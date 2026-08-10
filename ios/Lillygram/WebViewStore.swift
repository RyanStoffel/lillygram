import SwiftUI
import WebKit

/// `WKUserContentController` and `WKHTTPCookieStore` both retain what you
/// register with them, and `WebViewStore` retains the controller — registering
/// `self` directly makes the store immortal. These forward weakly instead.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

private final class WeakCookieStoreObserver: NSObject, WKHTTPCookieStoreObserver {
    private weak var target: WKHTTPCookieStoreObserver?

    init(_ target: WKHTTPCookieStoreObserver) {
        self.target = target
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        target?.cookiesDidChange?(in: cookieStore)
    }
}

final class WebViewStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKHTTPCookieStoreObserver {
    enum RefreshPhase: Equatable {
        case idle
        case pullCommitted
        case rebuilding
    }

    @Published private(set) var isLoggedIn = false
    /// True once the home tab has actually rendered the favorites feed. Drives
    /// the launch splash that hides the cold-start harvest + reload.
    @Published private(set) var favoritesFeedReady = false
    /// True when the favorites feed is confirmed stuck (splice landed but the
    /// feed never rendered) even after an automatic recovery reload — drives a
    /// native retry screen so the user never faces a permanent spinner.
    @Published private(set) var feedStuck = false
    /// Pull-to-refresh keeps the current document and native spinner visible
    /// during `pullCommitted`, then enters `rebuilding` before the real reload.
    @Published private(set) var refreshPhase: RefreshPhase = .idle
    /// True when the last favorites sync attempted writes but couldn't verify
    /// them (`confirmed < add` — most likely a rotated GraphQL `doc_id`, see
    /// known-issues.md #5 "Proposed: doc_id resilience"). Persisted so the
    /// signal survives past the current console/session instead of being a
    /// log line a human has to happen to notice; flips back false the next
    /// time a sync fully confirms. No UI reads this yet.
    @Published private(set) var favoritesSyncDegraded = false

    private var webViews: [NavTarget: WKWebView] = [:]
    private var navVisibleCache: [ObjectIdentifier: Bool] = [:]
    private var pageBackgroundCache: [ObjectIdentifier: Color] = [:]
    private var immersiveCache: [ObjectIdentifier: Bool] = [:]
    private var scrollLockedCache: [ObjectIdentifier: Bool] = [:]
    private let bridge: WebBridge
    private let favorites: FavoritesStore
    private let userContentController = WKUserContentController()
    // Shared config gives every persistent tab the same cookies/session and
    // injected scripts as the eager home webview.
    private let webViewConfiguration = WKWebViewConfiguration()
    private var activeTarget: NavTarget = .home
    private var profileResolved = false
    // The user's own profile href, once detected from the nav row (fires from
    // whichever tab is loaded first, almost always home). Kept even if the
    // profile webview doesn't exist yet, so its eventual lazy creation can load
    // the real profile directly instead of the plain home URL.
    private var resolvedProfileURLString: String?
    private var lastSessionID = ""
    private var lastUserID = ""
    // The cookie store retains its observers, but the proxy's lifetime is this
    // store's business, not WebKit's.
    private var cookieObserver: WeakCookieStoreObserver?
    // Hidden webview that navigates to /?variant=favorites (the only way IG
    // streams the favorites feed) so its edges can be harvested and spliced into
    // the visible home tab. Isolated controller so ContentFilter doesn't run in it.
    private var favHarvestWebView: WKWebView?
    private let favHarvestController = WKUserContentController()
    private var cachedFavEdgesJSON: String?
    // The exact edges JSON armed for the home tab's upcoming/most recent
    // *initial* load, loaded from UserDefaults at init before the home
    // webview's first .load(). Only ever set from disk at launch, and only
    // ever compared against — never trusted blindly, see finishHarvest().
    private var preloadedFromDiskJSON: String?
    private static let favEdgesCacheKey = "biCachedFavEdgesJSON"
    private static let favoritesSyncDegradedKey = "biFavoritesSyncDegraded"
    // Usernames this app itself most recently confirmed as added to the
    // user's real Instagram Favorites. Diffed against the current picks on
    // every sync so an account deselected in-app gets unfavorited on the real
    // account too — a local-history-based remove-side reconcile that doesn't
    // need the (blocked) bulk favorites-list-read endpoint. See
    // known-issues.md #5.
    private static let syncedFavoritesKey = "biSyncedFavoriteUsernames"
    private var didReloadHomeForFavorites = false
    private var didRunLaunchSync = false
    private var feedRecoveryAttempts = 0
    // Monotonic harvest token. Selection commit, launch sync, retry,
    // pull-to-refresh and watchdog recovery can all start a harvest while an
    // earlier one is still in flight; every async stage carries the generation
    // it started under so a slow, stale cycle can never overwrite a newer
    // one's edges (which would splice the previous favorites set into the feed).
    private var harvestGeneration = 0
    // Bounded recovery budgets for WebKit content-process termination and hard
    // navigation failures. Tab budgets are per webview; the harvest webview
    // gets its own because recovery destroys and recreates it.
    private var recoveryAttempts: [ObjectIdentifier: Int] = [:]
    private var pendingScrollRestore: [ObjectIdentifier: CGPoint] = [:]
    private struct NavigationTrace {
        let id: Int
        let reason: String
        var started: Bool
    }
    private var nextNavigationID = 0
    private var navigationTraces: [ObjectIdentifier: NavigationTrace] = [:]
    private var navigationObjectTraces: [ObjectIdentifier: NavigationTrace] = [:]
    private var harvestRecoveryAttempts = 0
    private static let maxRecoveryAttempts = 2
    private static let messageHandlerNames = [
        "biNav", "biAvatar", "biProfile", "biBg", "biPresentation",
        "biFavEdit", "biFavReady", "biFeedStuck", "biLog"
    ]
    #if DEBUG
    private var didRunStoryTimingProbe = false
    #endif
    private weak var homeRefreshControl: UIRefreshControl?
    private var refreshInFlight = false
    private let blockedExactPaths: Set<String> = ["/reels", "/reels/", "/explore", "/explore/"]
    // Clearance reserved at the bottom of every tab's scroll content so the
    // last item never ends up hidden behind the floating tab bar (see
    // makeWebView). Empirically chosen in-simulator, not derived from a
    // system constant — the floating tab bar's own size isn't exposed to a
    // sibling WKWebView.
    private static let bottomTabBarClearance: CGFloat = 100

    private let startURLs: [NavTarget: String] = [
        .home: "https://www.instagram.com/",
        .search: "https://www.instagram.com/explore/search/",
        .direct: "https://www.instagram.com/direct/inbox/",
        .profile: "https://www.instagram.com/"
    ]

    // Home always loads the plain home feed first: the JS captures IG's real
    // stories tray there, then redirects to /?variant=favorites (the native
    // favorites feed) when the filter is on. Loading the variant directly
    // would skip the capture and lose the stories row.
    private var homeURLString: String {
        // Plain home page: keeps IG's live stories tray + real header. The
        // favorites posts are pulled from the /?variant=favorites HTML and
        // spliced into this page's feed (see ContentFilter prefetchFavoriteEdges).
        "https://www.instagram.com/"
    }

