import XCTest

final class DockPreviewLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testEdgeIsTheScreenSideTheIconHugs() {
        XCTAssertEqual(DockPreviewLayout.edge(CGRect(x: 800, y: 4, width: 60, height: 60), screen), .bottom)
        XCTAssertEqual(DockPreviewLayout.edge(CGRect(x: 4, y: 500, width: 60, height: 60), screen), .left)
        XCTAssertEqual(DockPreviewLayout.edge(CGRect(x: 1664, y: 500, width: 60, height: 60), screen), .right)
    }

    func testThumbnailsKeepTheWindowShapeWithinClamps() {
        let sizes = DockPreviewLayout.thumbnailSizes([16 / 10, 10, 0.1], maxLength: 10_000, vertical: false)
        XCTAssertEqual(sizes.map { $0.height }, [130, 130, 130])
        XCTAssertEqual(sizes.map { $0.width }, [208, 286, 78])
    }

    func testTooManyWindowsShrinkToFitTheScreen() {
        let sizes = DockPreviewLayout.thumbnailSizes(Array(repeating: 16 / 10, count: 12), maxLength: 1200, vertical: false)
        let panel = DockPreviewLayout.panelSize(sizes, vertical: false)
        XCTAssertLessThanOrEqual(panel.width, 1200 + CGFloat(sizes.count))
        XCTAssertLessThan(sizes[0].height, DockPreviewLayout.thumbnailHeight)
    }

    func testBottomDockPanelSitsAboveTheIconAndStaysOnScreen() {
        let panel = CGSize(width: 500, height: 170)
        let visible = CGRect(x: 8, y: 80, width: 1712, height: 1000)
        let centered = DockPreviewLayout.origin(panel, icon: CGRect(x: 800, y: 4, width: 60, height: 60), edge: .bottom, visibleFrame: visible)
        XCTAssertEqual(centered, CGPoint(x: 580, y: 72))
        let nearLeftEdge = DockPreviewLayout.origin(panel, icon: CGRect(x: 10, y: 4, width: 60, height: 60), edge: .bottom, visibleFrame: visible)
        XCTAssertEqual(nearLeftEdge.x, 8)
    }

    func testSideDockPanelOpensAwayFromTheEdge() {
        let panel = CGSize(width: 240, height: 400)
        let visible = CGRect(x: 80, y: 8, width: 1560, height: 1080)
        let left = DockPreviewLayout.origin(panel, icon: CGRect(x: 4, y: 500, width: 60, height: 60), edge: .left, visibleFrame: visible)
        XCTAssertEqual(left, CGPoint(x: 72, y: 330))
        let right = DockPreviewLayout.origin(panel, icon: CGRect(x: 1664, y: 500, width: 60, height: 60), edge: .right, visibleFrame: visible)
        XCTAssertEqual(right, CGPoint(x: 1416, y: 330))
    }

    func testBridgeCoversTheGapBetweenIconAndPanel() {
        let icon = CGRect(x: 800, y: 4, width: 60, height: 60)
        let panel = CGRect(x: 580, y: 72, width: 500, height: 170)
        let bridge = DockPreviewLayout.bridge(icon: icon, panel: panel, edge: .bottom)
        XCTAssertTrue(bridge.contains(CGPoint(x: 830, y: 68)))
        XCTAssertEqual(bridge.maxY, panel.minY)
    }

    func testFitCentersAndKeepsAspect() {
        let fitted = DockPreviewLayout.fit(CGSize(width: 1000, height: 500), in: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(fitted, CGRect(x: 0, y: 50, width: 200, height: 100))
    }
}
