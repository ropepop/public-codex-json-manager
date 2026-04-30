import AppKit
import SwiftUI

struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusTrigger: Int
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focusTrigger: focusTrigger)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.delegate = context.coordinator
        searchField.placeholderString = placeholder
        searchField.focusRingType = .default
        searchField.maximumRecents = 0
        searchField.recentsAutosaveName = nil
        searchField.sendAction(on: [.leftMouseUp, .keyUp])
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }

        if context.coordinator.consumeFocusTrigger(focusTrigger) {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String
        private var lastFocusTrigger: Int

        init(text: Binding<String>, focusTrigger: Int) {
            _text = text
            self.lastFocusTrigger = focusTrigger
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }

            let updatedText = searchField.stringValue
            if updatedText != text {
                text = updatedText
            }
        }

        func consumeFocusTrigger(_ focusTrigger: Int) -> Bool {
            guard focusTrigger != lastFocusTrigger else {
                return false
            }

            lastFocusTrigger = focusTrigger
            return true
        }
    }
}
