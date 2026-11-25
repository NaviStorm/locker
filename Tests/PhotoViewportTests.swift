#if !SWIFT_PACKAGE
import XCTest
@testable import Locker

final class PhotoViewportTests: XCTestCase {
    func testRepeatedPinchKeepsThePhotoPointUnderTheFingers() {
        let view = CGSize(width: 300, height: 300)
        let photo = CGSize(width: 1200, height: 1200)
        let initial = PhotoViewport()
        let first = initial.zoom(by: 2, around: CGPoint(x: 225, y: 75), photo: photo, in: view)
        XCTAssertEqual(first.offset, CGSize(width: -75, height: 75))
        let second = first.zoom(by: 1.5, around: CGPoint(x: 180, y: 150), photo: photo, in: view)
        XCTAssertEqual(second.scale, 3)
        XCTAssertEqual(second.offset, CGSize(width: -127.5, height: 112.5))
        XCTAssertEqual(second.zoom(by: 0.1, around: .zero, photo: photo, in: view), initial)
    }

    func testPanStaysWithinPhotoEdgesAndResizeRecentresLetterboxedAxis() {
        let view = CGSize(width: 300, height: 400)
        let photo = CGSize(width: 1200, height: 600)
        let zoom = PhotoViewport().zoom(by: 2, around: CGPoint(x: 150, y: 200), photo: photo, in: view)
        XCTAssertEqual(zoom.imageSize(photo, in: view), CGSize(width: 600, height: 300))
        let panned = zoom.panned(by: CGSize(width: 900, height: -900), photo: photo, in: view)
        XCTAssertEqual(panned.offset, CGSize(width: 150, height: 0))
        let resized = panned.panned(by: .zero, photo: photo, in: CGSize(width: 600, height: 100))
        XCTAssertEqual(resized.offset, .zero)
        XCTAssertEqual(zoom.zoom(by: 30, around: .zero, photo: photo, in: view).scale, 8)
    }
}
#endif
