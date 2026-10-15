import SwiftUI
import AppKit

// MARK: - Top pill strip (overview)
// Horizontal row of pills above the focused card, video-style: the focused
// pill is a highlighted capsule with its name, the rest are round Mochi
// icons. Horizontally scrollable once the pills overflow the island.

struct PillStripView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.tasks) { task in
                        let focused = task.id == state.focusId
                        Button {
                            guard !focused else { return }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                state.setFocus(task.id)
                            }
                            SoundEngine.shared.play("blip")
                        } label: {
                            HStack(spacing: 5) {
                                MiniBotCanvasView(task: task)
                                    .frame(width: 16 / 0.6, height: 16 / 0.6)
                                    .frame(width: 16, height: 16)
                                if focused {
                                    Text(task.id == "integration_claude"
                                         ? ClaudeHost.pillName(hostApp: task.hostApp)
                                         : task.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(Color(hex: "#F5F6F8"))
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, focused ? 10 : 8)
                            .frame(height: 26)
                            .background(
                                Capsule().fill(focused ? Color.white.opacity(0.10) : Color(hex: "#0E0F11"))
                            )
                            .overlay(
                                Capsule().stroke(
                                focused ? Color.white.opacity(0.16)
                                        : Color(hex: task.color).opacity(0.28),
                                lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: state.focusId)
            }
            .onChange(of: state.focusId) { _, new in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
        .frame(height: 28)
    }
}

// MARK: - Two-finger horizontal swipe = previous / next pill
// Local scroll-wheel monitor scoped to the island window; hitTest returns nil
// so clicks pass through to the buttons underneath untouched.

struct PillSwipeSwitcher: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> SwipeMonitorView {
        let view = SwipeMonitorView()
        view.state = state
        return view
    }

    func updateNSView(_ nsView: SwipeMonitorView, context: Context) {
        nsView.state = state
    }

    final class SwipeMonitorView: NSView {
        weak var state: AppState?
        private var monitor: Any?
        private var accumulator: CGFloat = 0
        private var gestureConsumed = false
        private var lastFireAt = Date.distantPast

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.handleScroll(event)
                    return event
                }
            } else if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handleScroll(_ event: NSEvent) {
            guard let state, event.window === window,
                  abs(event.deltaX) > abs(event.deltaY) else { return }

            // Momentum (fingers already lifted) never switches pills.
            if event.momentumPhase != [] {
                accumulator = 0
                return
            }
            // A new touch (or the end of one) re-arms the single-fire latch.
            if event.phase == .began || event.phase == .ended || event.phase == .cancelled {
                gestureConsumed = false
                accumulator = 0
            }
            // One swipe = exactly one adjacent pill: latched until the gesture ends.
            if gestureConsumed { return }
            // Discrete devices (mouse wheels) report no phase — rate-limit instead.
            if event.phase == [] {
                guard Date().timeIntervalSince(lastFireAt) > 0.2 else { return }
            }

            let delta = abs(event.scrollingDeltaX) > 0.01 ? event.scrollingDeltaX : event.deltaX
            accumulator += delta
            // Natural scrolling: fingers left → deltaX > 0 → next pill.
            if accumulator > 8 {
                fire(1)
            } else if accumulator < -8 {
                fire(-1)
            }
        }

        private func fire(_ direction: Int) {
            accumulator = 0
            gestureConsumed = true
            lastFireAt = Date()
            guard let state, state.tasks.count > 1,
                  let current = state.tasks.firstIndex(where: { $0.id == state.focusId }) else { return }
            let next = (current + direction + state.tasks.count) % state.tasks.count
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                state.setFocus(state.tasks[next].id)
            }
            SoundEngine.shared.play("blip")
        }
    }
}
