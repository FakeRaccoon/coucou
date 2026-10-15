import SwiftUI

// MARK: - Discord voice card (expanded pill)
// Follows the layout conventions of ResendCardView / VercelDeploymentListView:
// header offset to clear Mochi, 10–12 pt type, the app's grey palette.

struct DiscordVoiceCardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: channel name + own mic/headphone state
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: "#5865F2"))
                    .frame(width: 7, height: 7)
                Text("Discord")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text(state.discordChannelName)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                Spacer()
                // Mic / headphones toggles — control Discord straight from the notch
                Button {
                    DiscordController.shared.setSelfMute(!state.discordSelfMute)
                } label: {
                    Image(systemName: state.discordSelfMute ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(state.discordSelfMute ? Color(hex: "#F4505E") : Color(hex: "#23A55A"))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(state.discordSelfMute ? "Unmute" : "Mute")
                Button {
                    DiscordController.shared.setSelfDeaf(!state.discordSelfDeaf)
                } label: {
                    Image(systemName: state.discordSelfDeaf ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(state.discordSelfDeaf ? Color(hex: "#F4505E") : Color(hex: "#C5C8CD"))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help(state.discordSelfDeaf ? "Undeafen" : "Deafen")
                Text("\(state.discordUsers.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .monospacedDigit()
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Speaker rows — green ring while someone talks, mic/deaf marks when muted
            VStack(alignment: .leading, spacing: 3) {
                ForEach(state.discordUsers.prefix(6)) { user in
                    HStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .stroke(user.speaking ? Color(hex: "#23A55A") : Color(hex: "#3A3E45"),
                                        lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                            Text(initials(user.username))
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Color(hex: "#C5C8CD"))
                        }
                        Text(user.username)
                            .font(.system(size: 11, weight: user.speaking ? .semibold : .medium))
                            .foregroundColor(user.speaking ? Color(hex: "#F5F6F8") : Color(hex: "#C5C8CD"))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer()
                        if user.mute || user.deaf {
                            Image(systemName: user.deaf ? "speaker.slash.fill" : "mic.slash.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(hex: "#6B7079"))
                        }
                    }
                }
                if state.discordUsers.isEmpty {
                    Text("Connected, nobody here yet.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#6B7079"))
                }
            }
            .padding(.top, 8)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Recent DM / mention notifications
            if let first = state.discordNotifications.first {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.discordNotifications.prefix(2)) { note in
                        HStack(spacing: 5) {
                            Circle().fill(Color(hex: "#5865F2")).frame(width: 5, height: 5)
                            Text(note.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "#C5C8CD"))
                                .lineLimit(1)
                            Text(note.body)
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#6B7079"))
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 108)
                .padding(.trailing, 36)
            }
        }
        .padding(.bottom, 6)
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first }
        return chars.isEmpty ? "?" : String(chars).uppercased()
    }
}
