import Foundation
import XCTest
@testable import NewBiCore

final class BiliPublicHTMLParserTests: XCTestCase {
    private let parser = BiliPublicHTMLParser()

    func testParseSubscriptionVideos() throws {
        let html = try loadFixture("subscription_page")
        let cards = try parser.parseSubscriptionVideos(from: html)

        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.first?.bvid, "BV1A11111111")
        XCTAssertEqual(cards.first?.coverURL?.absoluteString, "https://i0.hdslb.com/bfs/archive/cover1.jpg")
    }

    func testParseSearchVideos() throws {
        let html = try loadFixture("search_page")
        let cards = try parser.parseSearchVideos(from: html)

        XCTAssertEqual(cards.count, 2)
        XCTAssertTrue(cards.map(\.bvid).contains("BV1C33333333"))
    }

    func testParseVideoDetail() throws {
        let html = try loadFixture("video_detail_page")
        let detail = try parser.parseVideoDetail(from: html)

        XCTAssertEqual(detail.bvid, "BV1A11111111")
        XCTAssertEqual(detail.parts.count, 2)
        XCTAssertEqual(detail.stats?.like, 333)
    }

    func testParsePlayableStream() throws {
        let html = try loadFixture("play_page")
        let stream = try parser.parsePlayableStream(from: html)

        XCTAssertEqual(stream.url.absoluteString, "https://example.com/video-720.mp4")
        XCTAssertEqual(stream.qualityLabel, "高清 720P")
    }

    func testParsePlayableStreamWithoutDurlThrows() throws {
        let html = try loadFixture("play_page_no_durl")
        XCTAssertThrowsError(try parser.parsePlayableStream(from: html))
    }
}
