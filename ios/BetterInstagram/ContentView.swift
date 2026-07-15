import SwiftUI

struct ContentView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var bridge: WebBridge
    @StateObject private var favoritesStore: FavoritesStore
    @StateObject private var store: WebViewStore
    @State private var selectedTab: NavTarget = .home
    @State private var avatarImage: UIImage?
    @State private var showOnboarding = false
    @State private var showFavoritesEditor = false
    @State private var hasBeenReadyOnce = false
    @State private var resaveRequested = false

    init() {
        let bridge = WebBridge()
        let favorites = FavoritesStore()
        _bridge = StateObject(wrappedValue: bridge)
        _favoritesStore = StateObject(wrappedValue: favorites)
        _store = StateObject(wrappedValue: WebViewStore(bridge: bridge, favorites: favorites))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: NavTarget.home) {
                webContent(for: .home)
            } label: {
                tabIcon("nav-home")
            }
            Tab(value: NavTarget.search) {
                webContent(for: .search)
            } label: {
                tabIcon("nav-search")
            }
            Tab(value: NavTarget.direct) {
                webContent(for: .direct)
            } label: {
                tabIcon("nav-send")
            }
            Tab(value: NavTarget.profile) {
                webContent(for: .profile)
            } label: {
                profileTabIcon
            }
        }
        .tint(.primary)
        .onChange(of: selectedTab) { _, newValue in
            store.setActive(newValue)
        }
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
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            case .resave:
                ResaveSplashView()
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            case .none:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.45), value: activeSplash)
    }

    private enum SplashKind: Equatable { case launch, resave }

    /// Which full-screen splash (if any) to show. Both cover the harvest + reload
    /// so the user never sees the feed being assembled — they fire instantly
    /// (identity insertion) and only fade out. The first time (feed never ready
    /// yet) shows the branded launch splash; any later gap is only produced by
    /// re-saving favorites, so it shows the update splash.
    private var activeSplash: SplashKind? {
        guard store.isLoggedIn, favoritesStore.isFilterEnabled else { return nil }
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
        WebViewContainer(webView: store.webView(for: target))
            .ignoresSafeArea(edges: reduceTransparency ? [] : .bottom)
            .background(bridge.pageBackground.ignoresSafeArea())
            .toolbarVisibility(isTabBarVisible ? .visible : .hidden, for: .tabBar)
    }
}

/// The official "from Meta" footer: grey "from" over the official Meta company
/// lockup asset (blue-gradient mark + white "Meta").
private struct MetaFooter: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("from")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.45))
            Image("MetaLockup")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(height: 40)
        }
        .padding(.bottom, 46)
    }
}

/// Branded cold-start splash matching Instagram's real dark launch screen: pure
/// black, the official Instagram gradient glyph centered, and a "from Meta"
/// footer using the official Meta lockup.
private struct LaunchSplashView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image("InstagramGlyph")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: 84, height: 84)

            VStack {
                Spacer()
                MetaFooter()
            }
        }
    }
}

/// Update splash shown while re-saving favorites re-harvests + reloads the feed,
/// so the swap happens behind a clean screen. Same black + official-brand style
/// as the launch splash; the glyph does not animate.
private struct ResaveSplashView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Image("InstagramGlyph")
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 84, height: 84)
                Text("Updating your favorites…")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.6))
                ProgressView()
                    .tint(Color.white.opacity(0.7))
            }
            VStack {
                Spacer()
                MetaFooter()
            }
        }
    }
}
