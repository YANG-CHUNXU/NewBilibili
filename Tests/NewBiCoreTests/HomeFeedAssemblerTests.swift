import Foundation
import XCTest
@testable import NewBiCore

final class HomeFeedAssemblerTests: XCTestCase {
    func testMergeDeduplicateAndSortByPublishTimeDesc() {
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        let t3 = Date(timeIntervalSince1970: 300)

        let a = VideoCard(
            id: "BV1",
            bvid: "BV1",
            title: "A",
            coverURL: nil,
            authorName: "up",
            authorUID: nil,
            durationText: nil,
            publishTime: t1
        )
        let b = VideoCard(
            id: "BV2",
            bvid: "BV2",
            title: "B",
            coverURL: nil,
            authorName: "up",
            authorUID: nil,
            durationText: nil,
            publishTime: t3
        )
        let c = VideoCard(
            id: "BV3",
            bvid: "BV3",
            title: "C",
            coverURL: nil,
            authorName: "up",
            authorUID: nil,
            durationText: nil,
            publishTime: t2
        )

        let merged = HomeFeedAssembler.merge([[a, b], [c, a]], limit: 100)
        XCTAssertEqual(merged.map(\.bvid), ["BV2", "BV3", "BV1"])
    }
}
