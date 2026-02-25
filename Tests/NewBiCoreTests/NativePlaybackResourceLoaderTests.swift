import Foundation
import XCTest
@_spi(PlaybackProxy) @testable import NewBiCore

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

    func testMediaPlaylistWithMultipleSegments() throws {
        let sessionID = UUID(uuidString: "F6D87659-63D8-4D64-B952-F4C2A9C52EB8")!
        let playlist = try XCTUnwrap(
            NativePlaybackProxyUtilities.makeMediaPlaylist(
                scheme: "newbi-proxy",
                sessionID: sessionID,
                segments: [
                    .init(segmentPath: "/progressive/0.segment", durationSeconds: 30),
                    .init(segmentPath: "/progressive/1.segment", durationSeconds: 45)
                ]
            )
        )

        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:45"))
        XCTAssertTrue(playlist.contains("newbi-proxy://f6d87659-63d8-4d64-b952-f4c2a9c52eb8/progressive/0.segment"))
        XCTAssertTrue(playlist.contains("newbi-proxy://f6d87659-63d8-4d64-b952-f4c2a9c52eb8/progressive/1.segment"))
        XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"))
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

    func testDeduplicatedCandidateURLsPreservesOrder() {
        let a = URL(string: "https://example.com/a.m4s")!
        let b = URL(string: "https://example.com/b.m4s")!
        let c = URL(string: "https://example.com/c.m4s")!

        let result = NativePlaybackProxyUtilities.deduplicatedCandidateURLs([a, b, a, c, b, c])

        XCTAssertEqual(result, [a, b, c])
    }

    func testPrioritizedCandidateURLsMovesPreferredToFront() {
        let a = URL(string: "https://example.com/a.m4s")!
        let b = URL(string: "https://example.com/b.m4s")!
        let c = URL(string: "https://example.com/c.m4s")!

        let result = NativePlaybackProxyUtilities.prioritizedCandidateURLs([a, b, c], preferred: c)

        XCTAssertEqual(result, [c, a, b])
    }

    func testPrioritizedCandidateURLsKeepsOrderWhenPreferredMissing() {
        let a = URL(string: "https://example.com/a.m4s")!
        let b = URL(string: "https://example.com/b.m4s")!
        let missing = URL(string: "https://example.com/missing.m4s")!

        let result = NativePlaybackProxyUtilities.prioritizedCandidateURLs([a, b], preferred: missing)

        XCTAssertEqual(result, [a, b])
    }

    func testPrioritizedCandidateURLsHandlesDuplicatesWithPreferred() {
        let a = URL(string: "https://example.com/a.m4s")!
        let b = URL(string: "https://example.com/b.m4s")!
        let c = URL(string: "https://example.com/c.m4s")!

        let result = NativePlaybackProxyUtilities.prioritizedCandidateURLs([a, b, a, c, b], preferred: b)

        XCTAssertEqual(result, [b, a, c])
    }

    func testRangeSelectionPrefers206CandidateOverEarlier200Candidate() {
        let first200 = URL(string: "https://example.com/fallback-200.m4s")!
        let later206 = URL(string: "https://example.com/real-206.m4s")!

        let selection = NativePlaybackProxyUtilities.selectRangeCandidate(
            orderedCandidates: [first200, later206],
            probeResults: [
                first200: .fallback200,
                later206: .supports206
            ]
        )

        XCTAssertEqual(selection?.url, later206)
    }

    func testRangeSelectionFallsBackToFirst200WhenNo206Exists() {
        let first200 = URL(string: "https://example.com/first-200.m4s")!
        let second200 = URL(string: "https://example.com/second-200.m4s")!

        let selection = NativePlaybackProxyUtilities.selectRangeCandidate(
            orderedCandidates: [first200, second200],
            probeResults: [
                first200: .fallback200,
                second200: .fallback200
            ]
        )

        XCTAssertEqual(selection?.url, first200)
    }

    func testRangeSelectionSkipsFailuresAndUsesLater206Candidate() {
        let failedA = URL(string: "https://example.com/failed-a.m4s")!
        let failedB = URL(string: "https://example.com/failed-b.m4s")!
        let later206 = URL(string: "https://example.com/later-206.m4s")!

        let selection = NativePlaybackProxyUtilities.selectRangeCandidate(
            orderedCandidates: [failedA, failedB, later206],
            probeResults: [
                failedA: .failed,
                failedB: .failed,
                later206: .supports206
            ]
        )

        XCTAssertEqual(selection?.url, later206)
    }

    func testRangeSelectionMarksPreferredFor206Candidate() {
        let candidate = URL(string: "https://example.com/206.m4s")!

        let selection = NativePlaybackProxyUtilities.selectRangeCandidate(
            orderedCandidates: [candidate],
            probeResults: [candidate: .supports206]
        )

        XCTAssertEqual(selection?.shouldMarkPreferredCandidate, true)
    }

    func testRangeSelectionDoesNotMarkPreferredFor200FallbackCandidate() {
        let candidate = URL(string: "https://example.com/200.m4s")!

        let selection = NativePlaybackProxyUtilities.selectRangeCandidate(
            orderedCandidates: [candidate],
            probeResults: [candidate: .fallback200]
        )

        XCTAssertEqual(selection?.shouldMarkPreferredCandidate, false)
    }

    func testRangeSelectionReturnsNilWhenNoCandidateIsUsable() {
        let failedA = URL(string: "https://example.com/failed-a.m4s")!
        let failedB = URL(string: "https://example.com/failed-b.m4s")!

        let selection = NativePlaybackProxyUtilities.selectRangeCandidate(
            orderedCandidates: [failedA, failedB],
            probeResults: [
                failedA: .failed,
                failedB: .failed
            ]
        )

        XCTAssertNil(selection)
    }
}
