import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Space card (expanded pill)
// My tasks due today (+ overdue & open) across all Space projects,
// grouped per project. Same card conventions as ResendCardView.

struct SpaceCardView: View {
    @ObservedObject var state: AppState
    @State private var uploadingTaskId: Int? = nil
    @State private var feedback: (text: String, good: Bool)? = nil

    private var todayString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    // Strictly today: due today (done or open). No overdue backfill.
    private var todaysTasks: [SpaceTask] {
        state.spaceTasks
            .filter { $0.duedate == todayString }
            .sorted { a, b in
                if a.done != b.done { return !a.done }
                if a.urgent != b.urgent { return a.urgent }
                return a.name < b.name
            }
    }

    private var grouped: [(project: String, tasks: [SpaceTask])] {
        Dictionary(grouping: todaysTasks, by: \.projectName)
            .sorted { $0.key < $1.key }
            .map { (project: $0.key, tasks: $0.value) }
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

            // Header
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#239D9C")).frame(width: 7, height: 7)
                Text("Space — Today").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text("\(todaysTasks.count) task\(todaysTasks.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .monospacedDigit()
                if let feedback {
                    Text(feedback.text)
                        .font(.system(size: 10, weight: feedback.good ? .semibold : .regular))
                        .foregroundColor(feedback.good ? Color(hex: "#23A55A") : Color(hex: "#F4505E"))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

            if todaysTasks.isEmpty {
                Text("Nothing due today ✨")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .padding(.top, 8).padding(.leading, 108).padding(.trailing, 36)
                    .padding(.bottom, 6)
            } else {
                let groups = grouped
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(groups, id: \.project) { group in
                        // Project section header
                        HStack(spacing: 4) {
                            Text(group.project.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(hex: "#239D9C"))
                            Text("· \(group.tasks.count)")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "#6B7079"))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(group.tasks.prefix(5)) { task in
                                taskRow(task)
                            }
                            if group.tasks.count > 5 {
                                Text("+\(group.tasks.count - 5) more")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "#6B7079"))
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
                .padding(.top, 8).padding(.leading, 108).padding(.trailing, 36)
                .padding(.bottom, 6)
            }
        }
    }

    private func taskRow(_ task: SpaceTask) -> some View {
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
                // Overdue tasks show how far back they slipped
                Text(shortDate(due))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#F4505E"))
            }
            uploadButton(task)
        }
    }

    /// Screenshot to clipboard (⌘⇧4+Ctrl) → click = sent. No clipboard image → file picker.
    private func uploadButton(_ task: SpaceTask) -> some View {
        Button {
            guard uploadingTaskId == nil else { return }
            uploadFor(task)
        } label: {
            Group {
                if uploadingTaskId == task.id {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.up.to.line")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundColor(Color(hex: "#8E939C"))
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help("Upload hasil: screenshot di clipboard, atau pilih file")
        .disabled(uploadingTaskId != nil)
    }

    private func uploadFor(_ task: SpaceTask) {
        var imageData: Data?
        var ext = "png"

        if let png = NSPasteboard.general.data(forType: .png) {
            imageData = png
        } else if let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self]),
                  let image = images.first as? NSImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) {
            imageData = rep.representation(using: .png, properties: [:])
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.png, .jpeg]
            guard panel.runModal() == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            imageData = data
            ext = url.pathExtension.lowercased()
        }
        guard let imageData, !imageData.isEmpty else { return }

        uploadingTaskId = task.id
        feedback = nil
        SpacePoller.shared.uploadResult(issueId: task.id, imageData: imageData, ext: ext) { ok, message in
            uploadingTaskId = nil
            if ok {
                feedback = ("✓ hasil terkirim", true)
                SoundEngine.shared.play("finish")
            } else {
                feedback = (message ?? "Upload gagal", false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if self.feedback?.text.hasPrefix("✓") == true || !ok { self.feedback = nil }
            }
        }
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
