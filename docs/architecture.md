# Architecture

## One-paragraph model

Lillygram is a thin SwiftUI shell around **four persistent `WKWebView`s**
(one per tab: home, search, direct, profile) that all load the real
`instagram.com` and **share a single `WKUserContentController`**. Home is created
in `WebViewStore.init()`; search/direct/profile are created immediately from
`ContentView.onAppear` behind the launch splash (see "The WKWebView layer").
That controller
injects one large JavaScript userscript at **document start** into every page.
The userscript does all the "product": blocking reels/explore, locking DM reels,
normalizing URL-less DM share cards to one physical tap, filtering the feed,
fixing the header, and reporting page state back to Swift via message handlers.
A **fifth hidden webview** is created only while actively harvesting the
favorites feed and is detached/destroyed after a successful extraction+density
pass (see `favorites-feed.md`). Native and web talk over `postMessage` handlers
and `evaluateJavaScript` / `callAsyncJavaScript`.

## Files (all under `ios/Lillygram/`)

| File | Role |
| --- | --- |
| `LillygramApp.swift` | `@main` App; shows `ContentView`. |
| `ContentView.swift` | Root `TabView` (home/search/direct/profile), onboarding cover, favorites-editor sheet, the two splashes (`LaunchSplashView`/`ResaveSplashView`) chosen by `activeSplash`, and the `FeedErrorView` retry screen. |
| `WebViewStore.swift` | Owns the 4 tab webviews (home eager; others created via `ensureWebView(for:)`, called for all three during the launch splash by `ContentView.preloadSecondaryTabs()` — see architecture note below) + the disposable harvest webview; the shared `WKUserContentController`; login detection; favorites sync/harvest; navigation reason/id tracing; visibility-aware bottom clearance; and the home `UIRefreshControl` phase machine. The native brain. |
| `ContentFilter.swift` | **The injected userscript**, as a Swift multiline string (`ContentFilter.script`), plus `harvestScript`. All web-side behavior lives here. |
| `WebBridge.swift` | `NavTarget` enum (`home/search/direct/profile`) + `@Published` UI state (`isNavVisible`, `avatarURL`, `pageBackground`, `favoritesEditRequests`). |
| `FavoritesStore.swift` | `UserDefaults`-backed favorites selection + onboarding-complete flag; `isFilterEnabled`. |
| `OnboardingView.swift` | `FavoritesPickerView` — post-login onboarding + the star-tab editor; lists the user's following + global search. |
| `WKWebView+NoAccessory.swift` | Removes the keyboard input-accessory bar. |
| `BlockingRules.json` | Bundled `WKContentRuleList` source — a single static `css-display-none` rule for the Explore/Reels nav chrome, compiled by `WebViewStore.compileContentRuleList()`. Additive defense-in-depth; the equivalent JS/CSS hides stay in `ContentFilter.swift`. |

## The WKWebView layer

