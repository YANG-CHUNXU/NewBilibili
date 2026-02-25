import XCTest

final class TestFixtureLoaderTests: XCTestCase {
    func testLoadFixtureLoadsProcessedFixtureFromBundleRoot() throws {
        let html = try loadFixture("subscription_page")

        XCTAssertFalse(html.isEmpty)
        XCTAssertTrue(html.contains("BV1A11111111"))
    }

    func testLoadFixtureMissingFileThrowsInsteadOfCrashing() throws {
        try XCTExpectFailure("Missing fixture should report an XCTFail diagnostic before throwing.") {
            XCTAssertThrowsError(try loadFixture("__missing_fixture__")) { error in
                guard case let FixtureLoaderError.notFound(name, candidates, bundlePath) = error else {
                    return XCTFail("Expected notFound error, got: \(error)")
                }

                XCTAssertEqual(name, "__missing_fixture__")
                XCTAssertTrue(bundlePath.contains("NewBiCore_NewBiCoreTests.bundle"))
                XCTAssertTrue(candidates.contains { $0.hasSuffix("/__missing_fixture__.html") })
                XCTAssertTrue(candidates.contains { $0.hasSuffix("/Fixtures/__missing_fixture__.html") })
            }
        }
    }
}
