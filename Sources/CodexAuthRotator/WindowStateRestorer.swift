import AppKit
import SwiftUI

struct WindowStateRestorer: NSViewRepresentable {
    let frameAutosaveName: NSWindow.FrameAutosaveName
    let splitViewAutosaveName: NSSplitView.AutosaveName
    let minimumSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator(
            frameAutosaveName: frameAutosaveName,
            splitViewAutosaveName: splitViewAutosaveName,
            minimumSize: minimumSize
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        context.coordinator.scheduleConfigure(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.scheduleConfigure(from: nsView)
    }

    @MainActor
    final class Coordinator {
        private let frameAutosaveName: NSWindow.FrameAutosaveName
        private let splitViewAutosaveName: NSSplitView.AutosaveName
        private let minimumSize: CGSize

        init(
            frameAutosaveName: NSWindow.FrameAutosaveName,
            splitViewAutosaveName: NSSplitView.AutosaveName,
            minimumSize: CGSize
        ) {
            self.frameAutosaveName = frameAutosaveName
            self.splitViewAutosaveName = splitViewAutosaveName
            self.minimumSize = minimumSize
        }

        func scheduleConfigure(from view: NSView) {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                self.configure(from: view, attemptsRemaining: 20)
            }
        }

        private func configure(from view: NSView, attemptsRemaining: Int) {
            guard let window = view.window else {
                retry(from: view, attemptsRemaining: attemptsRemaining)
                return
            }

            window.isRestorable = true
            window.minSize = minimumSize
            window.setFrameAutosaveName(frameAutosaveName)

            let didFindSplitView = window.contentView.map(configureFirstSplitView(in:)) ?? false
            if !didFindSplitView {
                retry(from: view, attemptsRemaining: attemptsRemaining)
            }
        }

        @discardableResult
        private func configureFirstSplitView(in view: NSView) -> Bool {
            if let splitView = view as? NSSplitView {
                splitView.autosaveName = splitViewAutosaveName
                return true
            }

            for subview in view.subviews {
                if configureFirstSplitView(in: subview) {
                    return true
                }
            }

            return false
        }

        private func retry(from view: NSView, attemptsRemaining: Int) {
            guard attemptsRemaining > 0 else {
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
                guard let view else { return }
                self.configure(from: view, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }
}
