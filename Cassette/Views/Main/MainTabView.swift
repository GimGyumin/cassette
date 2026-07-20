// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct MainTabView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var searchPath = NavigationPath()
    @State private var homePath = NavigationPath()
    @State private var selectedTab: AppTab = .home
    @State private var showingFullPlayer = false
    @Namespace private var playerZoom
    private let fullPlayerZoomID = "full-player"
    
    private enum AppTab: Hashable { case home, discover, search }
    
    private var hasTrack: Bool {
        container?.playerState.currentTrack != nil || container?.playerState.isLiveStream == true
    }
    
    // MARK: - Tabs View
    @ViewBuilder
    private var tabs: some View {
        TabView(selection: $selectedTab) {
            // 1. Home Tab
            NavigationStack(path: $homePath) {
                HomeView()
            }
            .tabItem {
                Label("홈", systemImage: "house.fill")
            }
            .tag(AppTab.home)
            
            // 2. Discover Tab
            NavigationStack {
                DiscoverView()
            }
            .tabItem {
                Label("찾아보기", systemImage: "safari.fill")
            }
            .tag(AppTab.discover)
            
            // 3. Search Tab (매개변수 이름을 searchQuery와 path로 정확히 매칭)
            NavigationStack(path: $searchPath) {
                SearchView(searchQuery: $searchText, path: $searchPath)
            }
            .tabItem {
                Label("검색", systemImage: "magnifyingglass")
            }
            .tag(AppTab.search)
        }
    }
    
    var body: some View {
#if os(iOS)
        if #available(iOS 26.0, *) {
            tabs
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory {
                    if hasTrack {
                        MiniPlayerAccessoryView(
                            showingFullPlayer: $showingFullPlayer
                        )
                        .environment(
                            \.colorScheme,
                             colorScheme
                        )
                        .cassetteMatchedTransitionSource(
                            id: fullPlayerZoomID,
                            in: playerZoom
                        )
                    }
                }
                .fullScreenCover(
                    isPresented: $showingFullPlayer
                ) {
                    FullPlayerView()
                        .cassetteZoomTransition(
                            sourceID: fullPlayerZoomID,
                            in: playerZoom
                        )
                }
        } else {
            tabs
                .safeAreaInset(edge: .bottom) {
                    if hasTrack {
                        MiniPlayerAccessoryView(
                            showingFullPlayer: $showingFullPlayer
                        )
                    }
                }
                .fullScreenCover(
                    isPresented: $showingFullPlayer
                ) {
                    FullPlayerView()
                }
        }
#else
        tabs
            .safeAreaInset(edge: .bottom) {
                if hasTrack {
                    MiniPlayerAccessoryView(
                        showingFullPlayer: $showingFullPlayer
                    )
                }
            }
            .sheet(
                isPresented: $showingFullPlayer
            ) {
                FullPlayerView()
            }
#endif
    }
}
