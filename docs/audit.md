# Technical Audit

An objective assessment of how BetterInstagram is currently built vs. 2026
best practice, with honest verdicts. This is an evaluation, not a change log —
nothing here was implemented. Where a gap maps to an open item it links to
[known-issues.md](known-issues.md).

_Audited against the code as of this doc's creation. Re-audit when the WKWebView
layer, blocking approach, or favorites pipeline changes materially._

## Scorecard

| Area | Verdict | Gap impact |
| --- | --- | --- |
| Project structure / deps | **ALIGNED** | — |
| WKWebView configuration | **ALIGNED** | Low |
| Persistent-webview reuse | **PARTIAL** | Medium (memory) |
| Blocking mechanism (JS/CSS vs content rules) | **PARTIAL** | Medium (fragility, main-thread) |
| Script-injection timing / flash | **ALIGNED** | Low |
| Feed response-rewrite (favorites splice) | **MISALIGNED by nature** | High fragility (load-bearing; now via SSR `JSON.parse` splice — renders on device) |
| Reels blocking | **ALIGNED** | Low |
| DM sent-reel exception | **PARTIAL** | Medium (heuristic) |
| Account-only search | **MISALIGNED** | High (requirement unmet) |
| Resilience to IG DOM/API change | **MISALIGNED** | High (systemic) |
| Performance: warm-up / launch / flash | **PARTIAL** | Medium (UX) |
| Media / thumbnail quality | **ALIGNED** | Low |
| Session / auth | **ALIGNED** | Low |
| SwiftUI ↔ WKWebView integration | **ALIGNED** | Low |

**Docs vs code:** `docs/` matches the code. `ios/README.md` and
`ios/project.yml` are stale (old fetch-filter approach, iOS 17 vs the pbxproj's
iOS 26) — see [known-issues.md](known-issues.md).

---

## Inventory (what's actually there)

- **Structure:** single SwiftUI target, **zero third-party dependencies** (no
  SPM/CocoaPods); pure `SwiftUI` + `WebKit`. `pbxproj` hand-edited and
  authoritative (iOS 26); `xcodegen` not installed.
- **WKWebView config:** one `WKWebViewConfiguration` with
  `WKWebsiteDataStore.default()` (persistent, shared), one shared
  `WKUserContentController`, `allowsInlineMediaPlayback = true`,
  `mediaTypesRequiringUserActionForPlayback = []`, pinned mobile-Safari
  `customUserAgent`, `allowsBackForwardNavigationGestures = true`.
  **No `WKProcessPool`, no `WKContentRuleList`, no `URLCache` tuning, no
  `WKWebpagePreferences`.**
- **Webviews:** four created **eagerly at init** + a fifth hidden harvest
  webview created lazily; all persistent for process lifetime.
- **Blocking mechanics:** one JS userscript at `.atDocumentStart`; document-start
  CSS; `history.pushState/replaceState` hooks; boot-time location guard;
  `decidePolicyFor` cancel for `/reels`,`/explore`; **XHR response rewrite via
  lazy getters**; `MutationObserver` DOM fallback.
- **Session:** rides Instagram's own cookie session in the persistent data
  store; `sessionid` cookie observer for login state.
- **Launch:** all tabs load at init; home reloads once after favorites harvest;
  `SplashView` masks it.

---

## Evaluation (best practice + verdict per area)

### 1. Content-blocking mechanism — PARTIAL
- **Now:** 100% imperative JS/CSS + MutationObserver + response rewriting; no
  `WKContentRuleList`.
- **Best practice:** `WKContentRuleList` compiles to bytecode run in the
  **networking subsystem**, off the main/JS thread — the correct, fastest,
  flash-free tool for **static** blocking (URL patterns, `css-display-none` by
  selector), main-frame-scopable since WWDC22. But it is **declarative only** —
  it cannot parse GraphQL, dedupe edges, or run the favorites splice.
- **Verdict:** dynamic logic is correctly JS; the **static** hides (Explore
  link, known reel chrome, blocked routes) sit in JS/CSS where a content rule is
  more reliable/flash-free.
- **Impact:** modest — avoidable main-thread work + minor flicker risk.
- **Worth it?** Yes for the static subset — low effort, isolated. Not worth
  forcing dynamic logic into rules (impossible).

