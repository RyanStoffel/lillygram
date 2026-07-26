import SwiftUI

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var bridge: WebBridge
    @StateObject private var favoritesStore: FavoritesStore
    @StateObject private var store: WebViewStore
    @State private var selectedTab: NavTarget = .home
    // Home is created by WebViewStore; the other tabs are preloaded on appear.
    // This tracks which tabs SwiftUI can render with their persistent webview.
    @State private var createdTabs: Set<NavTarget> = [.home]
    @State private var avatarImage: UIImage?
    @State private var showOnboarding = false
    @State private var showFavoritesEditor = false
    @State private var hasBeenReadyOnce = false
    @State private var resaveRequested = false
    @State private var didPreloadTabs = false

    init() {
        let bridge = WebBridge()
        let favorites = FavoritesStore()
        _bridge = StateObject(wrappedValue: bridge)
        _favoritesStore = StateObject(wrappedValue: favorites)
        _store = StateObject(wrappedValue: WebViewStore(bridge: bridge, favorites: favorites))
    }

    var body: some View {
        ZStack {
            TabView(selection: tabSelection) {
                Tab(value: NavTarget.home) {
                    webContent(for: .home)
                } label: {
                    tabIcon("nav-home")
                        .accessibilityLabel("Home")
                }
                Tab(value: NavTarget.search) {
                    webContent(for: .search)
                } label: {
                    tabIcon("nav-search")
                        .accessibilityLabel("Search")
                }
                Tab(value: NavTarget.direct) {
                    webContent(for: .direct)
                } label: {
                    tabIcon("nav-send")
                        .accessibilityLabel("Messages")
                }
                Tab(value: NavTarget.profile) {
                    webContent(for: .profile)
                } label: {
                    profileTabIcon
                        .accessibilityLabel("Profile")
                }
            }
            .tint(.primary)
            .onChange(of: store.isLoggedIn) { _, _ in
                refreshOnboarding()
            }
            .onChange(of: bridge.favoritesEditRequests) { _, _ in
                showFavoritesEditor = true
            }
            .onChange(of: store.favoritesFeedReady) { _, ready in
                if ready {
                    hasBeenReadyOnce = true
                    resaveRequested = false
                }
            }
            .onAppear {
                refreshOnboarding()
                preloadSecondaryTabs()
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            favoritesPicker(mode: .onboarding)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showFavoritesEditor) {
            favoritesPicker(mode: .editor)
        }
        .task(id: bridge.avatarURL) {
            guard let url = bridge.avatarURL else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            avatarImage = image
        }
        .overlay {
            switch activeSplash {
            case .launch:
                LaunchSplashView()
                    .transition(splashTransition)
            case .resave:
                ResaveSplashView()
                    .transition(splashTransition)
            case .none:
                EmptyView()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: activeSplash)
        .overlay {
            if store.feedStuck && selectedTab == .home {
                FeedErrorView(retry: { store.retryFavoritesFeed() })
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: store.feedStuck)
    }

    private enum SplashKind: Equatable { case launch, resave }

    private var tabSelection: Binding<NavTarget> {
        Binding(
            get: { selectedTab },
            set: { target in
                store.setActive(target)
                createdTabs.insert(target)
                selectedTab = target
            }
        )
    }

    private var splashTransition: AnyTransition {
        reduceMotion ? .identity : .asymmetric(insertion: .identity, removal: .opacity)
    }

    /// Which full-screen splash (if any) to show. Both cover the harvest + reload
    /// so the user never sees the feed being assembled — they fire instantly
    /// (identity insertion) and only fade out. The first time (feed never ready
    /// yet) shows the branded launch splash; any later gap is only produced by
    /// re-saving favorites, so it shows the update splash.
    private var activeSplash: SplashKind? {
        guard store.isLoggedIn, favoritesStore.isFilterEnabled else { return nil }
        // Pull-to-refresh shows the branded launch splash over the rebuild.
        if store.refreshingViaPull { return .launch }
        // A just-tapped Save forces the update splash immediately, even before
        // the feed-ready flag has flipped (it's still stale-true for a moment).
        if resaveRequested { return .resave }
        guard !store.favoritesFeedReady else { return nil }
        return hasBeenReadyOnce ? .resave : .launch
    }

    private var isTabBarVisible: Bool {
        store.isLoggedIn && bridge.isNavVisible
    }

    private func refreshOnboarding() {
        if store.isLoggedIn && !favoritesStore.hasCompletedOnboarding {
            showOnboarding = true
        }
    }

    /// Creates every tab's webview immediately instead of waiting for its
    /// first visit, so all four are already warm by the time the user
    /// switches — using the launch splash's own dead time (already covering
    /// the favorites harvest) to hide this instead of adding a new one.
    /// store.webView(for:) triggers real creation regardless of whether
    /// SwiftUI has rendered that tab's content yet; marking createdTabs
    /// up front means webContent(for:) shows the real webview the first
    /// time each tab is actually selected, never the loading placeholder.
    private func preloadSecondaryTabs() {
        guard !didPreloadTabs else { return }
        didPreloadTabs = true
        for target in NavTarget.allCases where target != .home {
            _ = store.webView(for: target)
            createdTabs.insert(target)
        }
    }

    private func favoritesPicker(mode: FavoritesPickerView.Mode) -> some View {
        FavoritesPickerView(
            mode: mode,
            favoritesStore: favoritesStore,
            loadFollowing: { await store.fetchFollowing() },
            search: { await store.searchProfiles(matching: $0) },
            onCommit: { picked in
                // Show the update splash the instant Save is tapped (only when the
                // feed has rendered before — first-time onboarding uses the launch
                // splash). Set before dismissing the sheet so the splash is already
                // behind it and no feed flash shows through.
                resaveRequested = hasBeenReadyOnce
                favoritesStore.favorites = picked
                favoritesStore.hasCompletedOnboarding = true
                store.applyFavoritesSelection()
                showOnboarding = false
                showFavoritesEditor = false
            },
            onSkip: mode == .onboarding ? {
                favoritesStore.favorites = []
                favoritesStore.hasCompletedOnboarding = true
                store.applyFavoritesSelection()
                showOnboarding = false
            } : nil
        )
    }

    private var profileTabIcon: Image {
        guard let avatarImage else {
            return Image(systemName: "person.crop.circle")
        }
        let size = CGSize(width: 24, height: 24)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
            avatarImage.draw(in: CGRect(origin: .zero, size: size))
        }
        return Image(uiImage: rendered.withRenderingMode(.alwaysOriginal))
    }

    private func tabIcon(_ name: String) -> Image {
        guard let source = UIImage(named: name) else {
            return Image(systemName: "questionmark")
        }
        let size = CGSize(width: 24, height: 24)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        return Image(uiImage: resized.withRenderingMode(.alwaysTemplate))
    }

    private func webContent(for target: NavTarget) -> some View {
        Group {
            if createdTabs.contains(target) {
                WebViewContainer(webView: store.webView(for: target))
                    .ignoresSafeArea(edges: reduceTransparency ? [] : .all)
            } else {
                // Shown for the instant it takes to create+load the webview on
                // this tab's first visit only; already-created tabs never see it.
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .overlay(ProgressView())
            }
        }
        .toolbarVisibility(isTabBarVisible ? .visible : .hidden, for: .tabBar)
    }
}

/// Shown when the favorites feed is confirmed stuck (splice landed but Instagram
/// never rendered) even after an automatic recovery — so the user gets a clean
/// retry instead of a permanent spinner. No algorithmic content is shown.
private struct FeedErrorView: View {
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "star.slash")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .accessibilityHidden(true)
                Text("Couldn't load your favorites")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text("Instagram may have changed something. Try again in a moment.")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button(action: retry) {
                    Text("Retry")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .padding(.top, 4)
                .accessibilityHint("Tries loading your favorites feed again")
            }
        }
    }
}

