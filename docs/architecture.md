# Architecture

## One-paragraph model

BetterInstagram is a thin SwiftUI shell around **four persistent `WKWebView`s**
(one per tab: home, search, direct, profile) that all load the real
`instagram.com` and **share a single `WKUserContentController`**. That controller
injects one large JavaScript userscript at **document start** into every page.
The userscript does all the "product": blocking reels/explore, locking DM reels,
filtering the feed, fixing the header, and reporting page state back to Swift via
message handlers. A **fifth hidden webview** exists only to harvest the favorites
feed (see `favorites-feed.md`). Native and web talk over `postMessage` handlers
and `evaluateJavaScript` / `callAsyncJavaScript`.

## Files (all under `ios/BetterInstagram/`)

| File | Role |
| --- | --- |
| `BetterInstagramApp.swift` | `@main` App; shows `ContentView`. |
| `ContentView.swift` | Root `TabView` (home/search/direct/profile), onboarding cover, favorites-editor sheet, and the two splashes (`LaunchSplashView` branded cold-start, `ResaveSplashView` on favorites re-save) chosen by `activeSplash`. |
| `WebViewStore.swift` | Owns the 4 tab webviews + the hidden harvest webview; the shared `WKUserContentController`; login detection; favorites sync/harvest; all message-handler callbacks. The native brain. |
| `ContentFilter.swift` | **The injected userscript**, as a Swift multiline string (`ContentFilter.script`), plus `harvestScript` and (unused) `harvestCollectorScript`. All web-side behavior lives here. |
| `WebBridge.swift` | `NavTarget` enum (`home/search/direct/profile`) + `@Published` UI state (`isNavVisible`, `avatarURL`, `pageBackground`, `favoritesEditRequests`). |
| `FavoritesStore.swift` | `UserDefaults`-backed favorites selection + onboarding-complete flag; `isFilterEnabled`. |
| `OnboardingView.swift` | `FavoritesPickerView` — post-login onboarding + the star-tab editor; lists the user's following + global search. |
| `WKWebView+NoAccessory.swift` | Removes the keyboard input-accessory bar. |
| `FloatingNavBar.swift` | **Excluded from the target** (dead; `ContentView` uses a native `TabView`). |

## The WKWebView layer

- **Persistence.** `WebViewStore` creates the four webviews once and keeps them
  alive for the process lifetime; switching tabs shows an already-warm webview
  rather than reloading. This is central to R4 (fast, native-feeling).
- **Shared config.** One `WKWebViewConfiguration` with
  `WKWebsiteDataStore.default()` (so cookies/login are shared across tabs) and
  the shared `userContentController`.
- **Injection.** `installUserScripts()` adds two `WKUserScript`s at
  `.atDocumentStart`, `forMainFrameOnly: false`:
  1. a tiny preamble that seeds `window.__biFavorites` / `window.__biFavoritesEnabled`;
  2. `ContentFilter.script` — the userscript.
  Document-start injection is required so hooks (XHR/fetch, `history.pushState`,
  location guard) are installed **before** Instagram's own code runs.
- **User agent** is pinned to a mobile Safari UA so Instagram serves the mobile
  web experience.
- **Login detection.** `WebViewStore` observes the cookie store; presence of the
  `sessionid` cookie flips `isLoggedIn`. The native tab bar is hidden while
  logged out.

## Blocking happens in layers

Instagram is a React/Relay SPA that server-streams and client-fetches content,
so no single interception point is enough. Blocking is defense-in-depth:

1. **`WKNavigationDelegate` (`decidePolicyFor`)** — cancels full-page loads to
   blocked exact paths (`/reels`, `/explore`).
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
| `biNav` | Bool → tab-bar visibility. |
| `biAvatar` | String → profile avatar URL. |
| `biProfile` | String → detected own-profile href. |
| `biBg` | CSS color → `bridge.pageBackground` (e.g. black on `/stories/`). |
| `biScroll` | Bool → enable/disable the webview's scroll (reel lock). |
| `biFavEdit` | → open the favorites editor sheet. |
| `biFavReady` | → favorites feed rendered; drop the launch splash. |
| `biLog` | String → `[BI-DEBUG]` logging channel. |

**Native → web** via `evaluateJavaScript` / `callAsyncJavaScript`:
`window.__biSetFavorites(...)`, `window.__biSetFavEdges(...)`,
`window.__biReapply()`, `window.__biNavigate(...)`, and the harvest extraction.

## Build & target

- **`ios/BetterInstagram.xcodeproj/project.pbxproj` is the source of truth.** It
  was hand-edited (deployment target **iOS 26.0**, `DEVELOPMENT_TEAM
  9D3GQSX699`, explicit file list). `xcodegen` is **not installed** — do **not**
  regenerate from `project.yml` (it would drop the hand edits and the iOS-26
  target). New Swift files must be added to the pbxproj manually.
- Bundle id `com.betterinstagram.app`, Swift 5, portrait only.
- Build (no signing, simulator):
  ```sh
  xcodebuild -project ios/BetterInstagram.xcodeproj -scheme BetterInstagram \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
  ```
- **No test target.** JS changes are validated by extracting the string and
  running `node --check`; runtime behavior is validated on device/simulator via
  the `[BI-DEBUG]` / `[BI-harvest]` logs.

## Conventions

- Match the surrounding Swift style; keep the injected JS ES5-safe-ish and
  defensive (`try/catch`, null checks) since it runs against a hostile,
  changing DOM.
- **Regex backslashes in `ContentFilter.swift` must be doubled** — the JS lives
  inside a Swift string, so a JS `\/` is written `\\/`, `\s` is `\\s`, etc.
- Debug logging is `[BI-DEBUG]`-prefixed via the `biLog` handler; harvest logs
  are native `print` with `[BI-harvest]` / `[BI-sync]`.
</content>
