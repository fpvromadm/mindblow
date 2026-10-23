import SwiftUI
import AppKit

/// Press + hover feedback for the app's custom buttons.
///
/// Everything here is drawn by hand, so every button was `.buttonStyle(.plain)`
/// — which on macOS paints *no* pressed state whatsoever. A click therefore
/// looked like nothing until the document round-tripped and the map reflowed,
/// which reads as a dropped click even when the work took microseconds. This
/// style acknowledges the press locally and immediately, independent of
/// whatever the action goes on to do.
struct PressableButtonStyle: ButtonStyle {
    /// How far the label shrinks while held. Small round badges take a deeper
    /// squeeze than wide toolbar chips, where it would read as a wobble.
    var pressedScale: CGFloat = 0.94
    /// Lift on hover. Off for chips that already tint their own background.
    var hoverLift: CGFloat = 1.0
    /// Whether the pointer becomes a hand — these are all click targets, but
    /// only a handful used to say so.
    var pointerCursor: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, pressedScale: pressedScale,
                 hoverLift: hoverLift, pointerCursor: pointerCursor)
    }

    private struct Feedback: View {
        let configuration: Configuration
        let pressedScale: CGFloat
        let hoverLift: CGFloat
        let pointerCursor: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .scaleEffect(scale)
                .opacity(configuration.isPressed ? 0.82 : 1)
                // No spring: a spring keeps moving after the press has landed,
                // which reads as the control lagging behind the finger. This
                // is short enough to be felt rather than watched.
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.11), value: hovering)
                .onHover { inside in
                    guard isEnabled else { return }
                    hovering = inside
                    guard pointerCursor else { return }
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .onDisappear {
                    // A button can be torn down (node collapsed, hover badge
                    // hidden) while still holding the pushed cursor.
                    if hovering, pointerCursor { NSCursor.pop() }
                }
        }

        private var scale: CGFloat {
            if configuration.isPressed { return pressedScale }
            return hovering && isEnabled ? hoverLift : 1
        }
    }
}

/// A control that acts the instant the mouse goes down, instead of waiting for
/// it to come back up.
///
/// macOS fires buttons on mouse-up, which is right for anything destructive or
/// navigational — you can slide off to cancel. For a disclosure toggle it just
/// bills you for the length of your own click, which is the difference between
/// "immediate" and "quick". The action here is cheap, idempotent, and undoable,
/// so there is nothing to cancel out of.
struct PressActionButton<Label: View>: View {
    var help: String
    var accessibilityLabel: String
    /// Called when the pointer arrives, before any click. Somewhere to do the
    /// work the action is about to need, while the user is still aiming.
    var prepare: (() -> Void)? = nil
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var pressed = false
    @State private var hovering = false

    var body: some View {
        label()
            .scaleEffect(pressed ? 0.86 : (hovering ? 1.12 : 1))
            .opacity(pressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .animation(.easeOut(duration: 0.11), value: hovering)
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance 0 so the very first event of the press is
                // the one that fires; `pressed` keeps it to once per click.
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        // `action` may rebuild this view's subtree synchronously
                        // (e.g. a collapse toggle re-lays out the canvas), which
                        // tears down the in-flight gesture so `onEnded` never
                        // fires and `pressed` would strand at true — swallowing
                        // the next click. Clear the latch on the next tick so a
                        // skipped `onEnded` can't leave the button disarmed.
                        DispatchQueue.main.async { pressed = false }
                    }
                    .onEnded { _ in pressed = false }
            )
            .onHover { inside in
                hovering = inside
                if inside {
                    NSCursor.pointingHand.push()
                    prepare?()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if hovering { NSCursor.pop() }
            }
            .help(help)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Round badges attached to a topic (collapse, add child, notes, due date).
    static var nodeBadge: PressableButtonStyle {
        PressableButtonStyle(pressedScale: 0.86, hoverLift: 1.12)
    }

    /// Toolbar chips and other wide controls.
    static var chip: PressableButtonStyle {
        PressableButtonStyle(pressedScale: 0.95, hoverLift: 1.0)
    }

    /// Controls inside popovers and panels, where the pointer cursor would be
    /// noisy but a press still needs to register.
    static var panel: PressableButtonStyle {
        PressableButtonStyle(pressedScale: 0.96, hoverLift: 1.0, pointerCursor: false)
    }
}
