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

    func testParseSearchVideosFromPiniaState() throws {
        let html = """
        <!doctype html>
        <html><body><script>
        window.__pinia={"search":{"video":{"result":[{"bvid":"BV1E55555555","title":"搜索结果Pinia","pic":"//i0.hdslb.com/bfs/archive/pinia.jpg","author":"UP_PINIA","mid":"5005"}]}}};
        </script></body></html>
        """

        let cards = try parser.parseSearchVideos(from: html)

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.bvid, "BV1E55555555")
        XCTAssertEqual(cards.first?.authorName, "UP_PINIA")
    }

    func testParseSubscriptionVideosFromJSONParseDecodeURIComponentState() throws {
        let state = #"{"arcList":{"vlist":[{"bvid":"BV1F66666666","title":"订阅结果JSONParse","pic":"//i0.hdslb.com/bfs/archive/jsonparse.jpg","author":"UP_JSON","mid":"6006"}]}}"#
        let encoded = try XCTUnwrap(state.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let html = """
        <!doctype html>
        <html><body><script>
        window.__INITIAL_STATE__ = JSON.parse(decodeURIComponent("\(encoded)"));
        </script></body></html>
        """

        let cards = try parser.parseSubscriptionVideos(from: html)

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.bvid, "BV1F66666666")
        XCTAssertEqual(cards.first?.authorName, "UP_JSON")
    }

    func testParseSearchVideosFromNuxtDataScriptTag() throws {
        let html = """
        <!doctype html>
        <html><body>
        <script id="__NUXT_DATA__" type="application/json">{"payload":{"items":[{"bvid":"BV1G77777777","title":"搜索结果Nuxt","pic":"//i0.hdslb.com/bfs/archive/nuxt.jpg","author":"UP_NUXT","mid":"7007"}]}}</script>
        </body></html>
        """

        let cards = try parser.parseSearchVideos(from: html)

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.bvid, "BV1G77777777")
        XCTAssertEqual(cards.first?.authorName, "UP_NUXT")
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

        guard case .progressive(let url, _) = stream.transport else {
            return XCTFail("expected progressive transport")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/video-720.mp4")
        XCTAssertEqual(stream.qualityLabel, "高清 720P")
        XCTAssertEqual(stream.headers.referer, "https://www.bilibili.com")
    }

    func testParsePlayableStreamFromMultiDurlBuildsProgressivePlaylist() throws {
        let html = try loadFixture("play_page_multi_durl")
        let stream = try parser.parsePlayableStream(from: html)

        guard case .progressivePlaylist(let segments) = stream.transport else {
            return XCTFail("expected progressive playlist transport")
        }

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].url.absoluteString, "https://example.com/video-part-1.mp4")
        XCTAssertEqual(segments[1].url.absoluteString, "https://example.com/video-part-2.mp4")
        XCTAssertEqual(segments[0].durationSeconds, 30)
        XCTAssertEqual(segments[1].durationSeconds, 45)
        XCTAssertEqual(stream.qualityLabel, "高清 720P")
    }

    func testParsePlayableStreamFromInvalidMultiDurlThrowsNoPlayableStream() throws {
        let html = """
        <!doctype html>
        <html>
        <body>
        <script>
        window.__playinfo__={
          "data": {
            "quality": 64,
            "accept_quality": [64,32],
            "accept_description": ["高清 720P","清晰 480P"],
            "format": "mp4",
            "durl": [
              {"url": "https://example.com/video-part-1.mp4", "length": 30000},
              {"length": 45000}
            ]
          }
        };
        </script>
        </body>
        </html>
        """

        XCTAssertThrowsError(try parser.parsePlayableStream(from: html)) { error in
            XCTAssertEqual(error as? BiliClientError, .noPlayableStream)
        }
    }

    func testParsePlayableStreamPrefersDashWhenBothDashAndDurlExist() throws {
        let html = """
        <!doctype html>
        <html>
        <body>
        <script>
        window.__playinfo__={
          "data": {
            "quality": 80,
            "accept_quality": [80,64],
            "accept_description": ["高清 1080P","高清 720P"],
            "format": "mp4",
            "durl": [
              {"url": "https://example.com/video-1080.mp4"}
            ],
            "dash": {
              "video": [
                {"id": 80, "baseUrl": "https://example.com/video-1080.m4s", "codecs": "avc1.640028", "bandwidth": 2100000},
                {"id": 64, "baseUrl": "https://example.com/video-720.m4s", "codecs": "avc1.640020", "bandwidth": 1200000}
              ],
              "audio": [
                {"baseUrl": "https://example.com/audio.m4s", "codecs": "mp4a.40.2", "bandwidth": 128000}
              ]
            }
          }
        };
        </script>
        </body>
        </html>
        """

        let stream = try parser.parsePlayableStream(from: html)
        guard case .dash(let videoURL, let audioURL, _, _) = stream.transport else {
            return XCTFail("expected dash transport")
        }

        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-1080.m4s")
        XCTAssertEqual(audioURL?.absoluteString, "https://example.com/audio.m4s")
        XCTAssertEqual(stream.qualityOptions.map(\.qualityID), [80, 64])
    }

    func testParsePlayableStreamFromDash() throws {
        let html = try loadFixture("play_page_no_durl")
        let stream = try parser.parsePlayableStream(from: html)

        guard case .dash(let videoURL, let audioURL, _, _) = stream.transport else {
            return XCTFail("expected dash transport")
        }

        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-avc.m4s")
        XCTAssertEqual(audioURL?.absoluteString, "https://example.com/audio-aac.m4s")
        XCTAssertEqual(stream.qualityID, 80)
        XCTAssertEqual(stream.qualityOptions.count, 2)
        XCTAssertEqual(stream.qualityOptions.map(\.qualityID), [80, 64])
    }

    func testParsePlayableStreamDashWithoutAudioDoesNotThrow() throws {
        let html = try loadFixture("play_page_dash_no_audio")
        let stream = try parser.parsePlayableStream(from: html)

        guard case .dash(let videoURL, let audioURL, _, _) = stream.transport else {
            return XCTFail("expected dash transport")
        }

        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-only.m4s")
        XCTAssertNil(audioURL)
    }

    func testParsePlayableStreamDashUsesBackupURL() throws {
        let html = try loadFixture("play_page_dash_backup")
        let stream = try parser.parsePlayableStream(from: html)

        guard case .dash(let videoURL, let audioURL, _, _) = stream.transport else {
            return XCTFail("expected dash transport")
        }

        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-backup.m4s")
        XCTAssertEqual(audioURL?.absoluteString, "https://example.com/audio-backup.m4s")
    }

    func testParsePlayableStreamDashPrefersPrimaryURLWhenAvailable() throws {
        let html = """
        <!doctype html>
        <html><body><script>
        window.__playinfo__={"data":{"quality":80,"accept_quality":[80],"accept_description":["1080P"],"dash":{"video":[{"id":80,"baseUrl":"https://example.com/video-primary.m4s","backupUrl":["https://example.com/video-backup.m4s"],"codecs":"avc1.640028"}],"audio":[{"baseUrl":"https://example.com/audio-primary.m4s","backupUrl":["https://example.com/audio-backup.m4s"],"codecs":"mp4a.40.2"}]}}};
        </script></body></html>
        """

        let stream = try parser.parsePlayableStream(from: html)

        guard case .dash(let videoURL, let audioURL, let videoFallbacks, let audioFallbacks) = stream.transport else {
            return XCTFail("expected dash transport")
        }

        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-primary.m4s")
        XCTAssertEqual(audioURL?.absoluteString, "https://example.com/audio-primary.m4s")
        XCTAssertEqual(videoFallbacks.first?.absoluteString, "https://example.com/video-backup.m4s")
        XCTAssertEqual(audioFallbacks.first?.absoluteString, "https://example.com/audio-backup.m4s")
    }

    func testParsePlayableStreamDashFallsBackToHighestQuality() throws {
        let html = try loadFixture("play_page_dash_preferred_missing")
        let stream = try parser.parsePlayableStream(from: html)

        guard case .dash(let videoURL, _, _, _) = stream.transport else {
            return XCTFail("expected dash transport")
        }

        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-1080.m4s")
        XCTAssertEqual(stream.qualityLabel, "高清 1080P")
        XCTAssertEqual(stream.qualityID, 80)
    }

    func testParsePlayableStreamDashKeepsSelectableQualityOptions() throws {
        let html = try loadFixture("play_page_dash_preferred_missing")
        let stream = try parser.parsePlayableStream(from: html)

        XCTAssertEqual(stream.qualityOptions.map(\.qualityID), [80, 32])
        XCTAssertEqual(stream.qualityOptions.map(\.qualityLabel), ["高清 1080P", "清晰 480P"])
    }

    func testParsePlayableStreamDashFallsBackToAVCWhenPreferredQualityCodecIsNotCompatible() throws {
        let html = try loadFixture("play_page_dash_preferred_non_avc")
        let stream = try parser.parsePlayableStream(from: html)

        guard case .dash(let videoURL, _, _, _) = stream.transport else {
            return XCTFail("expected dash transport")
        }

        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-480-avc.m4s")
        XCTAssertEqual(stream.qualityID, 32)
        XCTAssertEqual(stream.qualityLabel, "清晰 480P")
        XCTAssertEqual(stream.qualityOptions.map(\.qualityID), [64, 32])
    }

    func testParsePlayableStreamDashUsesCodecidWhenCodecsFieldIsMissing() throws {
        let html = """
        <!doctype html>
        <html><body><script>
        window.__playinfo__={"data":{"quality":80,"accept_quality":[80],"accept_description":["高清 1080P"],"dash":{"video":[{"id":80,"baseUrl":"https://example.com/video-av1.m4s","codecid":13,"bandwidth":2100000},{"id":80,"baseUrl":"https://example.com/video-avc.m4s","codecid":7,"bandwidth":1800000}],"audio":[{"baseUrl":"https://example.com/audio-aac.m4s","codecs":"mp4a.40.2","bandwidth":128000}]}}};
        </script></body></html>
        """
        let stream = try parser.parsePlayableStream(from: html)

        guard case .dash(let videoURL, _, _, _) = stream.transport else {
            return XCTFail("expected dash transport")
        }
        XCTAssertEqual(videoURL.absoluteString, "https://example.com/video-avc.m4s")
        XCTAssertEqual(stream.qualityID, 80)
    }

    func testParsePlayableStreamWithoutDurlAndDashThrows() throws {
        let html = try loadFixture("play_page_no_stream")
        XCTAssertThrowsError(try parser.parsePlayableStream(from: html)) { error in
            XCTAssertEqual(error as? BiliClientError, .noPlayableStream)
        }
    }
}
