import AppKit
import XCTest
@testable import DikteNative

final class OverlayLayoutTests: XCTestCase {
    func testCompactOverlayUsesSmallBottomLeftFrame() {
        let visible = NSRect(x: 0, y: 24, width: 1512, height: 920)
        let frame = OverlayLayout.frame(position: .bottomLeft, visibleFrame: visible)

        XCTAssertEqual(frame.size.width, 286)
        XCTAssertEqual(frame.size.height, 46)
        XCTAssertEqual(frame.origin.x, 28)
        XCTAssertEqual(frame.origin.y, 48)
    }

    func testWideOverlayRemainsAvailableAtTopCenter() {
        let visible = NSRect(x: 100, y: 24, width: 1512, height: 920)
        let frame = OverlayLayout.frame(position: .top, visibleFrame: visible)

        XCTAssertEqual(frame.size.width, 520)
        XCTAssertEqual(frame.size.height, 72)
        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertEqual(frame.maxY, visible.maxY - 4)
    }
}
