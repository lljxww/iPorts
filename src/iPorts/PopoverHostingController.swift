import AppKit
import SwiftUI

/// Gives AppKit a non-control first responder before SwiftUI's controls enter the key-view loop.
@MainActor
final class PopoverHostingController<Content: View>: NSViewController {
    private let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }

    override func loadView() {
        let container = PopoverFocusView()
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        resetFocus()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        resetFocus()
    }

    func resetFocus() {
        view.window?.initialFirstResponder = view
        view.window?.makeFirstResponder(view)
    }
}

@MainActor
final class PopoverFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func insertTab(_ sender: Any?) {
        window?.selectKeyView(following: self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectKeyView(preceding: self)
    }
}
