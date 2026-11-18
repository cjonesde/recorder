import AppKit
import XCTest
@testable import Recorder

final class CoachHUDPanelTests: XCTestCase {
    @MainActor
    func testDefaultSpotIsAThirdOfTheScreenRightOfCentre() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let origin = CoachHUDPanel.defaultOrigin(in: visible)
        XCTAssertEqual(origin.x + CoachHUDPanel.size.width / 2, 756 + 504)
        XCTAssertEqual(origin.y, 944 - CoachHUDPanel.size.height - CoachHUDPanel.gapBelowMenuBar)
    }

    @MainActor
    func testChecksUnfoldBelowTheCapsuleAndFoldBackToIt() {
        let collapsed = NSRect(origin: NSPoint(x: 1162, y: 908), size: CoachHUDPanel.size)
        let expanded = CoachHUDPanel.frame(keepingCapsuleOf: collapsed, expanded: true)
        XCTAssertEqual(expanded.size, CoachHUDPanel.expandedSize)
        XCTAssertEqual(expanded.maxY, collapsed.maxY)
        XCTAssertEqual(expanded.midX, collapsed.midX)
        XCTAssertEqual(CoachHUDPanel.frame(keepingCapsuleOf: expanded, expanded: false), collapsed)
        XCTAssertEqual(CoachHUDPanel.collapsedOrigin(of: expanded), collapsed.origin)
    }

    @MainActor
    func testDefaultSpotFollowsAScreenThatIsNotAtZero() {
        let visible = NSRect(x: -1920, y: 200, width: 1920, height: 1050)
        let origin = CoachHUDPanel.defaultOrigin(in: visible)
        XCTAssertEqual(origin.x + CoachHUDPanel.size.width / 2, -960 + 640)
        XCTAssertEqual(origin.y, 1250 - CoachHUDPanel.size.height - CoachHUDPanel.gapBelowMenuBar)
    }
}
