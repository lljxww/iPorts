import AppKit
import SwiftUI
import XCTest

@testable import iPorts

final class PopoverFocusTests: XCTestCase {
    @MainActor
    func testOpeningAndReopeningLandOutsideControlsAndPreserveKeyboardNavigation() async throws {
        _ = NSApplication.shared
        let controller = PopoverHostingController(rootView: Text("Panel"))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 200, height: 100))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = NSButton(title: "Refresh", target: nil, action: nil)
        button.frame = NSRect(x: 10, y: 10, width: 80, height: 30)
        let search = NSTextField(frame: NSRect(x: 10, y: 50, width: 160, height: 24))
        controller.view.addSubview(button)
        controller.view.addSubview(search)
        button.nextKeyView = search
        search.nextKeyView = button
        window.recalculateKeyViewLoop()

        XCTAssertTrue(window.makeFirstResponder(button))
        controller.viewWillAppear()
        controller.viewDidAppear()
        XCTAssertTrue(window.initialFirstResponder === controller.view)
        XCTAssertTrue(window.firstResponder === controller.view)
        XCTAssertFalse(controller.view.canBecomeKeyView)

        XCTAssertTrue(window.makeFirstResponder(button))
        window.selectNextKeyView(button)
        XCTAssertTrue(window.firstResponder === search.currentEditor())
        XCTAssertTrue(search.isEditable)
        XCTAssertTrue(button.isEnabled)

        // The next appearance must not restore the search editor from the previous session.
        controller.viewWillAppear()
        controller.viewDidAppear()
        XCTAssertTrue(window.firstResponder === controller.view)
        XCTAssertTrue(window.initialFirstResponder === controller.view)

        let focusView = try XCTUnwrap(controller.view as? PopoverFocusView)
        focusView.insertTab(nil)
        XCTAssertFalse(window.firstResponder === focusView)
        XCTAssertFalse(window.firstResponder === window)
        controller.resetFocus()
        focusView.insertBacktab(nil)
        XCTAssertFalse(window.firstResponder === focusView)
        XCTAssertFalse(window.firstResponder === window)
    }
}