    init(bridge: WebBridge, favorites: FavoritesStore) {
        self.bridge = bridge
        self.favorites = favorites
        super.init()

        print("[BI-BUILD] device-polish-observability v2")

        // Warm-launch optimization: if a prior session's harvest left valid
        // edges on disk, arm them as the preload BEFORE the home webview's
        // first load below, so the document-start SSR splice can render
        // favorites on the very first paint instead of only after the
        // post-harvest reload. This is never trusted on faith — finishHarvest()
        // only skips the reload once the live harvest that follows proves
        // (by exact match) that this preload was already correct.
        if favorites.isFilterEnabled,
           let persisted = UserDefaults.standard.string(forKey: Self.favEdgesCacheKey),
           harvestCount(persisted) > 0 {
            cachedFavEdgesJSON = persisted
            preloadedFromDiskJSON = persisted
        }
        favoritesSyncDegraded = UserDefaults.standard.bool(forKey: Self.favoritesSyncDegradedKey)

        // Defense-in-depth: compile the static content-rule-list (Explore/Reels
        // nav chrome — see BlockingRules.json) as early as possible so it's in
        // effect before/at first paint on most launches. This is additive only:
        // compilation is inherently async, so the very first page load of a
        // cold launch may land before it's ready, and the equivalent JS/CSS
        // hides in ContentFilter.swift stay completely unchanged as the
        // always-on primary mechanism. Any failure here (missing resource,
        // malformed JSON, simulator quirk) is caught and logged; the app
        // continues exactly as it does today.
        compileContentRuleList()

        installUserScripts()
        let messageHandler = WeakScriptMessageHandler(self)
        for name in Self.messageHandlerNames {
            userContentController.add(messageHandler, name: name)
        }

        let dataStore = WKWebsiteDataStore.default()
        webViewConfiguration.websiteDataStore = dataStore
        webViewConfiguration.userContentController = userContentController
        webViewConfiguration.allowsInlineMediaPlayback = true
        webViewConfiguration.mediaTypesRequiringUserActionForPlayback = []

        // Only the home tab is created eagerly: it's needed immediately for the
        // launch splash + favorites harvest + first paint. Search/direct/profile
        // are created lazily on first visit (see ensureWebView(for:)) so launch
        // doesn't pay for 3 webviews the user may never open this session.
        _ = makeWebView(for: .home)

        let observer = WeakCookieStoreObserver(self)
        cookieObserver = observer
        dataStore.httpCookieStore.add(observer)
        dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastSessionID = Self.sessionID(from: cookies)
                self.lastUserID = Self.userID(from: cookies)
                self.isLoggedIn = !self.lastSessionID.isEmpty
                if self.isLoggedIn { self.harvestFavorites() }
            }
        }
    }

    deinit {
        for name in Self.messageHandlerNames {
            userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    /// Creates target's webview on first call, then returns the same persisted
    /// instance every time after — same session/scroll-position warmth as the
    /// eager home tab, just deferred until the tab is actually needed.
    @discardableResult
    private func makeWebView(for target: NavTarget) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // UIScrollView delays the first touch on its content by default, to
        // give itself a chance to claim the gesture as a scroll before
        // conceding it to the content underneath — this is the classic cause
        // of "have to tap twice" on interactive elements inside a WKWebView
        // (confirmed here via a diagnostic: taps on a DM reel-share card were
        // reaching the page's own click handler cleanly and un-prevented, so
        // nothing in the injected script was at fault). Disabling the delay
        // makes taps register immediately, matching native app feel.
        webView.scrollView.delaysContentTouches = false
        // Clearance follows this page's reported native-tab-bar visibility.
        // Thread routes hide the tab bar and respect the safe area instead of
        // carrying a permanent outer 100-point inset.
        updateBottomClearance(for: webView, navVisible: true)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // allowsBackForwardNavigationGestures's built-in interactive swipe
        // triggers a full document reload (visible white flash) when it lands
        // on a same-document (history.pushState) SPA entry — Instagram's DM
        // thread <-> inbox transitions are exactly that. A direct goBack()/
        // goForward() call fires a same-document popstate instead, with no
        // reload, so the gesture is reimplemented manually below and driven
        // through the API. See known-issues.md "Swipe-back white flash".
        webView.allowsBackForwardNavigationGestures = false
        addBackForwardSwipeGestures(to: webView)
        webView.removeInputAccessoryView()
        if target == .home {
            let refresh = UIRefreshControl()
            refresh.tintColor = .secondaryLabel
            refresh.addTarget(self, action: #selector(handlePullToRefresh), for: .valueChanged)
            webView.scrollView.refreshControl = refresh
            webView.scrollView.alwaysBounceVertical = true
            homeRefreshControl = refresh
        }
        // Profile normally starts at the plain root and gets JS-navigated to the
        // real profile once resolved (see setActive). If the href was already
        // resolved from another tab before this webview existed, load it
        // directly and skip that extra hop.
        let startURL: String
        if target == .profile, let resolved = resolvedProfileURLString {
            startURL = resolved
        } else {
            startURL = target == .home ? homeURLString : (startURLs[target] ?? homeURLString)
        }
        webViews[target] = webView
        if let url = URL(string: startURL) ?? URL(string: homeURLString) {
            load(URLRequest(url: url), in: webView, reason: "initial-\(target)")
        }
        return webView
    }

    private func ensureWebView(for target: NavTarget) -> WKWebView {
        webViews[target] ?? makeWebView(for: target)
    }

    func webView(for target: NavTarget) -> WKWebView {
        ensureWebView(for: target)
    }

    func setActive(_ target: NavTarget) {
        activeTarget = target
        let webView = ensureWebView(for: target)
        publishCachedPresentation(for: webView)
        updateBottomClearance(for: webView, navVisible: navVisibleCache[ObjectIdentifier(webView)] ?? true)
        if target == .profile && !profileResolved {
            webView.evaluateJavaScript(
                "window.__biNavigate('profile')",
                completionHandler: nil
            )
        }
    }

    private func publishCachedPresentation(for webView: WKWebView) {
        let identifier = ObjectIdentifier(webView)
        let base = pageBackgroundCache[identifier] ?? Color(.systemBackground)
        bridge.isNavVisible = navVisibleCache[identifier] ?? true
        bridge.pageBackground = base
        bridge.safeAreaBackground = base
    }

    private func updateBottomClearance(for webView: WKWebView, navVisible: Bool) {
        let bottom = navVisible ? Self.bottomTabBarClearance : 0
        guard webView.scrollView.contentInset.bottom != bottom ||
                webView.scrollView.verticalScrollIndicatorInsets.bottom != bottom else { return }
        webView.scrollView.contentInset.bottom = bottom
        webView.scrollView.verticalScrollIndicatorInsets.bottom = bottom
        let target = targetLabel(for: webView)
        print("[BI-geometry] target=\(target) navVisible=\(navVisible) bottomInset=\(bottom)")
    }

    private func targetLabel(for webView: WKWebView) -> String {
        if webView === favHarvestWebView { return "harvest" }
        return webViews.first(where: { $0.value === webView })
            .map { String(describing: $0.key) } ?? "unknown"
    }

    private func diagnosticURL(_ url: URL?) -> String {
        guard let url else { return "nil" }
        let path: String
        if url.path.hasPrefix("/direct/t/") {
            path = "/direct/t/<id>/"
        } else if url.path.hasPrefix("/stories/") {
            path = "/stories/<id>/"
        } else if ["/reel/", "/reels/", "/p/", "/tv/"].contains(where: url.path.hasPrefix) {
            path = "/\(url.path.split(separator: "/").first ?? "media")/<id>/"
        } else if url.path.split(separator: "/").count == 1, url.path != "/" {
            path = "/<profile>/"
        } else {
            path = url.path
        }
        return "\(url.scheme ?? "https")://\(url.host ?? "unknown")\(path)"
    }

    private func navigationSnapshot(for webView: WKWebView, url: URL? = nil) -> String {
        let scroll = webView.scrollView.contentOffset
        return "active=\(activeTarget) target=\(targetLabel(for: webView)) " +
            "url=\(diagnosticURL(url ?? webView.url)) isLoading=\(webView.isLoading) " +
            "offset=(\(Int(scroll.x)),\(Int(scroll.y)))"
    }

    @discardableResult
    private func registerNavigation(_ webView: WKWebView, reason: String, url: URL? = nil) -> Int {
        nextNavigationID += 1
        let id = nextNavigationID
        navigationTraces[ObjectIdentifier(webView)] = NavigationTrace(id: id, reason: reason, started: false)
        print("[BI-nav] id=\(id) action=request reason=\(reason) \(navigationSnapshot(for: webView, url: url))")
        return id
    }

    private func associate(_ navigation: WKNavigation?, with webView: WKWebView) {
        guard let navigation, let trace = navigationTraces[ObjectIdentifier(webView)] else { return }
        navigationObjectTraces[ObjectIdentifier(navigation)] = trace
    }

    private func load(_ request: URLRequest, in webView: WKWebView, reason: String) {
        registerNavigation(webView, reason: reason, url: request.url)
        associate(webView.load(request), with: webView)
    }

    private func reload(_ webView: WKWebView, reason: String) {
        registerNavigation(webView, reason: reason)
        associate(webView.reload(), with: webView)
    }

    private func logNavigationLifecycle(
        _ event: String,
        webView: WKWebView,
        navigation: WKNavigation? = nil,
        error: Error? = nil
    ) {
        let webViewKey = ObjectIdentifier(webView)
        let navigationKey = navigation.map(ObjectIdentifier.init)
        var trace = navigationKey.flatMap { navigationObjectTraces[$0] } ?? navigationTraces[webViewKey]
        if trace == nil {
            nextNavigationID += 1
            let reason = event == "didStart" ? "web-content" : "lifecycle-\(event)"
            trace = NavigationTrace(id: nextNavigationID, reason: reason, started: false)
        }
        if event == "didStart", var current = trace {
            current.started = true
            navigationTraces[webViewKey] = current
            if let navigationKey { navigationObjectTraces[navigationKey] = current }
            trace = current
        }
        let errorText = error.map {
            let value = $0 as NSError
            return " error=\(value.domain):\(value.code)"
        } ?? ""
        print("[BI-nav] id=\(trace?.id ?? 0) event=\(event) reason=\(trace?.reason ?? "untracked") " +
            "\(navigationSnapshot(for: webView))\(errorText)")
        if event == "didFinish" || event == "didFail" || event == "didFailProvisional" {
            if let navigationKey { navigationObjectTraces.removeValue(forKey: navigationKey) }
            if navigationTraces[webViewKey]?.id == trace?.id {
                navigationTraces.removeValue(forKey: webViewKey)
            }
        }
    }

    private func setPresentation(locked: Bool, immersive: Bool, for webView: WKWebView) {
        let identifier = ObjectIdentifier(webView)
        immersiveCache[identifier] = immersive
        scrollLockedCache[identifier] = locked
        webView.scrollView.isScrollEnabled = !locked
        guard webView === webViews[activeTarget] else { return }
        let base = pageBackgroundCache[identifier] ?? Color(.systemBackground)
        bridge.safeAreaBackground = base
    }

    // MARK: - Favorites

    private var favoritesJSON: String {
        let usernames = favorites.favorites.map { $0.username.lowercased() }
        guard let data = try? JSONSerialization.data(withJSONObject: usernames),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Runs before ContentFilter.script so the allowlist exists by the time
    /// the filter boots (and before Instagram's own scripts execute).
    private func installUserScripts() {
        userContentController.removeAllUserScripts()
        var preamble = "window.__biFavorites = \(favoritesJSON); window.__biFavoritesEnabled = \(favorites.isFilterEnabled);"
        // Preload harvested favorite edges so the document-start SSR splice can
        // swap them into Instagram's server-streamed feed before it hydrates.
        if let edges = cachedFavEdgesJSON {
            preamble += " window.__biFavEdgesPreload = \(edges);"
        }
        userContentController.addUserScript(
            WKUserScript(source: preamble, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        userContentController.addUserScript(
            WKUserScript(source: ContentFilter.script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
    }

    /// Compiles `BlockingRules.json` (static, always-true nav-chrome hides —
    /// Explore link, Reels link/icon) into a `WKContentRuleList` and adds it to
    /// the shared `userContentController`, so WebKit's networking/rendering
    /// layer can apply it off the main thread before the page's own JS/CSS
    /// runs. Purely additive: the equivalent CSS hides in `ContentFilter.swift`
    /// remain the primary, unconditional mechanism. Any failure (resource
    /// missing, malformed JSON, store error) is logged and swallowed — the app
    /// works exactly as before, just without this extra layer.
    private func compileContentRuleList() {
        guard let url = Bundle.main.url(forResource: "BlockingRules", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else {
            print("[BI-DEBUG] content rule list: BlockingRules.json not found/unreadable, skipping")
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "BIBlockingRules",
            encodedContentRuleList: json
        ) { [weak self] list, error in
            guard let self else { return }
            if let error {
                print("[BI-DEBUG] content rule list compile failed, skipping: \(error)")
                return
            }
            guard let list else { return }
            DispatchQueue.main.async {
                self.userContentController.add(list)
            }
        }
    }

    /// Call after the favorites selection changes. Reinstalls the preamble
    /// for future page loads, pushes the new list into live pages, and
    /// reloads home so posts already delivered by filtered-out authors drop.
    func applyFavoritesSelection() {
        installUserScripts()
        let call = "window.__biSetFavorites && window.__biSetFavorites(\(favoritesJSON), \(favorites.isFilterEnabled));"
        for webView in webViews.values {
            webView.evaluateJavaScript(call, completionHandler: nil)
        }
        // The favorites feed (?variant=favorites, which the edge-splice reads)
        // renders from Instagram's OWN server-side Favorites list, not the app's
        // picks. Push the picks into that list first, THEN reload home so the
        // spliced feed actually contains their posts. Without this the favorites
        // feed is empty and the algorithmic home feed falls through.
        Task { @MainActor in
            if favorites.isFilterEnabled {
                await syncFavoritesToInstagram()
            }
            // Re-harvest so the favorites feed reflects the new picks, then
            // reload home (the harvested edges get pushed in on didFinish).
            cachedFavEdgesJSON = nil
            didReloadHomeForFavorites = false
            // This explicit reload is not the disk-warm-start case (the picks
            // just changed) — never let finishHarvest's no-op check skip it.
            preloadedFromDiskJSON = nil
            favoritesFeedReady = false
            feedStuck = false
            feedRecoveryAttempts = 0
            harvestRecoveryAttempts = 0
            harvestFavorites()
            if let home = webViews[.home], let url = URL(string: homeURLString) {
                load(URLRequest(url: url), in: home, reason: "favorites-selection")
            }
        }
    }

    /// Resolve each picked account to its numeric user id and make Instagram's
    /// server-side Favorites list ("besties" / `favorites_home_list`) match the
    /// picks EXACTLY: read the current list (probing the besties list endpoint),
    /// then `set_besties` with add = picks not on the list and remove = list
    /// entries not picked. If no read endpoint responds, falls back to add-only
    /// (the old behavior). Runs inside the logged-in home webview so it rides
    /// the page's session cookies + csrftoken. This is what makes the
    /// ?variant=favorites feed reflect the app's selection.
    @MainActor
    @discardableResult
    func syncFavoritesToInstagram() async -> String {
        let usernames = favorites.favorites.map(\.username)
        guard !usernames.isEmpty, let webView = webViews[.home] else { return "skipped" }
        let script = """
        const APP_ID = '936619743392459';
        const csrf = (document.cookie.match(/csrftoken=([^;]+)/) || [])[1] || '';
        const log = function(m) {
            try { window.webkit.messageHandlers.biLog.postMessage('[sync] ' + m); } catch (e) {}
        };
        const resolved = [];
        for (const name of usernames) {
            try {
                const r = await fetch('/api/v1/users/web_profile_info/?username=' +
                    encodeURIComponent(name), {
                    credentials: 'include', headers: { 'X-IG-App-ID': APP_ID }
                });
                if (!r.ok) { continue; }
                const j = await r.json();
                const id = j && j.data && j.data.user && j.data.user.id;
                if (id) { resolved.push({ name: name, id: String(id) }); }
            } catch (e) {}
        }
        if (!resolved.length) { return 'no ids resolved'; }
        const ids = resolved.map(function(r) { return r.id; });
        // Ground truth per pick: friendships/show. is_feed_favorite is the
        // FAVORITES-list flag; is_bestie is Close Friends (fallback only when
        // is_feed_favorite is absent). Instagram only allows Favorites for
        // FOLLOWED accounts (set_besties silently ignores the rest), so
        // non-followed picks are surfaced.
        const favFlag = function(j) {
            return (typeof j.is_feed_favorite === 'boolean') ? j.is_feed_favorite : !!j.is_bestie;
        };
        const state = {};
        const flags = [];
        for (const r of resolved) {
            try {
                const res = await fetch('/api/v1/friendships/show/' + r.id + '/', {
                    credentials: 'include', headers: { 'X-IG-App-ID': APP_ID }
                });
                if (!res.ok) { log('show ' + r.name + ' status=' + res.status); continue; }
                const j = await res.json();
                state[r.id] = { following: !!j.following, fav: favFlag(j), bestie: !!j.is_bestie };
                flags.push(r.name + ':follow=' + (j.following ? 1 : 0) +
                    ' bestie=' + (j.is_bestie ? 1 : 0) +
                    ' fav=' + (typeof j.is_feed_favorite === 'boolean' ? (j.is_feed_favorite ? 1 : 0) : '?'));
            } catch (e) {}
        }
        log('flags ' + flags.join(' | '));
        const notFollowed = resolved.filter(function(r) {
            return state[r.id] && !state[r.id].following;
        }).map(function(r) { return r.name; });
        const add = resolved.filter(function(r) {
            const s = state[r.id];
            return !s || (s.following && !s.fav);
        }).map(function(r) { return r.id; });
        // Remove-side reconcile: an account this app itself previously
        // confirmed as added to Favorites, but that's no longer one of the
        // current picks, should get unfavorited on the real account too —
        // otherwise its posts keep streaming into the favorites feed forever
        // even after being deselected in-app. This can't enumerate Instagram's
        // real Favorites list (the bulk read endpoints reject the web UA), so
        // it only ever removes what OUR OWN prior sync added (tracked in
        // `previouslySynced`) — it will never touch a favorite the user set up
        // directly in the real Instagram app outside of this one.
        const currentLower = usernames.map(function(n) { return String(n).toLowerCase(); });
        const removedNames = (previouslySynced || []).filter(function(n) {
            return currentLower.indexOf(String(n).toLowerCase()) === -1;
        });
        const removedResolved = [];
        for (const name of removedNames) {
            try {
                const r = await fetch('/api/v1/users/web_profile_info/?username=' +
                    encodeURIComponent(name), {
                    credentials: 'include', headers: { 'X-IG-App-ID': APP_ID }
                });
                if (!r.ok) { continue; }
                const j = await r.json();
                const id = j && j.data && j.data.user && j.data.user.id;
                if (id) { removedResolved.push({ name: name, id: String(id) }); }
            } catch (e) {}
        }
        const remove = removedResolved.map(function(r) { return r.id; });
        const hdrs = {
            'X-IG-App-ID': APP_ID,
            'X-CSRFToken': csrf,
            'X-Requested-With': 'XMLHttpRequest',
            'Content-Type': 'application/x-www-form-urlencoded'
        };
        // Favorites are written by the GraphQL mutation the web "Add to
        // favorites" chevron fires (captured on device 2026-07-14):
        // usePolarisUpdateFeedFavoritesUpdatableFavoriteMutation, a single call
        // that takes data.add[]/remove[]. Goes to /api/graphql (NOT the UA-gated
        // api/v1 endpoints). set_besties writes CLOSE FRIENDS, not favorites, so
        // it is only used for the one-time CF cleanup below. The unfavorite
        // side is the mirror-image mutation, usePolarisUpdateFeedFavoritesUpdatableUnfavoriteMutation.
        // Anti-CSRF tokens for the mutation are scraped from the page HTML.
        const html = document.documentElement.innerHTML;
        function tok(re) { const m = html.match(re); return m ? m[1] : ''; }
        const dtsg = tok(/"DTSGInitialData",\\[\\],\\{"token":"([^"]+)"/) ||
            tok(/name=\\"fb_dtsg\\" value=\\"([^"]+)\\"/);
        const lsd = tok(/"LSD",\\[\\],\\{"token":"([^"]+)"/);
        const av = tok(/"actorID":"([0-9]+)"/) ||
            (document.cookie.match(/ds_user_id=([0-9]+)/) || [])[1] || '';
        const FAV_DOC_ID = '27127248780249605';
        const FAV_FN = 'usePolarisUpdateFeedFavoritesUpdatableFavoriteMutation';
        const UNFAV_DOC_ID = '27275847402052259';
        const UNFAV_FN = 'usePolarisUpdateFeedFavoritesUpdatableUnfavoriteMutation';
        async function runFavMutation(addIds, removeIds, docId, friendlyName) {
            if (!dtsg) { return { ok: false, reason: 'no fb_dtsg token' }; }
            try {
                const body = new URLSearchParams({
                    av: av, __a: '1', __comet_req: '7',
                    fb_dtsg: dtsg, lsd: lsd,
                    fb_api_caller_class: 'RelayModern',
                    fb_api_req_friendly_name: friendlyName,
                    variables: JSON.stringify({ data: { add: addIds, remove: removeIds, source: 'favorites_management' } }),
                    server_timestamps: 'true',
                    doc_id: docId
                });
                const r = await fetch('/api/graphql', {
                    method: 'POST', credentials: 'include',
                    headers: {
                        'X-CSRFToken': csrf, 'X-IG-App-ID': APP_ID, 'X-FB-LSD': lsd,
                        'X-FB-Friendly-Name': friendlyName,
                        'Content-Type': 'application/x-www-form-urlencoded'
                    },
                    body: body.toString()
                });
                const t = await r.text();
                if (r.ok && t.indexOf('"errors"') === -1) { return { ok: true }; }
                return { ok: false, reason: 'status=' + r.status + ' body=' + t.slice(0, 200) };
            } catch (e) { return { ok: false, reason: String(e) }; }
        }
        let wrote = 0;
        if (add.length) {
            const res = await runFavMutation(add, [], FAV_DOC_ID, FAV_FN);
            if (res.ok) { wrote = add.length; } else { log('favmut ' + res.reason); }
        }
        let removedWrote = 0;
        if (remove.length) {
            const res = await runFavMutation([], remove, UNFAV_DOC_ID, UNFAV_FN);
            if (res.ok) { removedWrote = remove.length; } else { log('unfavmut ' + res.reason); }
        }
        // Verify the writes took: re-check the favorites flag for every add
        // and every remove.
        let confirmed = 0;
        for (const id of add) {
            try {
                const r = await fetch('/api/v1/friendships/show/' + id + '/', {
                    credentials: 'include', headers: { 'X-IG-App-ID': APP_ID }
                });
                if (!r.ok) { continue; }
                const j = await r.json();
                if (favFlag(j)) { confirmed++; }
            } catch (e) {}
        }
        let removedConfirmed = 0;
        for (const id of remove) {
            try {
                const r = await fetch('/api/v1/friendships/show/' + id + '/', {
                    credentials: 'include', headers: { 'X-IG-App-ID': APP_ID }
                });
                if (!r.ok) { continue; }
                const j = await r.json();
                if (!favFlag(j)) { removedConfirmed++; }
            } catch (e) {}
        }
        // One-time cleanup: the old set_besties path polluted the user's CLOSE
        // FRIENDS list with the picks; remove them from it once.
        let cleaned = -1;
        if (cleanupBesties) {
            const bestiePicks = resolved.filter(function(r) {
                return state[r.id] && state[r.id].bestie;
            }).map(function(r) { return r.id; });
            cleaned = 0;
            if (bestiePicks.length) {
                try {
                    const res = await fetch('/api/v1/friendships/set_besties/', {
                        method: 'POST', credentials: 'include', headers: hdrs,
                        body: new URLSearchParams({
                            module: 'favorites_home_list',
                            source: 'audience_manager',
                            add: JSON.stringify([]),
                            remove: JSON.stringify(bestiePicks)
                        }).toString()
                    });
                    if (res.ok) { cleaned = bestiePicks.length; }
                    else { log('cleanup status=' + res.status); }
                } catch (e) {}
            }
        }
        const followNote = notFollowed.length ?
            ' NOT-FOLLOWED(cannot favorite): ' + notFollowed.join(',') : '';
        const cleanNote = cleaned >= 0 ? ' cleanedCF=' + cleaned : '';
        const removeNote = remove.length ?
            ' remove=' + remove.length + ' removedOk=' + removedWrote +
            ' removedConfirmed=' + removedConfirmed : '';
        if (!add.length && !remove.length) {
            return 'already in sync (' + ids.length + ' picks)' + followNote + cleanNote;
        }
        return 'wrote favorites add=' + add.length + ' ok=' + wrote +
            ' confirmed=' + confirmed + ' picks=' + ids.length + '/' + usernames.length +
            removeNote + followNote + cleanNote;
        """
        let cleanupNeeded = !UserDefaults.standard.bool(forKey: "biDidCleanBesties")
        let previouslySynced = (UserDefaults.standard.array(forKey: Self.syncedFavoritesKey) as? [String]) ?? []
        let result: String = await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(
                script,
                arguments: [
                    "usernames": usernames,
                    "cleanupBesties": cleanupNeeded,
                    "previouslySynced": previouslySynced
                ],
                in: nil,
                in: .page
            ) { r in
                switch r {
                case .success(let value): continuation.resume(returning: (value as? String) ?? "ok")
                case .failure(let error): continuation.resume(returning: "error: \(error.localizedDescription)")
                }
            }
        }
        print("[BI-sync] \(result)")
        if result.contains("cleanedCF=") {
            UserDefaults.standard.set(true, forKey: "biDidCleanBesties")
        }
        // The current picks are now the reconcile baseline going forward,
        // whether or not every individual add/remove verified — this process
        // is self-healing once per launch (see didFinish), so a partial
        // failure converges on a later run rather than needing to be exact
        // here. Only skip updating the baseline on a hard failure (no ids
        // resolved / a thrown error), where we learned nothing new.
        if !result.hasPrefix("error:") && result != "no ids resolved" {
            UserDefaults.standard.set(usernames, forKey: Self.syncedFavoritesKey)
        }
        updateFavoritesSyncHealth(result)
        return result
    }

    /// Parses `add=`/`confirmed=` out of a `syncFavoritesToInstagram()` result
    /// summary and tracks whether writes are going through. `confirmed < add`
    /// most likely means a rotated GraphQL doc_id (see known-issues.md #5,
    /// "Proposed: doc_id resilience") — this only makes that failure a
    /// persisted, named signal instead of a console line a human has to
    /// happen to notice; it does not change sync behavior in any way.
    /// "already in sync" / "skipped" / "no ids resolved" / "error: ..."
    /// results carry no add/confirmed counts (no write was attempted) and are
    /// intentionally left alone either way.
    @MainActor
    private func updateFavoritesSyncHealth(_ result: String) {
        func intAfter(_ label: String) -> Int? {
            guard let range = result.range(of: label) else { return nil }
            let digits = result[range.upperBound...].prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
        guard let add = intAfter("add="), let confirmed = intAfter("confirmed=") else { return }
        let degraded = add > 0 && confirmed < add
        guard degraded != favoritesSyncDegraded else { return }
        favoritesSyncDegraded = degraded
        UserDefaults.standard.set(degraded, forKey: Self.favoritesSyncDegradedKey)
        if degraded {
            print("[BI-sync] DEGRADED: confirmed \(confirmed)/\(add) favorites writes verified — " +
                "doc_id likely rotated; recapture via devtools (see docs/known-issues.md #5)")
        } else {
            print("[BI-sync] favorites sync healthy again (confirmed=\(confirmed)/\(add))")
        }
    }

    // MARK: - Favorites harvest

    /// Load /?variant=favorites in a hidden webview (a real navigation is the
    /// only thing that makes IG stream the favorites feed) so its edges can be
    /// extracted and pushed into the visible home tab.
    func harvestFavorites() {
        guard favorites.isFilterEnabled, !lastSessionID.isEmpty else { return }
        harvestGeneration += 1
        let generation = harvestGeneration
        let webView: WKWebView
        if let existing = favHarvestWebView {
            webView = existing
        } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            config.userContentController = favHarvestController
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            let created = WKWebView(frame: CGRect(x: -10000, y: 0, width: 430, height: 900),
                                    configuration: config)
            created.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
            created.navigationDelegate = self
            // Attach offscreen so WebKit fully processes the load/streaming.
            Self.keyWindow()?.addSubview(created)
            favHarvestWebView = created
            webView = created
        }
        print("[BI-harvest] loading /?variant=favorites (generation \(generation))")
        load(
            URLRequest(url: URL(string: "https://www.instagram.com/?variant=favorites")!),
            in: webView,
            reason: "harvest-generation-\(generation)"
        )
        // Safety net. This used to unconditionally flip favoritesFeedReady,
        // which dropped the launch splash onto whatever Instagram had rendered
        // — i.e. the algorithmic feed — and reported success (R1 violation).
        // It now fails CLOSED: if this generation still hasn't produced a
        // rendered favorites feed by the deadline, the degraded path runs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, generation == self.harvestGeneration, !self.favoritesFeedReady else { return }
            self.failFeedClosed("no favorites feed rendered within 20s of harvest \(generation)")
        }
    }

    private func harvestExtract(generation: Int) {
        guard favHarvestWebView != nil else { return }
        // Small settle, then the harvest script itself scrolls to paginate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, generation == self.harvestGeneration,
                  let webView = self.favHarvestWebView else { return }
            webView.callAsyncJavaScript(
                ContentFilter.harvestScript,
                arguments: [:],
                in: nil,
                in: .page
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let value):
                    guard let json = value as? String else {
                        print("[BI-harvest] no string returned")
                        self.finishHarvest("{}", generation: generation)
                        return
                    }
                    self.logHarvestSummary(json)
                    self.densifyHarvest(json, generation: generation)
                case .failure(let error):
                    print("[BI-harvest] extract error: \(error.localizedDescription)")
                    self.finishHarvest("{}", generation: generation)
                }
            }
        }
    }

    /// Append each favorite's recent profile media to the streamed edges (the
    /// density pass, see ContentFilter.densityScript). Fail-safe: any error or
    /// empty result falls back to the streamed-only harvest unchanged.
    private func densifyHarvest(_ json: String, generation: Int) {
        guard harvestCount(json) > 0, let webView = favHarvestWebView else {
            finishHarvest(json, generation: generation)
            return
        }
        let usernames = favorites.favorites.map(\.username)
        webView.callAsyncJavaScript(
            ContentFilter.densityScript,
            arguments: ["harvestJson": json, "usernames": usernames],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                if let augmented = value as? String, self.harvestCount(augmented) >= self.harvestCount(json) {
                    print("[BI-density] appended \(self.harvestCount(augmented) - self.harvestCount(json)) profile posts"
                        + " fetch=\(self.harvestFetchStats(augmented))")
                    self.finishHarvest(augmented, generation: generation)
                } else {
                    print("[BI-density] no augmentation; using streamed edges only")
                    self.finishHarvest(json, generation: generation)
                }
            case .failure(let error):
                print("[BI-density] error: \(error.localizedDescription); using streamed edges only")
                self.finishHarvest(json, generation: generation)
            }
        }
    }

    private func finishHarvest(_ json: String, generation: Int) {
        // A newer harvest has started since this one began (selection commit,
        // retry, pull-to-refresh, watchdog recovery). Its edges are the current
        // truth; completing this one would splice a stale favorites set.
        guard generation == harvestGeneration else {
            print("[BI-harvest] discarding stale harvest generation \(generation) (current \(harvestGeneration))")
            return
        }
        guard harvestCount(json) > 0 else {
            failFeedClosed("harvest \(generation) returned 0 favorite edges")
            return
        }
        harvestRecoveryAttempts = 0
        destroyHarvestWebView(reason: "harvest generation \(generation) completed")
        // Proven (not assumed) no-op check: only true when a disk-preloaded
        // cache was armed before the home tab's current/most recent initial
        // load AND this live harvest returned byte-identical edges — i.e. the
        // already-rendered SSR splice used exactly this data, so reloading
        // would repaint the same thing. Any difference (account switch,
        // changed picks, new posts since last launch) falls through to the
        // normal reload below.
        let preloadAlreadyCorrect = preloadedFromDiskJSON != nil && json == preloadedFromDiskJSON

        cachedFavEdgesJSON = json
        // Refresh the preamble so window.__biFavEdgesPreload carries the latest
        // edges on any future page load (the document-start SSR splice reads it),
        // and persist to disk so the *next* launch can arm this same warm-start
        // preload before its first load.
        installUserScripts()
        UserDefaults.standard.set(json, forKey: Self.favEdgesCacheKey)

        // After the first successful harvest, reload home once so the
        // now-cached favorites splice lands deterministically (no
        // cold-start race) — unless the disk-preloaded first paint already
        // proved itself correct above, in which case reloading would be a
        // pure no-op and is skipped.
        let willReloadHome = !didReloadHomeForFavorites && !preloadAlreadyCorrect
        if willReloadHome {
            // Re-arm BEFORE delivering edges, and skip delivering to home
            // below: the still-visible pre-reload home page can render a real
            // (if not yet deterministic) favorites feed and independently
            // flip favoritesFeedReady true (or run an uncovered DOM-filter
            // pass) the instant it receives fresh edges — which used to
            // happen a moment before this reload fired. That's the visible
            // "loads in, then flashes as it reloads" bug: the splash leaves
            // early, the reload briefly shows the raw page (with Instagram's
            // own chrome, before our filters catch up), then the real
            // favorites feed reappears. Re-arming first and never delivering
            // to the about-to-be-discarded home page closes that window; only
            // the *reloaded* page's own biFavReady can drop the splash now.
            favoritesFeedReady = false
        }
        deliverFavEdges(includingHome: !willReloadHome)

        if !didReloadHomeForFavorites {
            didReloadHomeForFavorites = true
            if preloadAlreadyCorrect {
                print("[BI-harvest] disk preload matched live harvest; skipping post-harvest reload")
            } else if let home = webViews[.home] {
                // No artificial delay: the splash is already back up (re-armed
                // above) before this reload is even requested, so there is
                // nothing left for a delay to protect against.
                reload(home, reason: "post-harvest-generation-\(generation)")
            }
        }
    }

    private func logHarvestSummary(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let count = obj["count"] ?? "?"
        let markers = obj["markers"] ?? "?"
        let authors = obj["authors"] ?? "?"
        print("[BI-harvest] count=\(count) markers=\(markers) authors=\(authors)")
    }

    private func harvestCount(_ json: String) -> Int {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = obj["count"] as? Int else { return 0 }
        return count
    }

    private func harvestFetchStats(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stats = obj["fetch"] as? String else { return "" }
        return stats
    }

    /// Push cached favorites edges into every webview. Only the home tab's feed
    /// needs them visually, but the other tabs also hold their preloaded feed
    /// request, so delivering everywhere stops them waiting the full timeout.
    /// `includingHome: false` skips the home tab specifically — used from
    /// finishHarvest() when home is about to reload anyway (the fresh edges
    /// are already armed as its preload for that reload): delivering to the
    /// still-visible, about-to-be-discarded pre-reload home page would only
    /// let it react on its own before the reload lands. See
    /// research-2026-07-27-coldstart-reload-flash.md.
    private func deliverFavEdges(includingHome: Bool = true) {
        guard let json = cachedFavEdgesJSON else { return }
        for (target, webView) in webViews {
            if target == .home && !includingHome { continue }
            webView.callAsyncJavaScript(
                "window.__biSetFavEdges && window.__biSetFavEdges(payload);",
                arguments: ["payload": json],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }
    }

    // MARK: - Feed fail-safe recovery

    /// The JS watchdog reported the favorites feed stuck (splice landed but the
    /// feed never rendered). Try one automatic recovery reload; if it's still
    /// stuck after that, surface the retry screen rather than loop.
    @MainActor
    private func handleFeedStuck() {
        guard !feedStuck else { return }
        if feedRecoveryAttempts == 0 {
            feedRecoveryAttempts = 1
            print("[BI-watchdog] favorites feed stuck — auto-recovery (re-harvest + reload)")
            reharvestAndReloadHome(reason: "watchdog-recovery")
        } else {
            print("[BI-watchdog] favorites feed still stuck after recovery — showing retry")
            feedStuck = true
        }
    }

    /// User-triggered retry from the feed error screen.
    func retryFavoritesFeed() {
        feedStuck = false
        feedRecoveryAttempts = 0
        // An explicit user retry restores the full recovery budget; otherwise a
        // previously exhausted harvest webview would give up on first failure.
        harvestRecoveryAttempts = 0
        reharvestAndReloadHome(reason: "user-retry")
    }

    /// R1 fails closed. Whenever the favorites feed cannot be produced or
    /// verified, Instagram's algorithmic feed must never be presented as a
    /// successful result. Drop the splash (so the other three tabs stay usable
    /// — R1 is a home-feed contract) and put home into the existing degraded
    /// state, which gets one automatic recovery attempt before the retry
    /// screen takes over.
    @MainActor
    private func failFeedClosed(_ reason: String) {
        print("[BI-harvest] fail-closed: \(reason)")
        favoritesFeedReady = true
        endRefresh()
        handleFeedStuck()
    }

    private func reharvestAndReloadHome(reason: String) {
        if let home = webViews[.home] {
            print("[BI-nav] action=reharvest reason=\(reason) \(navigationSnapshot(for: home))")
        }
        cachedFavEdgesJSON = nil
        didReloadHomeForFavorites = false
        // Explicit retry/refresh reload, not the disk-warm-start case — never
        // let finishHarvest's no-op check skip it.
        preloadedFromDiskJSON = nil
        // The rebuild is not a rendered favorites feed: keep the splash over it
        // so this generation's fail-closed deadline is meaningful again.
        favoritesFeedReady = false
        harvestFavorites()
        if let home = webViews[.home], let url = URL(string: homeURLString) {
            load(URLRequest(url: url), in: home, reason: reason)
        }
    }

    // MARK: - Webview process / navigation recovery

    /// WebKit killed the content process (usually memory pressure while four
    /// persistent webviews plus the harvest webview are alive). Reload rather
    /// than leave a blank page, preserving the scroll position, and give up
    /// into a visible degraded state rather than looping.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logNavigationLifecycle("processTerminated", webView: webView)
        if webView === favHarvestWebView {
            recoverHarvestWebView(reason: "content process terminated")
        } else {
            recoverTab(webView, reason: "content process terminated")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(webView, navigation: navigation, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(webView, navigation: navigation, error: error, provisional: true)
    }

    private func handleNavigationFailure(
        _ webView: WKWebView,
        navigation: WKNavigation?,
        error: Error,
        provisional: Bool = false
    ) {
        logNavigationLifecycle(
            provisional ? "didFailProvisional" : "didFail",
            webView: webView,
            navigation: navigation,
            error: error
        )
        let nsError = error as NSError
        // -999 is an ordinary cancel (a new load superseded this one, which the
        // harvest and every retry path do constantly). WebKitErrorDomain 102 is
        // "frame load interrupted by policy change" — literally what our own
        // decidePolicyFor(.cancel) produces for /reels and /explore, so
        // treating it as a failure would fight the R2 block.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        let reason = "navigation failed (\(nsError.domain) \(nsError.code))"
        if webView === favHarvestWebView {
            recoverHarvestWebView(reason: reason)
        } else {
            recoverTab(webView, reason: reason)
        }
    }

    private func recoverTab(_ webView: WKWebView, reason: String) {
        let key = ObjectIdentifier(webView)
        let target = webViews.first { $0.value === webView }?.key
        let label = target.map(String.init(describing:)) ?? "unknown tab"
        let attempt = (recoveryAttempts[key] ?? 0) + 1
        guard attempt <= Self.maxRecoveryAttempts else {
            print("[BI-recovery] \(label): \(reason); giving up after \(Self.maxRecoveryAttempts) attempts")
            if target == .home {
                DispatchQueue.main.async { [weak self] in self?.failFeedClosed("home webview unrecoverable — \(reason)") }
            }
            return
        }
        recoveryAttempts[key] = attempt
        // After a content-process kill the scroll view keeps its last offset,
        // so stash it now and restore it once the replacement content lays out.
        let offset = webView.scrollView.contentOffset
        if offset.y > 0 { pendingScrollRestore[key] = offset }
        print("[BI-recovery] \(label): \(reason); reloading (attempt \(attempt))")
        let fallback = target.flatMap { $0 == .home ? homeURLString : startURLs[$0] }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(attempt)) { [weak webView] in
            guard let webView else { return }
            if webView.url != nil {
                self.reload(webView, reason: "recovery-\(label)-attempt-\(attempt): \(reason)")
            } else if let fallback, let url = URL(string: fallback) {
                self.load(
                    URLRequest(url: url),
                    in: webView,
                    reason: "recovery-fallback-\(label)-attempt-\(attempt): \(reason)"
                )
            }
        }
    }

    private func destroyHarvestWebView(reason: String) {
        guard let webView = favHarvestWebView else { return }
        print("[BI-harvest] destroying offscreen webview: \(reason)")
        navigationTraces.removeValue(forKey: ObjectIdentifier(webView))
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        favHarvestWebView = nil
    }

    /// The harvest webview is offscreen and disposable, so recovery discards it
    /// and starts a fresh harvest generation rather than reloading a webview
    /// whose process just died. Exhausting the budget fails the feed closed.
    private func recoverHarvestWebView(reason: String) {
        destroyHarvestWebView(reason: "recovery: \(reason)")
        harvestRecoveryAttempts += 1
        guard harvestRecoveryAttempts <= Self.maxRecoveryAttempts else {
            print("[BI-harvest] harvest webview \(reason); giving up after \(Self.maxRecoveryAttempts) retries")
            DispatchQueue.main.async { [weak self] in self?.failFeedClosed("harvest webview \(reason)") }
            return
        }
        print("[BI-harvest] harvest webview \(reason); retry \(harvestRecoveryAttempts)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.harvestFavorites()
        }
    }

    private func restoreScrollPositionIfNeeded(for webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        recoveryAttempts[key] = 0
        guard let offset = pendingScrollRestore.removeValue(forKey: key) else { return }
        // One layout pass after didFinish the content height is real; clamp so
        // a now-shorter page can't be scrolled past its end.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak webView] in
            guard let webView else { return }
            let scrollView = webView.scrollView
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            guard maxY > 0 else { return }
            scrollView.setContentOffset(CGPoint(x: 0, y: min(offset.y, maxY)), animated: false)
        }
    }

    // MARK: - Back/forward edge-swipe (SPA-safe replacement for allowsBackForwardNavigationGestures)

    /// Manual replacement for `WKWebView.allowsBackForwardNavigationGestures`.
    /// Mirrors its edge zones but calls `goBack()`/`goForward()` directly on
    /// release instead of letting WebKit drive its own interactive
    /// transition, which reloads (and flashes blank/white) on same-document
    /// SPA history entries.
    private func addBackForwardSwipeGestures(to webView: WKWebView) {
        let back = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleBackSwipeGesture(_:)))
        back.edges = .left
        webView.addGestureRecognizer(back)

        let forward = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleForwardSwipeGesture(_:)))
        forward.edges = .right
        webView.addGestureRecognizer(forward)
    }

    @objc private func handleBackSwipeGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended,
            let webView = gesture.view as? WKWebView,
            webView.canGoBack
        else { return }
        webView.goBack()
    }

    @objc private func handleForwardSwipeGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended,
            let webView = gesture.view as? WKWebView,
            webView.canGoForward
        else { return }
        webView.goForward()
    }

    // MARK: - Pull to refresh (home)

    /// Pull down on the home feed → commit the native spinner and haptic, keep
    /// the current document visible for 0.4 seconds, then rebuild behind the
    /// splash. Delaying the real load is what makes pull → spin → splash visible.
    @objc private func handlePullToRefresh() {
        guard !refreshInFlight, let home = webViews[.home] else { return }
        refreshInFlight = true
        refreshPhase = .pullCommitted
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.prepare()
        feedback.impactOccurred()
        let scroll = home.scrollView
        print("[BI-refresh] valueChanged phase=pullCommitted offset=\(scroll.contentOffset.y) " +
            "inset=\(scroll.adjustedContentInset) isRefreshing=\(homeRefreshControl?.isRefreshing ?? false)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.refreshInFlight else { return }
            self.refreshPhase = .rebuilding
            print("[BI-refresh] phase=rebuilding; starting reharvest/load")
            self.reharvestAndReloadHome(reason: "pull-to-refresh")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.endRefresh()
        }
    }

    private func endRefresh() {
        guard refreshInFlight else { return }
        refreshInFlight = false
        refreshPhase = .idle
        print("[BI-refresh] phase=idle")
        homeRefreshControl?.endRefreshing()
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
            ?? scenes.flatMap { $0.windows }.first
    }

    /// Profile search for the favorites picker, run inside the logged-in home
    /// webview so it rides on the page's own session cookies — the same
    /// endpoint the web client's search box calls.
    func searchProfiles(matching query: String) async -> [FavoriteProfile] {
        let script = """
        const response = await fetch('/api/v1/web/search/topsearch/?context=blended&query=' +
            encodeURIComponent(query) + '&search_surface=web_top_search', {
            headers: { 'X-IG-App-ID': '936619743392459' },
            credentials: 'include'
        });
        if (!response.ok) { throw new Error('search failed: ' + response.status); }
        const payload = await response.json();
        return JSON.stringify((payload.users || []).map(function(item) {
            return {
                username: item.user.username,
                fullName: item.user.full_name || '',
                avatar: item.user.profile_pic_url || ''
            };
        }));
        """
        return await runProfileScript(script, arguments: ["query": query])
    }

    /// The logged-in user's following list (own user id comes from the
    /// non-HttpOnly ds_user_id cookie), paginated up to 500 accounts.
    func fetchFollowing() async -> [FavoriteProfile] {
        let script = """
        const cookieMatch = document.cookie.match(/ds_user_id=([0-9]+)/);
        if (!cookieMatch) { return '[]'; }
        const userId = cookieMatch[1];
        const collected = [];
        let maxId = '';
        for (let page = 0; page < 5; page++) {
            const url = '/api/v1/friendships/' + userId + '/following/?count=100' +
                (maxId ? '&max_id=' + encodeURIComponent(maxId) : '');
            const response = await fetch(url, {
                headers: { 'X-IG-App-ID': '936619743392459' },
                credentials: 'include'
            });
            if (!response.ok) { break; }
            const payload = await response.json();
            (payload.users || []).forEach(function(u) {
                collected.push({
                    username: u.username,
                    fullName: u.full_name || '',
                    avatar: u.profile_pic_url || ''
                });
            });
            if (!payload.next_max_id) { break; }
            maxId = String(payload.next_max_id);
        }
        return JSON.stringify(collected);
        """
        return await runProfileScript(script, arguments: [:])
    }

    private func runProfileScript(_ script: String, arguments: [String: Any]) async -> [FavoriteProfile] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let webView = self?.webViews[.home] else {
                    continuation.resume(returning: [])
                    return
                }
                webView.callAsyncJavaScript(
                    script,
                    arguments: arguments,
                    in: nil,
                    in: .page
                ) { result in
                    guard case .success(let value) = result,
                          let json = value as? String,
                          let data = json.data(using: .utf8),
                          let profiles = try? JSONDecoder().decode([FavoriteProfile].self, from: data) else {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(returning: profiles)
                }
            }
        }
    }

    // MARK: - Session

    private static func sessionID(from cookies: [HTTPCookie]) -> String {
        cookies.first(where: {
            $0.name == "sessionid" && $0.domain.contains("instagram.com")
        })?.value ?? ""
    }

    /// Account identity. `sessionid` is the login signal but its value also
    /// rotates on re-auth/2FA within one account, so it can't tell an account
    /// switch from a refreshed session. `ds_user_id` is the account's numeric
    /// id and only changes when the account does.
    private static func userID(from cookies: [HTTPCookie]) -> String {
        cookies.first(where: {
            $0.name == "ds_user_id" && $0.domain.contains("instagram.com")
        })?.value ?? ""
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                guard let self else { return }
                let session = Self.sessionID(from: cookies)
                let user = Self.userID(from: cookies)
                let wasLoggedOut = self.lastSessionID.isEmpty
                let previousUser = self.lastUserID
                // An account switch inside the same shared data store: every
                // cached artifact (harvested edges, sync baseline, resolved
                // profile) belongs to the PREVIOUS account and would otherwise
                // be spliced straight into the new account's feed.
                let switchedAccount = !previousUser.isEmpty && !user.isEmpty && user != previousUser
                guard session != self.lastSessionID || switchedAccount else { return }
                self.lastSessionID = session
                self.lastUserID = user
                self.isLoggedIn = !session.isEmpty
                if switchedAccount || (session.isEmpty && !previousUser.isEmpty) {
                    self.resetAccountDerivedState(loggedOut: session.isEmpty)
                }
                guard !session.isEmpty else { return }
                if switchedAccount {
                    self.reloadSecondaryTabs(reason: "account-switch")
                    if let home = self.webViews[.home], let url = URL(string: self.homeURLString) {
                        self.load(URLRequest(url: url), in: home, reason: "account-switch-home")
                    }
                    self.harvestFavorites()
                } else if wasLoggedOut {
                    self.reloadSecondaryTabs(reason: "login")
                    self.harvestFavorites()
                }
            }
        }
    }

    /// Clears the state derived from one specific Instagram account. The
    /// favorites *picks* themselves live in `FavoritesStore` under global,
    /// un-namespaced `UserDefaults` keys and are deliberately not touched here
    /// — see known-issues.md for the remaining namespacing work. This only
    /// stops the previous account's harvest, sync baseline and profile
    /// resolution from leaking into the next one.
    @MainActor
    private func resetAccountDerivedState(loggedOut: Bool) {
        // Invalidate and dispose any harvest still in flight for the previous
        // account so a late didFinish cannot extract its edges under the new
        // generation after logout/account switch.
        harvestGeneration += 1
        destroyHarvestWebView(reason: loggedOut ? "logout" : "account switch")
        cachedFavEdgesJSON = nil
        preloadedFromDiskJSON = nil
        UserDefaults.standard.removeObject(forKey: Self.favEdgesCacheKey)
        // The remove-side reconcile baseline is "what this app added for THAT
        // account" — applying it to another account would unfavorite accounts
        // it never touched.
        UserDefaults.standard.removeObject(forKey: Self.syncedFavoritesKey)
        favoritesSyncDegraded = false
        UserDefaults.standard.set(false, forKey: Self.favoritesSyncDegradedKey)
        profileResolved = false
        resolvedProfileURLString = nil
        didReloadHomeForFavorites = false
        didRunLaunchSync = false
        harvestRecoveryAttempts = 0
        feedRecoveryAttempts = 0
        feedStuck = false
        favoritesFeedReady = false
        // Drops window.__biFavEdgesPreload so the next document-start injection
        // cannot SSR-splice the old account's posts.
        installUserScripts()
        print("[BI] \(loggedOut ? "logged out" : "account changed") — cleared account-derived state")
    }

    private func reloadSecondaryTabs(reason: String) {
        for target in [NavTarget.search, .direct, .profile] {
            if let webView = webViews[target], let start = startURLs[target], let url = URL(string: start) {
                load(URLRequest(url: url), in: webView, reason: "\(reason)-\(target)")
            }
        }
    }

    // MARK: - WKNavigationDelegate / WKUIDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame ?? true,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else {
            // about:/blob:/data: are WebKit's own internals, not navigation the
            // user asked for. The handful of schemes the system genuinely owns
            // go to the OS. Everything else — instagram://, fb://, itms-apps:
            // — is an "open in the app" nag, and following it would eject the
            // user into the very app this one exists to replace.
            if Self.webKitInternalSchemes.contains(scheme) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if Self.externallyOpenableSchemes.contains(scheme) {
                    UIApplication.shared.open(url)
                }
            }
            return
        }

        // Host-scoped: matching on path alone also cancelled any other site's
        // /reels or /explore page. The R2 block is about Instagram's own routes.
        if Self.isInAppHost(url), blockedExactPaths.contains(url.path) {
            decisionHandler(.cancel)
            if webView.canGoBack {
                registerNavigation(webView, reason: "blocked-route-goBack", url: url)
                associate(webView.goBack(), with: webView)
            } else {
                load(
                    URLRequest(url: URL(string: "https://www.instagram.com/")!),
                    in: webView,
                    reason: "blocked-route-home"
                )
            }
            return
        }

        // A tapped link leaving the Meta host family is a real web page, not
        // part of this app — hand it to Safari. Only .linkActivated qualifies:
        // redirects and client-driven loads arrive as .other, and Instagram's
        // login / challenge / 2FA flows hop between instagram.com and
        // facebook.com that way, so intercepting them would break sign-in.
        if navigationAction.navigationType == .linkActivated, !Self.isInAppHost(url) {
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
            return
        }

        decisionHandler(.allow)
    }

    // target="_blank" links (common on DM share cards) otherwise go nowhere;
    // route Instagram's own into the same webview so the reel permalink
    // actually opens, and genuinely external ones out to Safari.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else { return nil }
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        if Self.isInAppHost(url) {
            load(URLRequest(url: url), in: webView, reason: "target-blank")
        } else {
            UIApplication.shared.open(url)
        }
        return nil
    }

    // Hosts that stay in-app. Instagram's login, checkpoint/challenge, 2FA and
    // Accounts Center flows redirect across the Meta host family, and the
    // Safari session shares none of this app's cookies, so bouncing any of
    // them out would strand the user mid-sign-in.
    private static let inAppHostSuffixes = [
        "instagram.com", "cdninstagram.com", "facebook.com", "fbcdn.net",
        "fb.com", "messenger.com", "meta.com", "threads.com", "threads.net"
    ]
    private static let webKitInternalSchemes: Set<String> = ["about", "blob", "data"]
    private static let externallyOpenableSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "maps"
    ]

    private static func isInAppHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return inAppHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        logNavigationLifecycle("didStart", webView: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        logNavigationLifecycle("didCommit", webView: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logNavigationLifecycle("didFinish", webView: webView, navigation: navigation)
        if webView === favHarvestWebView {
            harvestExtract(generation: harvestGeneration)
            return
        }
        restoreScrollPositionIfNeeded(for: webView)
        webView.evaluateJavaScript(ContentFilter.reapplyCall, completionHandler: nil)
        webView.evaluateJavaScript(
            "({version: window.__biVersion || null, reapply: typeof window.__biReapply})"
        ) { [weak self, weak webView] value, error in
            guard let self, let webView else { return }
            print("[BI-health] target=\(self.targetLabel(for: webView)) value=\(String(describing: value)) " +
                "error=\(error?.localizedDescription ?? "none")")
        }
        // Re-push cached favorites edges to the home tab on every (re)load so the
        // splice has them even after a navigation resets the page's JS state.
        if cachedFavEdgesJSON != nil {
            deliverFavEdges()
        }
        // Once per launch, after the home page exists (the sync's fetches run in
        // its page context): reconcile the server Favorites list with the app
        // picks, so a previously failed/partial sync self-heals on every boot.
        // Re-harvest if a write actually happened so the feed reflects it.
        if webView === webViews[.home], !didRunLaunchSync, isLoggedIn, favorites.isFilterEnabled {
            didRunLaunchSync = true
            Task { @MainActor in
                let summary = await syncFavoritesToInstagram()
                if summary.contains("wrote favorites") {
                    harvestFavorites()
                }
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if message.name == "biNav", let visible = message.body as? Bool {
            let source = message.webView
            DispatchQueue.main.async {
                if let source {
                    self.navVisibleCache[ObjectIdentifier(source)] = visible
                    self.updateBottomClearance(for: source, navVisible: visible)
                }
                if source === self.webViews[self.activeTarget] {
                    if UIAccessibility.isReduceMotionEnabled {
                        self.bridge.isNavVisible = visible
                    } else {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            self.bridge.isNavVisible = visible
                        }
                    }
                }
            }
        } else if message.name == "biAvatar", let urlString = message.body as? String {
            DispatchQueue.main.async {
                self.bridge.avatarURL = URL(string: urlString)
            }
        } else if message.name == "biProfile", let href = message.body as? String {
            DispatchQueue.main.async {
                guard !self.profileResolved,
                      let url = URL(string: "https://www.instagram.com" + href) else { return }
                self.profileResolved = true
                self.resolvedProfileURLString = url.absoluteString
                // Preload immediately only if the profile tab already exists
                // (was already visited); otherwise its eventual lazy creation
                // will load this resolved URL directly (see makeWebView).
                if let profile = self.webViews[.profile] {
                    self.load(URLRequest(url: url), in: profile, reason: "profile-resolved")
                }
            }
        } else if message.name == "biFavEdit" {
            DispatchQueue.main.async {
                self.bridge.favoritesEditRequests += 1
            }
        } else if message.name == "biFavReady" {
            DispatchQueue.main.async {
                self.favoritesFeedReady = true
                // The feed rendered (or at least the data/apply-ready signal
                // fired): clear the retry screen if it was already showing.
                // Deliberately NOT resetting feedRecoveryAttempts here anymore
                // — it used to be reset on every biFavReady, which replenished
                // handleFeedStuck()'s one-auto-recovery budget on every single
                // reload cycle. When biFavReady can fire without the feed ever
                // actually showing a visible favorite (SSR splice + apply()
                // both succeed, but React hasn't hydrated the DOM with the
                // spliced data yet), that turned into an infinite
                // reload→biFavReady→watchdog-stuck→reload loop that never
                // reached the retry screen. The budget now only refills on an
                // explicit new attempt: applyFavoritesSelection(),
                // retryFavoritesFeed(), or an account switch
                // (resetAccountDerivedState) — see known-issues.md §4.
                self.feedStuck = false
                self.endRefresh()
                #if DEBUG
                if ProcessInfo.processInfo.environment["BI_STORY_TIMING_PROBE"] == "1",
                   !self.didRunStoryTimingProbe,
                   let home = self.webViews[.home] {
                    self.didRunStoryTimingProbe = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        home.evaluateJavaScript("""
                        (function clickStory(attempt) {
                          const hit = document.elementFromPoint(window.innerWidth * 0.38, 150);
                          const target = hit && (hit.closest('a, button, [role="button"], [role="link"]') || hit);
                          if (target) { target.click(); return; }
                          if (attempt < 100) setTimeout(function() { clickStory(attempt + 1); }, 200);
                        })(0);
                        """)
                    }
                }
                #endif
            }
        } else if message.name == "biFeedStuck" {
            DispatchQueue.main.async { self.handleFeedStuck() }
        } else if message.name == "biPresentation",
                  let payload = message.body as? [String: Any],
                  let locked = payload["locked"] as? Bool,
                  let immersive = payload["immersive"] as? Bool {
            let source = message.webView
            DispatchQueue.main.async {
                guard let source else { return }
                self.setPresentation(locked: locked, immersive: immersive, for: source)
            }
        } else if message.name == "biBg", let css = message.body as? String {
            if let color = Self.parseCSSColor(css) {
                let source = message.webView
                DispatchQueue.main.async {
                    let uiColor = UIColor(color)
                    source?.backgroundColor = uiColor
                    source?.scrollView.backgroundColor = uiColor
                    if let source {
                        self.pageBackgroundCache[ObjectIdentifier(source)] = color
                    }
                    if source === self.webViews[self.activeTarget] {
                        self.bridge.pageBackground = color
                        self.bridge.safeAreaBackground = color
                    }
                }
            }
        } else if message.name == "biLog", let text = message.body as? String {
            print("[BI-DEBUG] \(text)")
        }
    }

    static func parseCSSColor(_ css: String) -> Color? {
        let values = css
            .replacingOccurrences(of: "rgba(", with: "")
            .replacingOccurrences(of: "rgb(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count >= 3 else { return nil }
        return Color(
            red: values[0] / 255.0,
            green: values[1] / 255.0,
            blue: values[2] / 255.0
        )
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
