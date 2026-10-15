import SwiftUI

// MARK: - Space sprint card (expanded pill)
// "My tasks" view of the current sprint: Today by default, Week toggle.
// Same card conventions as ResendCardView: header clears Mochi, 10–12 pt type.

struct SpaceCardView: View {
    @ObservedObject var state: AppState
    @State private var scopeToday = true

    private var sprint: SpaceSprint? { state.spaceSprint }

    private var todayString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    private var myTasks: [SpaceTask] {
        guard let sprint = state.spaceSprint else { return [] }
        return sprint.tasks
            .filter { $0.userId == state.spaceUserId }
            .filter { task in
                guard scopeToday else { return true }
                // Today = due today (any state) + overdue & still open
                if task.duedate == todayString { return true }
                return (task.duedate ?? "9999") < todayString && !task.done
            }
            .sorted { a, b in
                if a.done != b.done { return !a.done }
                if a.urgent != b.urgent { return a.urgent }
                return (a.duedate ?? "9999") < (b.duedate ?? "9999")
            }
    }

    private func dotColor(_ task: SpaceTask) -> Color {
        if task.done { return Color(hex: "#23A55A") }
        if let due = task.duedate {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            if let d = fmt.date(from: due) {
                let today = Calendar.current.startOfDay(for: Date())
                if d < today { return Color(hex: "#F4505E") }      // overdue
                if Calendar.current.isDate(d, inSameDayAs: today) { return Color(hex: "#F5A524") }
            }
        }
        return Color(hex: "#6B7079")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = state.spaceError {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: "#F4505E")).frame(width: 7, height: 7)
                    Text("Space").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Text(error).font(.system(size: 10))
                        .foregroundColor(Color(hex: "#F4505E"))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)
                Spacer().frame(height: 10)
            }

            if let sprint {
                // Header: name + sprint range + Today/Week toggle
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: "#239D9C")).frame(width: 7, height: 7)
                    Text("Space").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Text(sprint.dateRange)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                    Spacer()
                    scopeButton("Today", selected: scopeToday) { scopeToday = true }
                    scopeButton("Week", selected: !scopeToday) { scopeToday = false }
                }
                .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

                // Team points row
                HStack(spacing: 8) {
                    ForEach(sprint.points.prefix(6)) { member in
                        HStack(spacing: 3) {
                            Text(member.initial.isEmpty ? String(member.name.prefix(2)).uppercased() : member.initial)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(hex: "#C5C8CD"))
                            Text(format(member.point) + " pt")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#8E939C"))
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

                // My tasks
                VStack(alignment: .leading, spacing: 3) {
                    let tasks = myTasks
                    if tasks.isEmpty {
                        Text(scopeToday ? "Nothing due today ✨" : "No tasks this week.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#6B7079"))
                    } else {
                        ForEach(tasks.prefix(7)) { task in
                            HStack(spacing: 5) {
                                Circle().fill(dotColor(task)).frame(width: 5, height: 5)
                                if task.urgent && !task.done {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundColor(Color(hex: "#F4505E"))
                                }
                                Text(task.name)
                                    .font(.system(size: 11, weight: task.done ? .regular : .medium))
                                    .foregroundColor(task.done ? Color(hex: "#6B7079") : Color(hex: "#C5C8CD"))
                                    .strikethrough(task.done)
                                    .lineLimit(1).truncationMode(.tail)
                                if task.point > 0 {
                                    Text(format(task.point) + " pt")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(hex: "#8E939C"))
                                        .monospacedDigit()
                                }
                                Spacer(minLength: 4)
                                if let due = task.duedate, due != todayString, !task.done {
                                    Text(shortDate(due))
                                        .font(.system(size: 10))
                                        .foregroundColor(dotColor(task) == Color(hex: "#F4505E")
                                                         ? Color(hex: "#F4505E") : Color(hex: "#6B7079"))
                                }
                            }
                        }
                        if tasks.count > 7 {
                            Text("+\(tasks.count - 7) more")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#6B7079"))
                        }
                    }
                }
                .padding(.top, 8).padding(.leading, 108).padding(.trailing, 36)
                .padding(.bottom, 6)
            }
        }
    }

    private func scopeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(selected ? Color.white.opacity(0.10) : Color.white.opacity(0.03)))
        }
        .buttonStyle(.plain)
    }

    private func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private func shortDate(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        return parts.count == 3 ? "\(parts[2])/\(parts[1])" : iso
    }
}