### 2. Script-injection timing / flash — ALIGNED
- **Now:** userscript + CSS at `.atDocumentStart`, `forMainFrameOnly:false`.
- **Best practice:** document-start injection pre-empts the page and applies CSS
  before first paint — the standard flash-free technique.
- **Worth it?** No change.

### 3. Feed response-rewrite (favorites splice) — MISALIGNED by nature, load-bearing
- **Now:** two splice points (see [favorites-feed.md](favorites-feed.md)). The
  **load-bearing one is the SSR splice**: a document-start `JSON.parse` hook that
  swaps favorites into the `feed__timeline` connection Instagram **server-streams
  into the page HTML** and renders the initial feed from. The older XHR lazy-getter
  splice remains for infinite-scroll pages. Favorites render on device.
- **Best practice:** there is **no blessed way** to rewrite a first-party SPA's
  own GraphQL/SSR responses — inherently reverse-engineering. Hooking the parse
  of the server-streamed data is the *correct* answer once you know Instagram
  renders the initial feed from SSR, not the XHR.
- **Verdict:** misaligned with "robust software" but intrinsic to the
  requirement, not a mistake; least-bad option for R1.
- **Impact:** high fragility; demonstrated regression class (reorder/dupe/non-post
  edges → spinner; and — the 2026-07-14 outage — Instagram silently moving the
  initial render from XHR to SSR, which the code had to follow). Both are now
  guarded (`sanitizeFavEdges` invariants; SSR splice).
- **Worth it?** No wholesale change exists; **harden** it (see Resilience) so it
  degrades gracefully rather than spinning.

### 4. Reels blocking — ALIGNED
- **Now:** defense-in-depth — native `decidePolicyFor`, SPA route guards,
  data-layer `product_type==='clips'` filter, DOM fallback.
- **Best practice:** layered blocking is correct for a SPA that surfaces content
  via route + data + DOM. Route blocks could optionally be content-rule `block`s.
- **Worth it?** Marginal; leave as is.

### 5. DM sent-reel exception — PARTIAL
- **Now:** detects the URL-less DM viewer via a **near-fullscreen `<video>`
  heuristic** (≥85% w / ≥60% h), then locks scroll/gestures.
- **Best practice:** structural heuristics beat exact class names for resilience,
  but a geometric heuristic is probabilistic — can mis-fire on layout changes or
  other fullscreen video.
- **Impact:** medium — a miss could leak reel chaining (violates R2) or lock
  scroll where it shouldn't.
- **Worth it?** Add a secondary signal + failure guard, not a rewrite.

### 6. Account-only search — MISALIGNED (requirement unmet)
- **Now:** `fixSearchPage()` only fixes **layout**; Explore routes are blocked
  but **search results are not filtered to accounts-only** — posts/hashtags/AI
  can appear.
- **Best practice:** filter search-results data/DOM to profiles only (keep
  `users`, drop posts/hashtag/place/AI).
- **Impact:** high — **R3 not satisfied.**
- **Worth it?** Yes — required by the contract; medium effort (mirror the
  feed-filter pattern on topsearch/Explore-search responses). Tracked in
  [known-issues.md](known-issues.md) #3.

### 7. Resilience to IG DOM/API change — MISALIGNED (biggest systemic risk)
- **Now:** hard-coded query friendly-names + `doc_id`s + `xdt_api__v1__*` keys +
  DOM selectors; **no version/feature detection, no failure telemetry, no
  graceful degradation** — a broken hook can blank/spin the feed.
