import Foundation
import XCTest
@testable import NewBiCore

final class NativePlaybackResourceLoaderTests: XCTestCase {
    func testMasterPlaylistWithAudio() throws {
        let sessionID = UUID(uuidString: "F6D87659-63D8-4D64-B952-F4C2A9C52EB8")!
        let playlist = try XCTUnwrap(
            NativePlaybackProxyUtilities.makeMasterPlaylist(
                scheme: "newbi-proxy",
                sessionID: sessionID,
                hasAudio: true
            )
        )

        XCTAssertTrue(playlist.contains("#EXTM3U"))
        XCTAssertTrue(playlist.contains("#EXT-X-MEDIA:TYPE=AUDIO"))
        XCTAssertTrue(playlist.contains("newbi-proxy://f6d87659-63d8-4d64-b952-f4c2a9c52eb8/video.m3u8"))
        XCTAssertTrue(playlist.contains("newbi-proxy://f6d87659-63d8-4d64-b952-f4c2a9c52eb8/audio.m3u8"))
    }

    func testMediaPlaylistContainsSegmentURL() throws {
        let sessionID = UUID(uuidString: "F6D87659-63D8-4D64-B952-F4C2A9C52EB8")!
        let playlist = try XCTUnwrap(
            NativePlaybackProxyUtilities.makeMediaPlaylist(
                scheme: "newbi-proxy",
                sessionID: sessionID,
                segmentPath: "/video.segment"
            )
        )

        XCTAssertTrue(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(playlist.contains("newbi-proxy://f6d87659-63d8-4d64-b952-f4c2a9c52eb8/video.segment"))
    }

    func testRangeHeaderGeneration() {
        XCTAssertEqual(
            NativePlaybackProxyUtilities.makeRangeHeader(requestedOffset: 1024, currentOffset: 0, requestedLength: 2048),
            "bytes=1024-3071"
        )
        XCTAssertEqual(
            NativePlaybackProxyUtilities.makeRangeHeader(requestedOffset: 2048, currentOffset: 4096, requestedLength: 0),
            "bytes=4096-"
        )
        XCTAssertNil(
            NativePlaybackProxyUtilities.makeRangeHeader(requestedOffset: 0, currentOffset: 0, requestedLength: 0)
        )
    }

    func testForwardHeadersContainRefererOriginAndUserAgent() {
        let headers = NativePlaybackProxyUtilities.buildForwardHeaders(
            base: .bilibiliDefault,
            range: "bytes=0-1023"
        )

        XCTAssertEqual(headers["Referer"], "https://www.bilibili.com")
        XCTAssertEqual(headers["Origin"], "https://www.bilibili.com")
        XCTAssertTrue(headers["User-Agent"]?.contains("Mozilla/5.0") == true)
        XCTAssertEqual(headers["Range"], "bytes=0-1023")
    }
}
