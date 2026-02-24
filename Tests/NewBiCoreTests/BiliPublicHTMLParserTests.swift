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

    func testParsePlayableStreamFromDurl() throws {
        let html = try loadFixture("play_page")
        let stream = try parser.parsePlayableStream(from: html)

        guard case .progressive(let url) = stream.transport else {
            return XCTFail("expected progressive transport")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/video-720.mp4")
        XCTAssertEqual(stream.qualityLabel, "高清 720P")
        XCTAssertEqual(stream.headers.referer, "https://www.bilibili.com")
    }

    func testParsePlayableStreamFromDash() throws {
        let html = try loadFixture("play_page_no_durl")
        let stream = try parser.parsePlayableStream(from: html)

        guard case .dash(let videoURL, let audioURL) = stream.transport else {
            return XCTFail("expected dash transport")
        }

        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-avc.m4s")
        XCTAssertEqual(audioURL?.absoluteString, "https://example.com/audio-hi.m4s")
    }

    func testParsePlayableStreamDashWithoutAudioDoesNotThrow() throws {
        let html = try loadFixture("play_page_dash_no_audio")
        let stream = try parser.parsePlayableStream(from: html)

        guard case .dash(let videoURL, let audioURL) = stream.transport else {
            return XCTFail("expected dash transport")
        }

        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-only.m4s")
        XCTAssertNil(audioURL)
    }

    func testParsePlayableStreamDashUsesBackupURL() throws {
        let html = try loadFixture("play_page_dash_backup")
        let stream = try parser.parsePlayableStream(from: html)

        guard case .dash(let videoURL, let audioURL) = stream.transport else {
            return XCTFail("expected dash transport")
        }

        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-backup.m4s")
        XCTAssertEqual(audioURL?.absoluteString, "https://example.com/audio-backup.m4s")
    }

    func testParsePlayableStreamDashFallsBackToHighestQuality() throws {
        let html = try loadFixture("play_page_dash_preferred_missing")
        let stream = try parser.parsePlayableStream(from: html)

        guard case .dash(let videoURL, _) = stream.transport else {
            return XCTFail("expected dash transport")
        }

        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-1080.m4s")
        XCTAssertEqual(stream.qualityLabel, "高清 1080P")
    }

    func testParsePlayableStreamWithoutDurlAndDashThrows() throws {
        let html = try loadFixture("play_page_no_stream")
        XCTAssertThrowsError(try parser.parsePlayableStream(from: html)) { error in
            XCTAssertEqual(error as? BiliClientError, .noPlayableStream)
        }
    }
}