- **Best practice:** Meta rotates `doc_id`s on a ~weeks cadence and renames XDT
  keys; resilient wrappers **feature-detect** (match structural signals like
  "key contains `feed__timeline`" — already done in places), **fail safe** (if
  the splice can't run, show the normal feed — never a permanent spinner), and
  **detect failure** (assert expected shape; log a miss).
- **Impact:** high — this is what turns an IG update into a broken app and what
  produced the current regression class.
- **Worth it?** **Yes — highest-value change.** Add invariant guards + safe
  fallbacks; prefer structural matches over exact `doc_id`s. Medium effort.

### 8. Performance: warm-up / launch / white flash — PARTIAL
- **Now:** persistent webviews (good) + `isOpaque=false` + `backgroundColor`
  (good). But **all four webviews created eagerly at launch** and a **one-time
  home reload** after harvest (masked by splash).
- **Best practice:** WKWebView creation is heavy — **limit live webviews and
  reuse**; white-flash fix via opaque/background is documented; **`WKProcessPool`
  is deprecated since iOS 15 and has no effect**, so *not* using it is correct.
- **Impact:** medium — 4 eager webviews = memory pressure; reload-flash is a UX
  seam (P8) papered over by the splash.
- **Worth it?** Partial: lazily create secondary tabs on first visit; remove the
  reload by letting first paint wait on cached favorites
  ([known-issues.md](known-issues.md) #4). Low–medium effort.

### 9. Media / thumbnail quality — ALIGNED
- **Now:** `fixDirectMediaQuality()` / `upgradeDirectPreviews()` swap DM
  share-card images to the largest `srcset` candidate (R4/P6).
- **Worth it?** Correct; no change.

### 10. Session / auth — ALIGNED
- **Now:** relies on Instagram's own cookie session in the persistent shared
  data store; `sessionid` cookie observer for login.
- **Best practice:** for a first-party wrapper this is exactly right — no token
  custody, login works across tabs via the shared data store (not
  `WKProcessPool`).
- **Worth it?** No change.

### 11. SwiftUI ↔ WKWebView integration — ALIGNED (with note)
- **Now:** `UIViewRepresentable` + a `WebViewStore` owning the webviews + a
  `WebBridge` `@Published` state — the standard pre-iOS-26 pattern.
- **2026 note:** iOS 26 ships a native SwiftUI `WebView` + `WebPage`, but it is
  higher-level and does **not** expose the deep hooks this app needs (custom
  `WKUserScript` timing, `WKScriptMessageHandler`, `decidePolicyFor`, response
  patching). **Staying on `WKWebView` is correct; do not migrate.**

---

## Bottom line

The app is well-built where the platform provides blessed tools (injection
timing, persistent webviews, shared-cookie session, no process pool, no
native-WebView migration). The real gaps, in priority order:

1. **Resilience / fail-safe layer** — highest leverage; make hooks degrade
   gracefully and never leave the feed spinning.
2. **Account-only search** — a requirement (R3) that is currently unmet.
3. **Static blocking → `WKContentRuleList`** — modest reliability/perf win, low
   effort, keep dynamic logic in JS.
4. **Launch memory + reload seam** — trim eager 4-webview creation and the
   post-harvest reload.

The favorites splice and reel-lock heuristics are **fragile by nature, not by
mistake** — harden and fail gracefully rather than rewrite. Explicitly **do not**
migrate to the iOS 26 native SwiftUI WebView.

## Sources

- WebKit — [Content Blockers: A First Look](https://webkit.org/blog/3476/content-blockers-first-look/)
- Apple — [WKContentRuleList](https://developer.apple.com/documentation/webkit/wkcontentrulelist) · [WKContentRuleListStore](https://developer.apple.com/documentation/webkit/wkcontentruleliststore)
- Apple — [WWDC22: What's new in WKWebView](https://developer.apple.com/videos/play/wwdc2022/10049/)
- Apple — [WKUserScriptInjectionTime](https://developer.apple.com/documentation/webkit/wkuserscriptinjectiontime)
- Apple — [WKProcessPool (deprecated iOS 15)](https://developer.apple.com/documentation/webkit/wkprocesspool)
- Embrace — [Why WKWebView is heavy / leak-prone](https://embrace.io/blog/wkwebview-memory-leaks/)
- AppMaster — [Optimizing WebView app performance](https://appmaster.io/blog/how-to-optimize-performance-for-webview-apps)
- [WebViewWarmUper](https://github.com/bernikovich/WebViewWarmUper) (warm-up/reuse pattern)
- Firefox-iOS — [document-start injection examples](https://gist.github.com/garvankeeley/49c48021c9a70e38cce0e403f8fdbc58)
- Scrapfly — [How to scrape Instagram (doc_id rotation, xdt keys)](https://scrapfly.io/blog/posts/how-to-scrape-instagram)
- [WWDC25: WebKit for SwiftUI](https://dev.to/arshtechpro/wwdc-2025-webkit-for-swiftui-2igc) · [AppCoda: SwiftUI WebView iOS 26](https://www.appcoda.com/swiftui-webview/)
- [Sarunw: WebView in SwiftUI](https://sarunw.com/posts/swiftui-webview/)
</content>
