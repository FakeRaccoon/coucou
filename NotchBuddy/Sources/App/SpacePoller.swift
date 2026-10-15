import Foundation

// MARK: - Models

struct SpaceTask: Identifiable, Equatable {
    let id: Int
    let name: String
    let point: Double
    let duedate: String?
    let moduleName: String
    let projectName: String
    let done: Bool
    let userId: Int
    let urgent: Bool
}

// MARK: - SpacePoller
// Pulls "my" tasks for today across ALL Space projects: project-team lists
// the user's projects, then sprint-issues is fetched per project (the same
// calls the web app makes). Login (email/password in Keychain) refreshes
// the JWT automatically on 401. Poll every 5 minutes.

final class SpacePoller: @unchecked Sendable {
    static let shared = SpacePoller()
    static let pillId = "integration_space"
    private static let api = "https://space-api.venturo.id/api"

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
            attemptLogin { [weak self] _ in self?.poll(isRetry: true) }
            return
        }

        let uid = Int(KeychainStore.shared.get("space-user-id") ?? "") ?? 26

        getJSON("/v1/project-team?user_auth_id=\(uid)&akses_nama=User", token: token) { [weak self] json in
            guard let self, let json,
                  let data = json["data"] as? [String: Any],
                  let projects = data["dataProject"] as? [[String: Any]] else { return }
            let targets = projects.compactMap { project -> (String, String)? in
                guard let id = project["id"] as? String,
                      let name = project["name"] as? String else { return nil }
                return (id, name)
            }
            guard !targets.isEmpty else { return }

            // Current Mon–Fri sprint week, same window the web app uses.
            let cal = Calendar(identifier: .iso8601)
            let daysFromMonday = (cal.component(.weekday, from: cal.startOfDay(for: Date())) + 5) % 7
            let monday = cal.date(byAdding: .day, value: -daysFromMonday, to: cal.startOfDay(for: Date()))!
            let friday = cal.date(byAdding: .day, value: 4, to: monday)!
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let today = fmt.string(from: cal.startOfDay(for: Date()))
            let start = fmt.string(from: monday)
            let end = fmt.string(from: friday)

            let group = DispatchGroup()
            let results = ResultsBox()

            for (projectId, projectName) in targets {
                group.enter()
                var comps = URLComponents(string: "\(Self.api)/v3/sprint-issues")!
                comps.queryItems = [
                    URLQueryItem(name: "project_id", value: projectId),
                    URLQueryItem(name: "t_sprint_id", value: "null"),
                    URLQueryItem(name: "isUncategorized", value: "false"),
                    URLQueryItem(name: "start_date", value: start),
                    URLQueryItem(name: "end_date", value: end),
                ]
                var req = URLRequest(url: comps.url!, timeoutInterval: 15)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Accept")

                URLSession.shared.dataTask(with: req) { data, response, _ in
                    defer { group.leave() }
                    if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                        results.markAuthFailure()
                        return
                    }
                    guard let data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let payload = json["data"] as? [String: Any],
                          let issues = payload["dataIssues"] as? [[String: Any]] else { return }

                    for raw in issues {
                        guard let id = raw["id"] as? Int,
                              let name = raw["name"] as? String,
                              (raw["user_auth_id"] as? Int) == uid else { continue }
                        let pct = (raw["percentage_acceptance"] as? Double) ?? 0
                        results.add(SpaceTask(
                            id: id,
                            name: name,
                            point: (raw["point"] as? Double) ?? 0,
                            duedate: raw["duedate"] as? String,
                            moduleName: (raw["module_name"] as? String) ?? "",
                            projectName: projectName,
                            done: pct >= 100,
                            userId: uid,
                            urgent: (raw["is_urgent"] as? Bool) ?? false))
                    }
                }.resume()
            }

            group.notify(queue: .main) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let app = AppState.shared
                    if results.sawAuthFailure && !isRetry {
                        self.attemptLogin { _ in self.poll(isRetry: true) }
                        return
                    }
                    if results.sawAuthFailure {
                        app.spaceError = "Space login failed — check email/password in Settings"
                        return
                    }
                    app.spaceTasks = results.tasks
                    app.spaceError = nil
                    let dueNow = results.tasks.filter { $0.duedate == today && !$0.done }
                    self.updateBadge(tasks: dueNow, today: today)
                    appendAppLog("space.log", "polled uid=\(uid): projects=\(targets.count) "
                        + "mine-today=\(dueNow.count) mine-total=\(results.tasks.count)")
                }
            }
        }
    }

    // MARK: - Upload result
    // Verified against the live API: POST /issue-result {id:0, t_issue_id,
    // file: data-URI, extension} → 200 with the stored file URL.

    func uploadResult(issueId: Int, imageData: Data, ext: String,
                      completion: @escaping (Bool, String?) -> Void) {
        performUpload(issueId: issueId, imageData: imageData, ext: ext, isRetry: false, completion: completion)
    }

    private func performUpload(issueId: Int, imageData: Data, ext: String,
                               isRetry: Bool, completion: @escaping (Bool, String?) -> Void) {
        let token = KeychainStore.shared.get("space-token") ?? ""
        guard !token.isEmpty else {
            completion(false, "Belum login ke Space")
            return
        }
        let mime = (ext == "jpg" || ext == "jpeg") ? "image/jpeg" : "image/png"
        let body: [String: Any] = [
            "id": 0,
            "t_issue_id": issueId,
            "file": "data:\(mime);base64,\(imageData.base64EncodedString())",
            "extension": ext,
        ]
        var req = URLRequest(url: URL(string: "\(Self.api)/v1/issue-result")!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                if isRetry {
                    completion(false, "Sesi kedaluwarsa — coba lagi")
                    return
                }
                self?.attemptLogin { _ in
                    self?.performUpload(issueId: issueId, imageData: imageData, ext: ext,
                                        isRetry: true, completion: completion)
                }
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                appendAppLog("space.log", "upload result FAILED (\(code))")
                completion(false, "Upload gagal (\(code))")
                return
            }
            var url: String? = nil
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let payload = json["data"] as? [String: Any] {
                url = payload["file"] as? String
            }
            appendAppLog("space.log", "upload result OK for issue \(issueId) → \(url ?? "?")")
            completion(true, url)
        }.resume()
    }

    // MARK: - Login (auto JWT refresh)

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
            var req = URLRequest(url: URL(string: "\(Self.api)/v1/auth/login")!, timeoutInterval: 15)
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
        var req = URLRequest(url: URL(string: "\(Self.api)/v1/auth/csrf")!, timeoutInterval: 15)
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

    private func getJSON(_ path: String, token: String, completion: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: URL(string: Self.api + path)!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(json)
        }.resume()
    }

    // MARK: - Badge

    @MainActor
    private func updateBadge(tasks: [SpaceTask], today: String) {
        let app = AppState.shared
        guard let idx = app.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let dueToday = tasks.contains { $0.duedate == today && !$0.done }
        app.tasks[idx].pillBadge = dueToday ? .finished : nil
    }
}

/// Thread-safe accumulator for the parallel project fetches.
private final class ResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _tasks: [SpaceTask] = []
    private var _sawAuthFailure = false

    var tasks: [SpaceTask] { lock.withLock { _tasks } }
    var sawAuthFailure: Bool { lock.withLock { _sawAuthFailure } }

    func add(_ task: SpaceTask) {
        lock.withLock { _tasks.append(task) }
    }

    func markAuthFailure() {
        lock.withLock { _sawAuthFailure = true }
    }
}
