import SwiftUI

// MARK: - Space sprint card (expanded pill)
// Current week's tasks + team points, from space.venturo.id. Same card
// conventions as ResendCardView: header clears Mochi, 10–12 pt type.

struct SpaceCardView: View {
    @ObservedObject var state: AppState

    private var sprint: SpaceSprint? { state.spaceSprint }

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
                // Header
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: "#239D9C")).frame(width: 7, height: 7)
                    Text("Space").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Text(sprint.dateRange)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                    Text("\(sprint.totalIssues) issues")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .monospacedDigit()
                    Spacer()
                }
                .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

                // Team points row
                HStack(spacing: 8) {
                    ForEach(sprint.points.prefix(6)) { member in
                        HStack(spacing: 3) {
                            Text(member.initial.isEmpty ? String(member.name.prefix(2)).uppercased() : member.initial)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(hex: "#C5C8CD"))
                            Text(String(format: member.point.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", member.point) + " pt")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#8E939C"))
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

                // Tasks — open first, then by due date
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(sprint.tasks.prefix(6)) { task in
                        HStack(spacing: 5) {
                            Circle().fill(dotColor(task)).frame(width: 5, height: 5)
                            Text(task.name)
                                .font(.system(size: 11, weight: task.done ? .regular : .medium))
                                .foregroundColor(task.done ? Color(hex: "#6B7079") : Color(hex: "#C5C8CD"))
                                .lineLimit(1).truncationMode(.tail)
                            if !task.moduleName.isEmpty {
                                Text(task.moduleName)
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "#6B7079"))
                                    .lineLimit(1).truncationMode(.tail)
                            }
                            Spacer(minLength: 4)
                            if task.point > 0 {
                                Text(String(format: task.point.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", task.point) + " pt")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "#8E939C"))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .padding(.top, 8).padding(.leading, 108).padding(.trailing, 36)
                .padding(.bottom, 6)
            }
        }
    }
}
