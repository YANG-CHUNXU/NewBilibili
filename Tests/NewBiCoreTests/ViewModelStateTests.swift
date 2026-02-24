import Foundation
import XCTest
@testable import NewBiCore

private actor MockSubscriptionRepository: SubscriptionRepository {
    let items: [Subscription]

    init(items: [Subscription]) {
        self.items = items
    }

    func list() async throws -> [Subscription] {
        items
    }

    func add(input: String) async throws -> Subscription {
        throw BiliClientError.invalidInput("not used")
    }

    func remove(id: UUID) async throws {}
}

private actor MockBiliClient: BiliPublicClient {
    enum Mode {
        case success([VideoCard])
        case failure(Error)
    }

    let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func fetchSubscriptionVideos(uid: String) async throws -> [VideoCard] {
        switch mode {
        case .success(let cards): return cards
        case .failure(let error): throw error
        }
    }

    func searchVideos(keyword: String, page: Int) async throws -> [VideoCard] {
        switch mode {
        case .success(let cards): return cards
        case .failure(let error): throw error
        }
    }

    func fetchVideoDetail(bvid: String) async throws -> VideoDetail {
        throw BiliClientError.parseFailed("not used")
    }

    func resolvePlayableStream(bvid: String, cid: Int?) async throws -> PlayableStream {
        throw BiliClientError.noPlayableStream
    }
}

final class ViewModelStateTests: XCTestCase {
    @MainActor
    func testSearchViewModelSuccessState() async {
        let card = VideoCard(
            id: "BV1",
            bvid: "BV1",
            title: "ok",
            coverURL: nil,
            authorName: "u",
            authorUID: nil,
            durationText: nil,
            publishTime: nil
        )

        let vm = SearchViewModel(biliClient: MockBiliClient(mode: .success([card])))
        vm.keyword = "test"
        vm.page = 1

        await vm.search()

        XCTAssertEqual(vm.results.count, 1)
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
        let subA = Subscription(
            id: UUID(),
            uid: "1001",
            homepageURL: URL(string: "https://space.bilibili.com/1001")!,
            createdAt: Date()
        )
        let repository = MockSubscriptionRepository(items: [subA])

        let card = VideoCard(
            id: "BV1",
            bvid: "BV1",
            title: "ok",
            coverURL: nil,
            authorName: "u",
            authorUID: nil,
            durationText: nil,
            publishTime: Date()
        )

        let vm = HomeFeedViewModel(
            subscriptionRepository: repository,
            biliClient: MockBiliClient(mode: .success([card]))
        )

        await vm.load()

        XCTAssertEqual(vm.videos.count, 1)
        XCTAssertFalse(vm.isLoading)
    }
}
