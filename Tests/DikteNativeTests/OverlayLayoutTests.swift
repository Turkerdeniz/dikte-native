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

    func testCompactLayoutSupportsNegativeScreenCoordinates() {
        let visible = NSRect(x: -1920, y: -900, width: 1920, height: 876)
        let frame = OverlayLayout.frame(position: .bottomLeft, visibleFrame: visible)

        XCTAssertEqual(frame.origin.x, -1892)
        XCTAssertEqual(frame.origin.y, -876)
    }

    func testResolverMovesOnlyAfterFrontWindowHasMajorityOnNewDisplay() {
        let displays = [
            OverlayDisplaySnapshot(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
            OverlayDisplaySnapshot(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
        ]
        let mostlyCurrent = OverlayWindowSnapshot(ownerPID: 42, layer: 0,
                                                   bounds: CGRect(x: 1000, y: 100, width: 1000, height: 700))
        let mostlyNew = OverlayWindowSnapshot(ownerPID: 42, layer: 0,
                                               bounds: CGRect(x: 1200, y: 100, width: 1000, height: 700))

        XCTAssertEqual(OverlayScreenResolver.displayID(frontmostPID: 42, currentDisplayID: 1,
                                                        windows: [mostlyCurrent], displays: displays), 1)
        XCTAssertEqual(OverlayScreenResolver.displayID(frontmostPID: 42, currentDisplayID: 1,
                                                        windows: [mostlyNew], displays: displays), 2)
    }

    func testResolverUsesFrontmostNormalWindowAndIgnoresOtherProcessesAndPanels() {
        let displays = [
            OverlayDisplaySnapshot(id: 10, frame: CGRect(x: -1600, y: 0, width: 1600, height: 900)),
            OverlayDisplaySnapshot(id: 11, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        ]
        let windows = [
            OverlayWindowSnapshot(ownerPID: 9, layer: 0,
                                  bounds: CGRect(x: -1500, y: 0, width: 1200, height: 800)),
            OverlayWindowSnapshot(ownerPID: 7, layer: 10,
                                  bounds: CGRect(x: -1400, y: 10, width: 800, height: 600)),
            OverlayWindowSnapshot(ownerPID: 7, layer: 0,
                                  bounds: CGRect(x: 100, y: 20, width: 1000, height: 800))
        ]

        XCTAssertEqual(OverlayScreenResolver.displayID(frontmostPID: 7, currentDisplayID: nil,
                                                        windows: windows, displays: displays), 11)
    }

    func testResolverFallsBackWhenCurrentDisplayWasRemoved() {
        let displays = [OverlayDisplaySnapshot(id: 2,
                                               frame: CGRect(x: 0, y: 0, width: 1512, height: 982))]
        let window = OverlayWindowSnapshot(ownerPID: 42, layer: 0,
                                           bounds: CGRect(x: 80, y: 80, width: 900, height: 700))

        XCTAssertEqual(OverlayScreenResolver.displayID(frontmostPID: 42, currentDisplayID: 1,
                                                        windows: [window], displays: displays), 2)
    }
}
