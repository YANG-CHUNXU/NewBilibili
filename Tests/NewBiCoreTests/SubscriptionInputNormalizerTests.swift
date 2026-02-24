import XCTest
@testable import NewBiCore

final class SubscriptionInputNormalizerTests: XCTestCase {
    func testNormalizePureUID() throws {
        XCTAssertEqual(try SubscriptionInputNormalizer.normalizeUID(from: "123456"), "123456")
    }

    func testNormalizeHomepageURL() throws {
        let url = "https://space.bilibili.com/987654/video"
        XCTAssertEqual(try SubscriptionInputNormalizer.normalizeUID(from: url), "987654")
    }

    func testNormalizeInvalidInputThrows() {
        XCTAssertThrowsError(try SubscriptionInputNormalizer.normalizeUID(from: "foo-bar"))
    }
}
