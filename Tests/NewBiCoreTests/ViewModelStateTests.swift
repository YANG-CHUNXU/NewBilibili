import Foundation
import XCTest
@testable import NewBiCore

private actor MockBiliClient: BiliPublicClient {
    enum Mode {
        case success([VideoCard])
        case failure(Error)
    }

    struct DetailStep {
        let result: Result<VideoDetail, Error>
        let delayNanoseconds: UInt64

        init(result: Result<VideoDetail, Error>, delayNanoseconds: UInt64 = 0) {
            self.result = result
            self.delayNanoseconds = delayNanoseconds
        }
    }

    let mode: Mode
    private var detailStepsByBVID: [String: [DetailStep]]
    private var detailFetchCountByBVID: [String: Int] = [:]

    init(
        mode: Mode,
        detailStepsByBVID: [String: [DetailStep]] = [:]
    ) {
        self.mode = mode
        self.detailStepsByBVID = detailStepsByBVID
    }

    func fetchSubscriptionVideos(uid: String) async throws -> [VideoCard] {
        switch mode {
        case .success(let cards):
            return cards
        case .failure(let error):
            throw error
        }
    }

    func fetchFollowingVideos(maxPages: Int) async throws -> [VideoCard] {
        switch mode {
        case .success(let cards):
            return cards
        case .failure(let error):
            throw error
        }
    }

    func searchVideos(keyword: String, page: Int) async throws -> [VideoCard] {
        switch mode {
        case .success(let cards):
            return cards
        case .failure(let error):
            throw error
        }
    }

    func fetchVideoDetail(bvid: String) async throws -> VideoDetail {
        detailFetchCountByBVID[bvid, default: 0] += 1

        var steps = detailStepsByBVID[bvid] ?? []
        guard !steps.isEmpty else {
            throw BiliClientError.parseFailed("not used")
        }

        let step = steps.removeFirst()
        detailStepsByBVID[bvid] = steps

        if step.delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: step.delayNanoseconds)
        }

        switch step.result {
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

private actor KeywordMockBiliClient: BiliPublicClient {
    struct DetailStep {
        let result: Result<VideoDetail, Error>
        let delayNanoseconds: UInt64
    }

    private let searchResultsByKeyword: [String: [VideoCard]]
    private var detailStepsByBVID: [String: [DetailStep]]

    init(
        searchResultsByKeyword: [String: [VideoCard]],
        detailStepsByBVID: [String: [DetailStep]]
    ) {
        self.searchResultsByKeyword = searchResultsByKeyword
        self.detailStepsByBVID = detailStepsByBVID
    }

    func fetchSubscriptionVideos(uid: String) async throws -> [VideoCard] {
        []
    }

    func fetchFollowingVideos(maxPages: Int) async throws -> [VideoCard] {
        []
    }

    func searchVideos(keyword: String, page: Int) async throws -> [VideoCard] {
        searchResultsByKeyword[keyword, default: []]
    }

    func fetchVideoDetail(bvid: String) async throws -> VideoDetail {
        var steps = detailStepsByBVID[bvid] ?? []
        guard !steps.isEmpty else {
            throw BiliClientError.parseFailed("missing detail step")
        }
        let step = steps.removeFirst()
        detailStepsByBVID[bvid] = steps

        if step.delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: step.delayNanoseconds)
        }

        switch step.result {
        case .success(let detail):
            return detail
        case .failure(let error):
            throw error
        }
    }

    func resolvePlayableStream(bvid: String, cid: Int?) async throws -> PlayableStream {
        throw BiliClientError.noPlayableStream
    }
}

