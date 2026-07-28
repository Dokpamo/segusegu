import SwiftUI
import XCTest
@testable import LorepiaKit

final class ChatBubbleShapeTests: XCTestCase {
    func testIncomingBubbleKeepsOnlyTopLeadingCornerTight() {
        let radii = ChatBubbleShape(isOutgoing: false)
            .resolvedRadii(
                in: CGRect(x: 0, y: 0, width: 240, height: 120)
            )

        XCTAssertEqual(radii.topLeading, 4)
        XCTAssertEqual(radii.bottomLeading, 18)
        XCTAssertEqual(radii.bottomTrailing, 18)
        XCTAssertEqual(radii.topTrailing, 18)
    }

    func testOutgoingBubbleKeepsOnlyBottomTrailingCornerTight() {
        let radii = ChatBubbleShape(isOutgoing: true)
            .resolvedRadii(
                in: CGRect(x: 0, y: 0, width: 240, height: 120)
            )

        XCTAssertEqual(radii.topLeading, 18)
        XCTAssertEqual(radii.bottomLeading, 18)
        XCTAssertEqual(radii.bottomTrailing, 4)
        XCTAssertEqual(radii.topTrailing, 18)
    }

    func testBubbleRadiiStayProportionalAcrossOneFiveAndTenLines() {
        let heights: [CGFloat] = [34, 122, 232]

        for height in heights {
            let rect = CGRect(x: 0, y: 0, width: 240, height: height)
            let shape = ChatBubbleShape(isOutgoing: false)
            let radii = shape.resolvedRadii(in: rect)
            let expectedLargeRadius = min(18, rect.width / 2, rect.height / 2)

            XCTAssertEqual(radii.topLeading, min(4, expectedLargeRadius))
            XCTAssertEqual(radii.bottomLeading, expectedLargeRadius)
            XCTAssertEqual(radii.bottomTrailing, expectedLargeRadius)
            XCTAssertEqual(radii.topTrailing, expectedLargeRadius)
            XCTAssertEqual(shape.path(in: rect).boundingRect, rect)
        }
    }
}