- **Eager creation for all four, hidden behind the launch splash (2026-07-21).**
  `WebViewStore.init()` still only builds **home** directly (needed immediately
  for the launch splash + favorites harvest + first paint). Search/direct/profile
  are created via `ensureWebView(for:)` — called from `webView(for:)` (which
  `ContentView`'s `webContent(for:)` uses) and from `setActive(_:)` — but
  `ContentView.preloadSecondaryTabs()` now calls `store.webView(for:)` for all
  three on `.onAppear` and marks them in `createdTabs` immediately, rather than
  waiting for each tab's first visit. This trades a little launch-time
  memory/CPU (previously avoided by true lazy creation) for zero visible delay
  switching tabs, since the extra creation/load work happens during the launch
  splash's existing dead time (already masking the favorites harvest) instead of
  becoming visible the first time a user taps Search/Direct/Profile. Every
  created webview stays alive for the rest of the process — switching tabs
  always shows the same warm instance, never a reload. This is central to R4
  (fast, native-feeling). `ContentView` still shows a plain `ProgressView`
  placeholder if a tab is ever visited before `createdTabs` catches up (e.g. a
  very fast tap right at launch), but in practice this no longer happens.
- **Shared config.** One `WKWebViewConfiguration` (`webViewConfiguration`) with
  `WKWebsiteDataStore.default()` (so cookies/login are shared across tabs) and
  the shared `userContentController` — every lazily-created webview gets it, so
  a newly created tab already carries the current favorites preamble / cached
  favorite edges without extra work.
- **Profile tab's resolved URL.** The profile tab starts at `instagram.com/`
  and gets JS-navigated to the user's real profile once its href is detected
  from the nav row (usually from the home tab, via the `biProfile` handler).
  That href is cached in `resolvedProfileURLString` even before the profile
  webview exists, so its first creation loads the real profile URL directly
  instead of the plain root.
- **Injection.** `installUserScripts()` adds two `WKUserScript`s at
  `.atDocumentStart`, `forMainFrameOnly: false`:
  1. a tiny preamble that seeds `window.__biFavorites` / `window.__biFavoritesEnabled`;
  2. `ContentFilter.script` — the userscript.
  Document-start injection is required so hooks (XHR/fetch, `history.pushState`,
  location guard) are installed **before** Instagram's own code runs.
- **User agent** is pinned to a mobile Safari UA so Instagram serves the mobile
  web experience.
- **Content rule list.** `compileContentRuleList()` (called at the top of
  `init()`, before the home webview is created) compiles the bundled
  `BlockingRules.json` via `WKContentRuleListStore.default()` and adds the
  result to the shared `userContentController` once ready. Compilation is
  async, so a cold-launch first paint may occasionally land just before it's
  installed; every load/reload after that carries it. Failure (missing
  resource, bad JSON, store error) is caught and logged — the app falls back
  to JS/CSS-only blocking, unchanged from before this addition.
- **Login detection & account identity.** `WebViewStore` observes the cookie
  store; presence of the `sessionid` cookie flips `isLoggedIn`. Account
  *identity* is keyed on **`ds_user_id`**, not `sessionid` — `sessionid`'s value
  also rotates on re-auth/2FA within one account, so it can't tell an account
  switch from a refreshed session. A changed `ds_user_id` (or logout) runs
  `resetAccountDerivedState()`, which invalidates the harvest generation and
  clears the cached/persisted fav edges, the sync baseline
  (`biSyncedFavoriteUsernames`), the degraded-sync flag and the resolved profile
  URL, then reinstalls the user scripts so `__biFavEdgesPreload` can't SSR-splice
  the previous account's posts. The favorites *picks* live in `FavoritesStore`
  under global, un-namespaced keys and are **not** reset — see known-issues.md.
- **Navigation policy** (`decidePolicyFor`). Host-scoped, not path-only:
  `/reels`//`/explore` are cancelled only on Meta-family hosts. A
  `.linkActivated` navigation to a host outside that family goes to Safari;
  redirects and client-driven loads (`.other`) are never intercepted, so
  Instagram's login/challenge/2FA hops between `instagram.com` and
  `facebook.com` stay in-app. `about:`/`blob:`/`data:` are allowed (WebKit
  internals); `mailto:`/`tel:`/`sms:`/`facetime:`/`maps:` go to the OS; every
  other scheme (`instagram://`, `fb://`, `itms-apps:` — the "open in the app"
  nags) is cancelled. `createWebViewWith` (`target="_blank"`) follows the same
  in-app/Safari split.
- **Process & navigation recovery.** `webViewWebContentProcessDidTerminate`,
  `didFail` and `didFailProvisionalNavigation` run a bounded (2-attempt)
  recovery. Visible tabs reload with their scroll offset stashed and restored
  after `didFinish`; the offscreen harvest webview is discarded and a fresh
  harvest generation started instead. `NSURLErrorCancelled` and
  `WebKitErrorDomain 102` are ignored — 102 is exactly what this app's own
  `decisionHandler(.cancel)` produces. Exhausting the budget on home (or on the
  harvest webview) fails the feed closed rather than leaving a blank page.
- **Handler lifetime.** `WKUserContentController` and `WKHTTPCookieStore` retain
  what you register with them, and `WebViewStore` retains the controller, so the
  nine message handlers and the cookie observer are registered through weak
  forwarding proxies (`WeakScriptMessageHandler` / `WeakCookieStoreObserver`)
  with paired teardown in `deinit`.

## Blocking happens in layers

Instagram is a React/Relay SPA that server-streams and client-fetches content,
so no single interception point is enough. Blocking is defense-in-depth:

1. **`WKNavigationDelegate` (`decidePolicyFor`)** — cancels full-page loads to
   blocked exact paths (`/reels`, `/explore`) **on Meta-family hosts only**.
2. **SPA route guards** — `history.pushState`/`replaceState` are hooked, plus a
   boot-time location guard, so client-side navigations to `/reels/`/`/explore/`
   are redirected to home (`WKNavigationDelegate` never sees these).
3. **Response rewrite (data layer)** — the home feed's GraphQL response is
   rewritten via **lazy getters** on the XHR's `responseText`/`response` (see
   `favorites-feed.md`), to strip reels/ads or splice favorites *before* Relay
   renders.
4. **DOM fallback (`MutationObserver` + `apply()`)** — `filterArticle`,
   `hideSponsoredAndReels`, `hideFeedNoise`, header/search fixes run on every
   mutation, catching anything the data layer missed (streamed/SSR content).

