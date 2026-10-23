import SwiftUI
import AppKit

/// AppKit-backed inline editor. SwiftUI's TextField + FocusState cannot
/// reliably claim first responder inside this custom canvas, so we manage
/// it directly.
struct InlineTextEditor: NSViewRepresentable {
    /// Where the caret lands when the editor takes focus.
    enum InitialSelection {
        /// Whole text highlighted — the "ready to retype" signal used when
        /// editing is entered deliberately (double-click, Space).
        case all
        /// Caret after the last character — used when a keystroke already
        /// started the text, so selecting would eat it.
        case end
    }

    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    /// Caret color — must contrast with the node fill, not the page.
    var caretColor: NSColor
    /// Selection-highlight fill; drawn under `selectedTextColor`.
    var selectionColor: NSColor
    var selectedTextColor: NSColor
    var width: CGFloat
    var initialSelection: InitialSelection = .all
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    var onTab: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = textColor
        field.alignment = .center
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.stringValue = text
        field.delegate = context.coordinator
        field.placeholderString = "Topic"
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Never push `text` back into the field: during editing the field is
        // the source of truth (field → binding only). Writing here can wipe
        // a dying editor's content just before its end-editing commit fires.
        field.font = font
        field.textColor = textColor
        field.preferredMaxLayoutWidth = width
        context.coordinator.focusWhenReady(field)
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.restoreFieldEditor(field)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextEditor
        var didFocus = false
        var didCancel = false

        init(_ parent: InlineTextEditor) {
            self.parent = parent
        }

        func focusWhenReady(_ field: NSTextField, attempts: Int = 20) {
            guard !didFocus else { return }
            if let window = field.window, window.makeFirstResponder(field) {
                didFocus = true
                styleFieldEditor(field)
                let length = (field.stringValue as NSString).length
                field.currentEditor()?.selectedRange = switch parent.initialSelection {
                case .all: NSRange(location: 0, length: length)
                case .end: NSRange(location: length, length: 0)
                }
            } else if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak field] in
                    guard let field else { return }
                    self.focusWhenReady(field, attempts: attempts - 1)
                }
            }
        }

        /// The field editor is one shared NSTextView per window, so its colors
        /// are set when we take focus and put back when we give it up —
        /// otherwise a white caret would follow into the inspector's fields.
        private func styleFieldEditor(_ field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.insertionPointColor = parent.caretColor
            editor.selectedTextAttributes = [
                .backgroundColor: parent.selectionColor,
                .foregroundColor: parent.selectedTextColor,
            ]
        }

        func restoreFieldEditor(_ field: NSTextField) {
            // After the field has resigned, `currentEditor()` is nil but the
            // window still holds the same shared editor — reach it directly.
            let editor = (field.currentEditor() ?? field.window?.fieldEditor(false, for: nil)) as? NSTextView
            guard let editor else { return }
            editor.insertionPointColor = .textColor
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor.selectedTextBackgroundColor,
                .foregroundColor: NSColor.selectedTextColor,
            ]
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            restoreFieldEditor(field)
            guard !didCancel else { return }
            parent.onCommit(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let currentText = (control as? NSTextField)?.stringValue ?? textView.string
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit(currentText)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                didCancel = true
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                parent.onTab(currentText)
                return true
            default:
                return false
            }
        }
    }
}
