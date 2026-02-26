import SwiftUI
import NewBiCore

struct ContentView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(
                    viewModel: HomeFeedViewModel(
                        biliClient: environment.biliClient,
                        isAuthenticatedProvider: {
                            environment.bilibiliCookieConfigured
                        }
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
                        watchHistoryRepository: environment.watchHistoryRepository,
                        historySyncCoordinator: environment.historySyncCoordinator
                    )
                )
            }
            .tabItem {
                Label("我的", systemImage: "person.crop.circle")
            }
        }
        .onAppear {
            environment.notifySceneActive(true)
        }
        .onChange(of: scenePhase) { newValue in
            environment.notifySceneActive(newValue == .active)
        }
    }
}