/// The "from RYAN STOFFEL" attribution footer.
private struct AttributionFooter: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("from")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.45))
            Text("RYAN STOFFEL")
                .font(.system(size: 20, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white)
        }
        .padding(.bottom, 46)
    }
}

/// The Lillygram app icon, rendered as a rounded app-icon tile.
private struct AppIconMark: View {
    let size: CGFloat
    var body: some View {
        Image("LillygramIcon")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Branded cold-start splash: pure black, the Lillygram app icon centered, and a
/// "from RYAN STOFFEL" footer.
private struct LaunchSplashView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 22) {
                AppIconMark(size: 84)
                ProgressView()
                    .tint(Color.white.opacity(0.7))
                    .accessibilityLabel("Loading your favorites feed")
            }

            VStack {
                Spacer()
                AttributionFooter()
            }
        }
    }
}

/// Update splash shown while re-saving favorites re-harvests + reloads the feed,
/// so the swap happens behind a clean screen. Same style as the launch splash;
/// the icon does not animate.
private struct ResaveSplashView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                AppIconMark(size: 84)
                Text("Updating your favorites…")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.6))
                ProgressView()
                    .tint(Color.white.opacity(0.7))
                    .accessibilityLabel("Updating your favorites feed")
            }
            VStack {
                Spacer()
                AttributionFooter()
            }
        }
    }
}
