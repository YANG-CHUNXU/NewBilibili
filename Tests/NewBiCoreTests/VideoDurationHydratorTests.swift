import Foundation
import XCTest
@testable import NewBiCore

private actor DurationHydratorMockClient: BiliPublicClient {
    enum DetailResponse {
        case success(VideoDetail)
        case failure(Error)
    }

    private var detailResponsesByBVID: [String: DetailResponse]
    private let detailDelayNanoseconds: UInt64
    private var detailFetchCountByBVID: [String: Int] = [:]

    init(
        detailResponsesByBVID: [String: DetailResponse],
        detailDelayNanoseconds: UInt64 = 0
    ) {
        self.detailResponsesByBVID = detailResponsesByBVID
        self.detailDelayNanoseconds = detailDelayNanoseconds
    }

    func fetchSubscriptionVideos(uid: String) async throws -> [VideoCard] {
        []
    }

    func fetchFollowingVideos(maxPages: Int) async throws -> [VideoCard] {
        []
    }

    func searchVideos(keyword: String, page: Int) async throws -> [VideoCard] {
        []
    }

    func fetchVideoDetail(bvid: String) async throws -> VideoDetail {
        detailFetchCountByBVID[bvid, default: 0] += 1
        if detailDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: detailDelayNanoseconds)
        }

        guard let response = detailResponsesByBVID[bvid] else {
            throw BiliClientError.parseFailed("missing detail response")
        }
        switch response {
        case .success(let detail):
            return detail
        case .failure(let error):
            throw error
        }
    }

    func resolvePlayableStream(bvid: String, cid: Int?) async throws -> PlayableStream {
        throw BiliClientError.noPlayableStream
    }

    func detailFetchCount(for bvid: String) -> Int {
        detailFetchCountByBVID[bvid, default: 0]
    }
}

final class VideoDurationHydratorTests: XCTestCase {
    func testResolveDurationTextUsesSinglePartDuration() async {
        let bvid = "BV1SINGLE"
        let client = DurationHydratorMockClient(
            detailResponsesByBVID: [
                bvid: .success(makeDetail(bvid: bvid, partDurations: [185]))
            ]
        )
        let hydrator = VideoDurationHydrator()

        let resolved = await hydrator.resolveDurationText(bvid: bvid, using: client)

        XCTAssertEqual(resolved, "03:05")
        let fetchCount = await client.detailFetchCount(for: bvid)
        XCTAssertEqual(fetchCount, 1)
    }

    func testResolveDurationTextSumsMultiPartDurations() async {
        let bvid = "BV1MULTI"
        let client = DurationHydratorMockClient(
            detailResponsesByBVID: [
                bvid: .success(makeDetail(bvid: bvid, partDurations: [120, nil, 45, 0, -1, 90]))
            ]
        )
        let hydrator = VideoDurationHydrator()

        let resolved = await hydrator.resolveDurationText(bvid: bvid, using: client)

        XCTAssertEqual(resolved, "04:15")
    }

    func testResolveDurationTextDeduplicatesConcurrentRequests() async {
        let bvid = "BV1DEDUP"
        let client = DurationHydratorMockClient(
            detailResponsesByBVID: [
                bvid: .success(makeDetail(bvid: bvid, partDurations: [61]))
            ],
            detailDelayNanoseconds: 80_000_000
        )
        let hydrator = VideoDurationHydrator()

        async let first = hydrator.resolveDurationText(bvid: bvid, using: client)
        async let second = hydrator.resolveDurationText(bvid: bvid, using: client)
        let (a, b) = await (first, second)

        XCTAssertEqual(a, "01:01")
        XCTAssertEqual(b, "01:01")
        let fetchCount = await client.detailFetchCount(for: bvid)
        XCTAssertEqual(fetchCount, 1)
    }

    func testResolveDurationTextRespectsFailureCooldown() async {
        let bvid = "BV1FAIL"
        let client = DurationHydratorMockClient(
            detailResponsesByBVID: [
                bvid: .failure(BiliClientError.networkFailed("detail failed"))
            ]
        )
        let hydrator = VideoDurationHydrator(failureCooldown: 10 * 60)

        let first = await hydrator.resolveDurationText(bvid: bvid, using: client)
        let second = await hydrator.resolveDurationText(bvid: bvid, using: client)

        XCTAssertNil(first)
        XCTAssertNil(second)
        let fetchCount = await client.detailFetchCount(for: bvid)
        XCTAssertEqual(fetchCount, 1)
    }

    private func makeDetail(bvid: String, partDurations: [Int?]) -> VideoDetail {
        let parts = partDurations.enumerated().map { index, duration in
            VideoPart(
                cid: 1000 + index,
                page: index + 1,
                title: "P\(index + 1)",
                durationSeconds: duration
            )
        }
        return VideoDetail(
            bvid: bvid,
            title: bvid,
            description: nil,
            authorName: "tester",
            parts: parts,
            stats: nil
        )
    }
}
