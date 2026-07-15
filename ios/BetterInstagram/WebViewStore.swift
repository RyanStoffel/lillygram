import SwiftUI
import WebKit

final class WebViewStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKHTTPCookieStoreObserver {
    @Published private(set) var isLoggedIn = false
    /// True once the home tab has actually rendered the favorites feed. Drives
    /// the launch splash that hides the cold-start harvest + reload.
    @Published private(set) var favoritesFeedReady = false

    private var webViews: [NavTarget: WKWebView] = [:]
    private var navVisibleCache: [ObjectIdentifier: Bool] = [:]
    private let bridge: WebBridge
    private let favorites: FavoritesStore
    private let userContentController = WKUserContentController()
    private var activeTarget: NavTarget = .home
    private var profileResolved = false
    private var lastSessionID = ""
    // Hidden webview that navigates to /?variant=favorites (the only way IG
    // streams the favorites feed) so its edges can be harvested and spliced into
    // the visible home tab. Isolated controller so ContentFilter doesn't run in it.
    private var favHarvestWebView: WKWebView?
    private let favHarvestController = WKUserContentController()
    private var cachedFavEdgesJSON: String?
    private var didReloadHomeForFavorites = false
    private var didRunLaunchSync = false
    private let blockedExactPaths: Set<String> = ["/reels", "/reels/", "/explore", "/explore/"]

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

        installUserScripts()
        userContentController.add(self, name: "biNav")
        userContentController.add(self, name: "biAvatar")
        userContentController.add(self, name: "biProfile")
        userContentController.add(self, name: "biBg")
        userContentController.add(self, name: "biScroll")
        userContentController.add(self, name: "biFavEdit")
        userContentController.add(self, name: "biFavReady")
        userContentController.add(self, name: "biLog")

        let dataStore = WKWebsiteDataStore.default()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController = userContentController
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        for target in [NavTarget.home, .search, .direct, .profile] {
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.isOpaque = false
            webView.backgroundColor = .systemBackground
            webView.scrollView.backgroundColor = .systemBackground
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.allowsBackForwardNavigationGestures = true
            webView.removeInputAccessoryView()
            let startURL = target == .home ? homeURLString : startURLs[target]!
            webView.load(URLRequest(url: URL(string: startURL)!))
            webViews[target] = webView
        }

