import SwiftUI
import NewBiCore

struct ContentView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(
                    viewModel: HomeFeedViewModel(
                        subscriptionRepository: environment.subscriptionRepository,
                        biliClient: environment.biliClient
                    ),
                    biliClient: environment.biliClient,
                    historyRepository: environment.watchHistoryRepository,
                    playbackItemFactory: environment.playbackItemFactory
                )
            }
            .tabItem {
                Label("首页", systemImage: "house")
            }

            NavigationStack {
                SearchView(
                    viewModel: SearchViewModel(biliClient: environment.biliClient),
                    biliClient: environment.biliClient,
                    historyRepository: environment.watchHistoryRepository,
                    playbackItemFactory: environment.playbackItemFactory
                )
            }
            .tabItem {
                Label("搜索", systemImage: "magnifyingglass")
            }

            NavigationStack {
                SubscriptionsView(
                    viewModel: SubscriptionListViewModel(
                        subscriptionRepository: environment.subscriptionRepository,
                        watchHistoryRepository: environment.watchHistoryRepository
                    )
                )
            }
            .tabItem {
                Label("订阅", systemImage: "person.crop.circle.badge.plus")
            }
        }
    }
}