final class ViewModelStateTests: XCTestCase {
    @MainActor
    func testSearchViewModelSuccessState() async {
        let card = makeCard(bvid: "BV1", title: "ok", durationText: "00:10")
        let vm = SearchViewModel(biliClient: MockBiliClient(mode: .success([card])))
        vm.keyword = "test"
        vm.page = 1

        await vm.search()

        XCTAssertEqual(vm.results.count, 1)
        XCTAssertEqual(vm.results.first?.durationText, "00:10")
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testSearchViewModelFailureState() async {
        let vm = SearchViewModel(biliClient: MockBiliClient(mode: .failure(BiliClientError.networkFailed("x"))))
        vm.keyword = "test"
        vm.page = 1

        await vm.search()

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testHomeViewModelSuccessState() async {
        let card = makeCard(bvid: "BV1", title: "ok", durationText: "00:20", publishTime: Date())
        let vm = HomeFeedViewModel(
            biliClient: MockBiliClient(mode: .success([card]))
        )

        await vm.load()

        XCTAssertEqual(vm.videos.count, 1)
        XCTAssertEqual(vm.videos.first?.durationText, "00:20")
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testHomeViewModelRequiresLoginBeforeLoading() async {
        let card = makeCard(bvid: "BV_LOGIN", title: "login", durationText: "00:20", publishTime: Date())
        let vm = HomeFeedViewModel(
            biliClient: MockBiliClient(mode: .success([card])),
            isAuthenticatedProvider: { false }
        )

        await vm.load()

        XCTAssertTrue(vm.videos.isEmpty)
        XCTAssertEqual(vm.errorMessage, BiliClientError.authRequired("请先在“我的”页登录 B 站账号").errorDescription)
    }

    @MainActor
    func testHomeViewModelKeepsOnlyRecentDayAndSortsDesc() async {
        let now = Date()
        let newest = makeCard(
            bvid: "BV_NEWEST",
            title: "newest",
            durationText: "01:00",
            publishTime: now.addingTimeInterval(-60)
        )
        let olderButWithinDay = makeCard(
            bvid: "BV_OLDER",
            title: "older",
            durationText: "02:00",
            publishTime: now.addingTimeInterval(-23 * 60 * 60)
        )
        let outdated = makeCard(
            bvid: "BV_OLD",
            title: "old",
            durationText: "03:00",
            publishTime: now.addingTimeInterval(-25 * 60 * 60)
        )
        let missingPublishTime = makeCard(
            bvid: "BV_NIL",
            title: "nil",
            durationText: "04:00",
            publishTime: nil
        )

        let vm = HomeFeedViewModel(
            biliClient: MockBiliClient(mode: .success([olderButWithinDay, missingPublishTime, outdated, newest]))
        )

        await vm.load()

        XCTAssertEqual(vm.videos.map(\.bvid), ["BV_NEWEST", "BV_OLDER"])
    }

    @MainActor
    func testSearchViewModelHydratesMissingDurationWithFallbackThenResolved() async {
        let bvid = "BV1SEARCHHYDRATE"
        let card = makeCard(bvid: bvid, title: "search", durationText: nil)
        let client = MockBiliClient(
            mode: .success([card]),
            detailStepsByBVID: [
                bvid: [
                    .init(
                        result: .success(makeDetail(bvid: bvid, partDurations: [65])),
                        delayNanoseconds: 120_000_000
                    )
                ]
            ]
        )
        let vm = SearchViewModel(
            biliClient: client,
            durationHydrator: VideoDurationHydrator(),
            maxConcurrentDurationHydration: 4
        )
        vm.keyword = "test"
        vm.page = 1

        await vm.search()

        XCTAssertEqual(vm.results.first?.durationText, "未知时长")
        let updated = await waitUntil {
            vm.results.first?.durationText == "01:05"
        }
        XCTAssertTrue(updated)
    }

    @MainActor
    func testSearchViewModelKeepsUnknownDurationWhenHydrationFails() async {
        let bvid = "BV1SEARCHFAIL"
        let card = makeCard(bvid: bvid, title: "search", durationText: nil)
        let client = MockBiliClient(
            mode: .success([card]),
            detailStepsByBVID: [
                bvid: [
                    .init(
                        result: .failure(BiliClientError.networkFailed("detail error")),
                        delayNanoseconds: 60_000_000
                    )
                ]
            ]
        )
        let vm = SearchViewModel(
            biliClient: client,
            durationHydrator: VideoDurationHydrator(),
            maxConcurrentDurationHydration: 4
        )
        vm.keyword = "test"
        vm.page = 1

        await vm.search()

        XCTAssertEqual(vm.results.first?.durationText, "未知时长")
        let fetched = await waitUntil {
            let count = await client.detailFetchCount(for: bvid)
            return count == 1
        }
        XCTAssertTrue(fetched)
        XCTAssertEqual(vm.results.first?.durationText, "未知时长")
    }

    @MainActor
    func testHomeViewModelHydratesMissingDurationWithFallbackThenResolved() async {
        let bvid = "BV1HOMEHYDRATE"
        let card = makeCard(bvid: bvid, title: "home", durationText: nil, publishTime: Date())
        let client = MockBiliClient(
            mode: .success([card]),
            detailStepsByBVID: [
                bvid: [
                    .init(
                        result: .success(makeDetail(bvid: bvid, partDurations: [100, 25])),
                        delayNanoseconds: 100_000_000
                    )
                ]
            ]
        )
        let vm = HomeFeedViewModel(
            biliClient: client,
            durationHydrator: VideoDurationHydrator(),
            maxConcurrentDurationHydration: 4
        )

        await vm.load()

        XCTAssertEqual(vm.videos.first?.durationText, "未知时长")
        let updated = await waitUntil {
            vm.videos.first?.durationText == "02:05"
        }
        XCTAssertTrue(updated)
    }

    @MainActor
    func testSearchViewModelNewSearchIgnoresOldHydrationResult() async {
        let oldBVID = "BV1OLD"
        let newBVID = "BV1NEW"
        let oldCard = makeCard(bvid: oldBVID, title: "old", durationText: nil)
        let newCard = makeCard(bvid: newBVID, title: "new", durationText: nil)

        let client = KeywordMockBiliClient(
            searchResultsByKeyword: [
                "first": [oldCard],
                "second": [newCard]
            ],
            detailStepsByBVID: [
                oldBVID: [
                    .init(
                        result: .success(makeDetail(bvid: oldBVID, partDurations: [300])),
                        delayNanoseconds: 300_000_000
                    )
                ],
                newBVID: [
                    .init(
                        result: .success(makeDetail(bvid: newBVID, partDurations: [90])),
                        delayNanoseconds: 20_000_000
                    )
                ]
            ]
        )

        let vm = SearchViewModel(
            biliClient: client,
            durationHydrator: VideoDurationHydrator(),
            maxConcurrentDurationHydration: 4
        )

        vm.keyword = "first"
        vm.page = 1
        await vm.search()
        XCTAssertEqual(vm.results.first?.bvid, oldBVID)
        XCTAssertEqual(vm.results.first?.durationText, "未知时长")

        vm.keyword = "second"
        await vm.search()
        XCTAssertEqual(vm.results.first?.bvid, newBVID)

        let newHydrated = await waitUntil {
            vm.results.first?.bvid == newBVID && vm.results.first?.durationText == "01:30"
        }
        XCTAssertTrue(newHydrated)

        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.results.first?.bvid, newBVID)
        XCTAssertEqual(vm.results.first?.durationText, "01:30")
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 1.2,
        intervalNanoseconds: UInt64 = 20_000_000,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return await condition()
    }

    private func makeCard(
        bvid: String,
        title: String,
        durationText: String?,
        publishTime: Date? = nil
    ) -> VideoCard {
        VideoCard(
            id: bvid,
            bvid: bvid,
            title: title,
            coverURL: nil,
            authorName: "u",
            authorUID: nil,
            durationText: durationText,
            publishTime: publishTime
        )
    }

    private func makeDetail(bvid: String, partDurations: [Int?]) -> VideoDetail {
        let parts = partDurations.enumerated().map { index, duration in
            VideoPart(
                cid: index + 1,
                page: index + 1,
                title: "P\(index + 1)",
                durationSeconds: duration
            )
        }
        return VideoDetail(
            bvid: bvid,
            title: bvid,
            description: nil,
            authorName: "u",
            parts: parts,
            stats: nil
        )
    }
}