        dataStore.httpCookieStore.add(self)
        dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastSessionID = Self.sessionID(from: cookies)
                self.isLoggedIn = !self.lastSessionID.isEmpty
                if self.isLoggedIn { self.harvestFavorites() }
            }
        }
    }

    func webView(for target: NavTarget) -> WKWebView {
        webViews[target]!
    }

    func setActive(_ target: NavTarget) {
        activeTarget = target
        if let webView = webViews[target] {
            bridge.isNavVisible = navVisibleCache[ObjectIdentifier(webView)] ?? true
        }
        if target == .profile && !profileResolved {
            webViews[.profile]?.evaluateJavaScript(
                "window.__biNavigate('profile')",
                completionHandler: nil
            )
        }
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
            favoritesFeedReady = false
            harvestFavorites()
            if let url = URL(string: homeURLString) {
                webViews[.home]?.load(URLRequest(url: url))
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
        // it is only used for the one-time CF cleanup below.
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
        let wrote = 0;
        if (add.length && dtsg) {
            try {
                const body = new URLSearchParams({
                    av: av, __a: '1', __comet_req: '7',
                    fb_dtsg: dtsg, lsd: lsd,
                    fb_api_caller_class: 'RelayModern',
                    fb_api_req_friendly_name: FAV_FN,
                    variables: JSON.stringify({ data: { add: add, remove: [], source: 'favorites_management' } }),
                    server_timestamps: 'true',
                    doc_id: FAV_DOC_ID
                });
                const r = await fetch('/api/graphql', {
                    method: 'POST', credentials: 'include',
                    headers: {
                        'X-CSRFToken': csrf, 'X-IG-App-ID': APP_ID, 'X-FB-LSD': lsd,
                        'X-FB-Friendly-Name': FAV_FN,
                        'Content-Type': 'application/x-www-form-urlencoded'
                    },
                    body: body.toString()
                });
                const t = await r.text();
                if (r.ok && t.indexOf('"errors"') === -1) { wrote = add.length; }
                else { log('favmut status=' + r.status + ' body=' + t.slice(0, 200)); }
            } catch (e) { log('favmut err ' + e); }
        } else if (add.length) {
            log('favmut SKIPPED: no fb_dtsg token (dtsg=' + (dtsg ? 'y' : 'n') + ' lsd=' + (lsd ? 'y' : 'n') + ')');
        }
        // Verify the writes took: re-check the favorites flag for every add.
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
        if (!add.length) {
            return 'already in sync (' + ids.length + ' picks)' + followNote + cleanNote;
        }
        return 'wrote favorites add=' + add.length + ' ok=' + wrote +
            ' confirmed=' + confirmed + ' picks=' + ids.length + '/' + usernames.length +
            followNote + cleanNote;
        """
        let cleanupNeeded = !UserDefaults.standard.bool(forKey: "biDidCleanBesties")
        let result: String = await withCheckedContinuation { continuation in
            webView.callAsyncJavaScript(
                script,
                arguments: ["usernames": usernames, "cleanupBesties": cleanupNeeded],
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
        return result
    }

    // MARK: - Favorites harvest

    /// Load /?variant=favorites in a hidden webview (a real navigation is the
    /// only thing that makes IG stream the favorites feed) so its edges can be
    /// extracted and pushed into the visible home tab.
    func harvestFavorites() {
        guard favorites.isFilterEnabled, !lastSessionID.isEmpty else { return }
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
        print("[BI-harvest] loading /?variant=favorites")
        webView.load(URLRequest(url: URL(string: "https://www.instagram.com/?variant=favorites")!))
        // Safety net: never let the launch splash stick if the feed never signals.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.favoritesFeedReady = true
        }
    }

    private func harvestExtract() {
        guard let webView = favHarvestWebView else { return }
        // Small settle, then the harvest script itself scrolls to paginate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let webView = self.favHarvestWebView else { return }
            webView.callAsyncJavaScript(
                ContentFilter.harvestScript,
                arguments: [:],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    guard let json = value as? String else {
                        print("[BI-harvest] no string returned")
                        return
                    }
                    self.logHarvestSummary(json)
                    self.densifyHarvest(json)
                case .failure(let error):
                    print("[BI-harvest] extract error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Append each favorite's recent profile media to the streamed edges (the
    /// density pass, see ContentFilter.densityScript). Fail-safe: any error or
    /// empty result falls back to the streamed-only harvest unchanged.
    private func densifyHarvest(_ json: String) {
        guard harvestCount(json) > 0, let webView = favHarvestWebView else {
            finishHarvest(json)
            return
        }
        let usernames = favorites.favorites.map(\.username)
        webView.callAsyncJavaScript(
            ContentFilter.densityScript,
            arguments: ["harvestJson": json, "usernames": usernames],
            in: nil,
            in: .page
        ) { result in
            switch result {
            case .success(let value):
                if let augmented = value as? String, self.harvestCount(augmented) >= self.harvestCount(json) {
                    print("[BI-density] appended \(self.harvestCount(augmented) - self.harvestCount(json)) profile posts"
                        + " fetch=\(self.harvestFetchStats(augmented))")
                    self.finishHarvest(augmented)
                } else {
                    print("[BI-density] no augmentation; using streamed edges only")
                    self.finishHarvest(json)
                }
            case .failure(let error):
                print("[BI-density] error: \(error.localizedDescription); using streamed edges only")
                self.finishHarvest(json)
            }
        }
    }

    private func finishHarvest(_ json: String) {
        cachedFavEdgesJSON = json
        deliverFavEdges()
        // Refresh the preamble so window.__biFavEdgesPreload carries the latest
        // edges on any future page load (the document-start SSR splice reads it).
        if harvestCount(json) > 0 {
            installUserScripts()
        }
        // After the first successful harvest, reload home once so the
        // now-cached favorites splice lands deterministically (no
        // cold-start race).
        if harvestCount(json) > 0 && !didReloadHomeForFavorites {
            didReloadHomeForFavorites = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.webViews[.home]?.reload()
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
    private func deliverFavEdges() {
        guard let json = cachedFavEdgesJSON else { return }
        for webView in webViews.values {
            webView.callAsyncJavaScript(
                "window.__biSetFavEdges && window.__biSetFavEdges(payload);",
                arguments: ["payload": json],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }
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

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                guard let self else { return }
                let session = Self.sessionID(from: cookies)
                guard session != self.lastSessionID else { return }
                let wasLoggedOut = self.lastSessionID.isEmpty
                self.lastSessionID = session
                self.isLoggedIn = !session.isEmpty
                if wasLoggedOut && !session.isEmpty {
                    self.reloadSecondaryTabs()
                    self.harvestFavorites()
                }
            }
        }
    }

    private func reloadSecondaryTabs() {
        for target in [NavTarget.search, .direct, .profile] {
            if let url = URL(string: startURLs[target]!) {
                webViews[target]?.load(URLRequest(url: url))
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

        if blockedExactPaths.contains(url.path) {
            decisionHandler(.cancel)
            if webView.canGoBack {
                webView.goBack()
            } else {
                webView.load(URLRequest(url: URL(string: "https://www.instagram.com/")!))
            }
            return
        }

        decisionHandler(.allow)
    }

    // target="_blank" links (common on DM share cards) otherwise go nowhere;
    // route them into the same webview so the reel permalink actually opens.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === favHarvestWebView {
            harvestExtract()
            return
        }
        webView.evaluateJavaScript(ContentFilter.reapplyCall, completionHandler: nil)
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
                }
                if source === self.webViews[self.activeTarget] {
                    self.bridge.isNavVisible = visible
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
                self.webViews[.profile]?.load(URLRequest(url: url))
            }
        } else if message.name == "biFavEdit" {
            DispatchQueue.main.async {
                self.bridge.favoritesEditRequests += 1
            }
        } else if message.name == "biFavReady" {
            DispatchQueue.main.async {
                self.favoritesFeedReady = true
            }
        } else if message.name == "biScroll", let locked = message.body as? Bool {
            let source = message.webView
            DispatchQueue.main.async {
                source?.scrollView.isScrollEnabled = !locked
            }
        } else if message.name == "biBg", let css = message.body as? String {
            if let color = Self.parseCSSColor(css) {
                let source = message.webView
                DispatchQueue.main.async {
                    self.bridge.pageBackground = color
                    let uiColor = UIColor(color)
                    source?.backgroundColor = uiColor
                    source?.scrollView.backgroundColor = uiColor
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