CSS injected at document start hides known chrome (e.g. the Explore nav link)
before first paint — cheaper and flash-free compared to post-render DOM removal.

## Native ↔ web bridge

**Web → native** via `window.webkit.messageHandlers.<name>.postMessage(...)`,
handled in `WebViewStore.userContentController(_:didReceive:)`:

| Handler | Payload → effect |
| --- | --- |
| `biNav` | Bool → tab-bar visibility and the source webview's outer bottom/indicator clearance (100 points while visible, zero while hidden). |
| `biAvatar` | String → profile avatar URL. |
| `biProfile` | String → detected own-profile href. |
| `biBg` | CSS color → that webview's cached Instagram base background. Immersive viewers do not overwrite this cache. |
| `biPresentation` | `{locked, immersive}` → atomically update reel scroll locking and the active safe-area override. Stories and confirmed reel viewers use black; closing restores the cached base color. |
| `biFavEdit` | → open the favorites editor sheet. |
| `biFavReady` | → favorites feed rendered; drop the launch splash; clear feed-stuck state. |
| `biFeedStuck` | → the feed is not trustworthy: either the watchdog (splice landed, feed never rendered) or the fail-closed path (`reportFeedDegraded()` — harvest edges never arrived / 0 edges). Native does one auto-recovery reload, then shows the retry screen (`FeedErrorView`). |
| `biLog` | String → `[BI-DEBUG]` logging channel. |

`ContentView` owns one non-interactive status-area painter above the `TabView`
(the tab container otherwise paints that region with its own black background). Each persistent
webview caches its base color and immersive state independently; only the active
webview can publish them to native chrome. Routes never make the safe area
immersive by themselves. The history hook records existing media geometry before
an SPA route change; `biPresentation` turns black only after a new Story/Reel
surface mounts or an existing element actually becomes fullscreen. The surface
reference keeps black stable through its close animation until it disappears.
This avoids predicting Instagram's intermediate navigation states, which
produces black-base-black safe-area flicker.

**Native → web** via `evaluateJavaScript` / `callAsyncJavaScript`:
`window.__biSetFavorites(...)`, `window.__biSetFavEdges(...)`,
`window.__biReapply()`, `window.__biNavigate(...)`, and the harvest extraction.

Native navigation requests go through one tracing wrapper. `[BI-nav]` records a
monotonic id/reason plus active tab, target, redacted route, loading state, and
scroll offset for each explicit load/reload and delegate lifecycle event. Each
injected document logs a `[boot]` id/frame and redacted route, and `didFinish`
prints a versioned `[BI-health]` probe. All diagnostics are console-only.

## Build & target

- **`ios/Lillygram.xcodeproj/project.pbxproj` is the source of truth.** It
  was hand-edited (deployment target **iOS 26.0**, `DEVELOPMENT_TEAM
  PD623TGVBL`, explicit file list). `xcodegen` is **not installed** — do **not**
  regenerate from `project.yml` (it would drop the hand edits and the iOS-26
  target). New Swift files must be added to the pbxproj manually.
- Bundle id `com.lillygram.app`, Swift 5, portrait only.
- Build (no signing, simulator):
  ```sh
  xcodebuild -project ios/Lillygram.xcodeproj -scheme Lillygram \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
  ```
- **No test target.** JS changes are validated by extracting the string
  (unescaping the doubled backslashes) and running `node --check`. `node --check`
  only proves it parses — it cannot catch a runtime abort during initialization,
  which silently costs the MutationObserver and the whole DOM layer. For that,
  eval the extracted script into a **jsdom** window from `beforeParse` (i.e.
  with `document.body === null`, matching `.atDocumentStart`) with
  `window.__biFavorites` / `__biFavoritesEnabled` and a `window.webkit
  .messageHandlers` shim, then assert initialization reached
  `observer.observe(document.body, ...)` and that mutations are delivered.
  Runtime behavior against the real Instagram is still only validated on
  device/simulator via the `[BI-DEBUG]` / `[BI-harvest]` logs.

## Conventions

- Match the surrounding Swift style; keep the injected JS ES5-safe-ish and
  defensive (`try/catch`, null checks) since it runs against a hostile,
  changing DOM.
- **Regex backslashes in `ContentFilter.swift` must be doubled** — the JS lives
  inside a Swift string, so a JS `\/` is written `\\/`, `\s` is `\\s`, etc.
- Debug logging is `[BI-DEBUG]`-prefixed via the `biLog` handler; harvest logs
  are native `print` with `[BI-harvest]` / `[BI-sync]`.
</content>
