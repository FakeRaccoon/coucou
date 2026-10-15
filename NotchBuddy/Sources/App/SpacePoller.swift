import Foundation

// MARK: - Models

struct SpaceTask: Identifiable, Equatable {
    let id: Int
    let name: String
    let point: Double
    let duedate: String?
    let moduleName: String
    let done: Bool
    let userId: Int
    let userName: String
    let urgent: Bool
}

struct SpacePoint: Identifiable, Equatable {
    let id: Int
    let name: String
    let initial: String
    let point: Double
}

struct SpaceSprint: Equatable {
    var totalIssues: Int
    var tasks: [SpaceTask]
    var points: [SpacePoint]
    var dateRange: String
}

// MARK: - SpacePoller
// Polls the Space task tracker (space.venturo.id) for the current sprint
// week — the same call the web app makes: Bearer JWT + project id, Monday
// to Friday. Token + project id live in the Keychain (Settings → Space).

final class SpacePoller: @unchecked Sendable {
    static let shared = SpacePoller()
    static let pillId = "integration_space"
    private static let baseURL = "https://space-api.venturo.id/api/v3"

    private var timer: DispatchSourceTimer?
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 10, repeating: 300, leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func pollNow() { DispatchQueue.global(qos: .utility).async { [weak self] in self?.poll() } }

    private func poll(isRetry: Bool = false) {
        guard !DemoEngine.isPollerPaused else { return }
        let token = KeychainStore.shared.get("space-token") ?? ""
        if token.isEmpty {
            guard !isRetry else {
                DispatchQueue.main.async {
                    AppState.shared.spaceError = "Login failed — check Space email/password in Settings"
                }
                return
            }
            attemptLogin { _ in self.poll(isRetry: true) }
            return
        }
        let projectId = KeychainStore.shared.get("space-project-id").flatMap { Int($0) } ?? 45

        let cal = Calendar(identifier: .iso8601)
        let daysFromMonday = (cal.component(.weekday, from: cal.startOfDay(for: Date())) + 5) % 7
        let monday = cal.date(byAdding: .day, value: -daysFromMonday, to: cal.startOfDay(for: Date()))!
        let friday = cal.date(byAdding: .day, value: 4, to: monday)!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: cal.startOfDay(for: Date()))
        let start = fmt.string(from: monday)
        let end = fmt.string(from: friday)

        var comps = URLComponents(string: "\(Self.baseURL)/sprint-issues")!
        comps.queryItems = [
            URLQueryItem(name: "project_id", value: String(projectId)),
            URLQueryItem(name: "t_sprint_id", value: "null"),
            URLQueryItem(name: "isUncategorized", value: "false"),
            URLQueryItem(name: "start_date", value: start),
            URLQueryItem(name: "end_date", value: end),
        ]
        var req = URLRequest(url: comps.url!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self, let data else { return }
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                if isRetry {
                    DispatchQueue.main.async {
                        AppState.shared.spaceError = "Login failed — check Space email/password in Settings"
                    }
                    return
                }
                // JWT expired: log in again with the stored credentials, then retry once.
                attemptLogin { _ in self.poll(isRetry: true) }
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["data"] as? [String: Any] else { return }

            var tasks: [SpaceTask] = []
            for raw in (payload["dataIssues"] as? [[String: Any]]) ?? [] {
                guard let id = raw["id"] as? Int,
                      let name = raw["name"] as? String else { continue }
                let pct = (raw["percentage_acceptance"] as? Double) ?? 0
                tasks.append(SpaceTask(
                    id: id,
                    name: name,
                    point: (raw["point"] as? Double) ?? 0,
                    duedate: raw["duedate"] as? String,
                    moduleName: (raw["module_name"] as? String) ?? "",
                    done: pct >= 100,
                    userId: (raw["user_auth_id"] as? Int) ?? 0,
                    userName: (raw["user_auth_name"] as? String) ?? "",
                    urgent: (raw["is_urgent"] as? Bool) ?? false))
            }
            var points: [SpacePoint] = []
            for raw in (payload["dataPoint"] as? [[String: Any]]) ?? [] {
                guard let id = raw["id"] as? Int, let name = raw["name"] as? String else { continue }
                points.append(SpacePoint(id: id, name: name,
                                         initial: (raw["initial"] as? String) ?? "",
                                         point: (raw["point"] as? Double) ?? 0))
            }
            tasks.sort { a, b in
                if a.done != b.done { return !a.done }   // open tasks first
                return (a.duedate ?? "9999") < (b.duedate ?? "9999")
            }

            DispatchQueue.main.async {
                let app = AppState.shared
                app.spaceSprint = SpaceSprint(
                    totalIssues: (payload["totalIssue"] as? Int) ?? tasks.count,
                    tasks: tasks,
                    points: points,
                    dateRange: "\(start.suffix(5)) – \(end.suffix(5))")
                app.spaceUserId = Int(KeychainStore.shared.get("space-user-id") ?? "") ?? 26
                app.spaceError = nil
                let mine = tasks.filter { $0.userId == app.spaceUserId }
                self.updateBadge(tasks: mine, today: today)
            }
        }.resume()
    }

    // MARK: - Login (auto JWT refresh)
    // Verified against the live API: GET /auth/csrf → POST /auth/login with
    // {email, password} + X-CSRF-Token → data.access_token.

    private func attemptLogin(completion: @escaping (Bool) -> Void) {
        guard let email = KeychainStore.shared.get("space-email"), !email.isEmpty,
              let password = KeychainStore.shared.get("space-password"), !password.isEmpty else {
            DispatchQueue.main.async {
                AppState.shared.spaceError = "Token expired — add Space email/password in Settings"
            }
            completion(false)
            return
        }
        login(email: email, password: password) { ok in
            appendAppLog("space.log", ok ? "login OK, token refreshed" : "login FAILED")
            if !ok {
                DispatchQueue.main.async {
                    AppState.shared.spaceError = "Space login failed — check email/password in Settings"
                }
            }
            completion(ok)
        }
    }

    private func login(email: String, password: String, completion: @escaping (Bool) -> Void) {
        csrf { csrfToken in
            guard let csrfToken else { completion(false); return }
            var req = URLRequest(url: URL(string: "\(Self.baseURL)/auth/login")!, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-Token")
            req.setValue("https://space.venturo.id", forHTTPHeaderField: "Origin")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password])
            URLSession.shared.dataTask(with: req) { data, response, _ in
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = json["data"] as? [String: Any],
                      let jwt = payload["access_token"] as? String else {
                    completion(false)
                    return
                }
                KeychainStore.shared.set("space-token", value: jwt)
                completion(true)
            }.resume()
        }
    }

    private func csrf(_ completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/auth/csrf")!, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let csrfToken = json["data"] as? String else {
                completion(nil)
                return
            }
            completion(csrfToken)
        }.resume()
    }

    @MainActor
    private func updateBadge(tasks: [SpaceTask], today: String) {
        let app = AppState.shared
        guard let idx = app.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let dueToday = tasks.contains { $0.duedate == today && !$0.done }
        app.tasks[idx].pillBadge = dueToday ? .finished : nil
    }
}
