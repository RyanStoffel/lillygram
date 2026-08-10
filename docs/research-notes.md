# Research Notes

External research backing the architecture and the performance/UX standards.

> **Citation status.** Live web search was rate-limited when this doc was first
> written, so community/blog claims are marked **_[verify]_** and get a live
> source link when search is available. Apple documentation URLs are canonical
> and stable. When backfilling, add a "Sources" list of the exact URLs used.

## 1. Script injection: `atDocumentStart` vs `atDocumentEnd`

- `WKUserScript(source:injectionTime:forMainFrameOnly:)` injects at either
  `.atDocumentStart` (before the page's own subresources/scripts run) or
  `.atDocumentEnd` (after the DOM is built, before subresources finish).
  — Apple: `WKUserScript`, `WKUserScriptInjectionTime`,
  `WKUserContentController`.
- **Rule of thumb we follow:** anything that must *pre-empt* the page — patching
  `XMLHttpRequest`/`fetch`, hooking `history.pushState`, a location guard, or
  CSS that must hide chrome before first paint — **must** be `atDocumentStart`.
  Purely reactive DOM cleanup can be `atDocumentEnd` or a `MutationObserver`.
  Lillygram injects at document start and does reactive work via an
  observer. _[verify with a current write-up]_

## 2. Declarative blocking: `WKContentRuleList`

- `WKContentRuleListStore.compileContentRuleList(...)` compiles a Safari-content-
  blocker-style JSON rule set (WebKit's own matching engine) supporting
  `block`, `block-cookies`, `css-display-none` (hide by selector), etc.
  — Apple: `WKContentRuleList`, `WKContentRuleListStore`; Safari "Creating a
  content blocker".
- **Trade-off vs. our JS approach.** Content rules are fast (native matcher, off
  the main JS thread) and flash-free for *static* URL/selector blocking, but they
  are **declarative only** — they can't parse a GraphQL response, dedupe feed
  edges, or run the favorites splice. Lillygram's core logic (feed rewrite,
  favorites splice, DM reel lock) is inherently imperative, so it lives in the
  userscript. **Opportunity:** move the *static* hides (Explore link, known reel
  chrome) into a `WKContentRuleList` for guaranteed flash-free blocking, keeping
  JS for the dynamic logic. _[verify current best practice]_

## 3. Performance: warm-up, process reuse, preloading

- Keeping `WKWebView` instances **alive and warm** (rather than recreating per
  screen) avoids process spin-up and re-parse costs — the dominant technique for
  "instant" tab switches. Lillygram keeps all four tab webviews
  persistent. _[verify — WWDC "What's new in WebKit"/community write-ups]_
- **Process/data-store sharing.** A shared `WKWebsiteDataStore` shares
  cookies/cache/session across webviews (needed for one login across tabs).
  Note: `WKProcessPool` is effectively deprecated/ignored on modern iOS —
  process sharing is managed by WebKit and the shared data store. _[verify
  current guidance for the deployment target]_
- **Preloading.** Load secondary tabs right after auth so they're warm before
  first tap (Lillygram reloads secondary tabs on login). _[verify]_

## 4. Avoiding white flashes & blurry media

- **White/blank flash** on load/navigation typically comes from the webview's
  default opaque white background showing before content paints. Mitigations:
  `isOpaque = false` + a `backgroundColor` matched to the page, and injecting
  page-background CSS at document start. Lillygram sets the background from
  the reported page color (black on stories). — Apple: `WKWebView` /
  `UIView.isOpaque`. _[verify community write-ups]_
- **Blurry previews** on DM share cards come from Instagram serving a tiny image
  scaled up; the fix is to select the largest `srcset`/candidate. Lillygram
  does this in `fixDirectMediaQuality()`. (Standard responsive-images behavior;
  MDN `srcset`.)

## 5. Native feel: scroll, gestures, safe area

- Use a **native** tab bar (SwiftUI `TabView`) rather than the web nav so the
  chrome is genuinely native; manage safe areas with
  `scrollView.contentInsetAdjustmentBehavior` and `ignoresSafeArea` rather than
  fighting the web layout. — Apple: `WKWebView`, `UIScrollView`,
  `contentInsetAdjustmentBehavior`.
- `allowsBackForwardNavigationGestures` gives native edge-swipe back. For the DM
  reel lock we disable scrolling **surgically** (only the reel container) to keep
  native scrolling everywhere else.
- Keep the detected web-page background separate from temporary presentation
  chrome. Lillygram caches Instagram's base color per webview and uses one
  root safe-area painter; confirmed Story/Reel presentation overrides that
  painter to black without mutating the webview's base color. Do not infer that
  override from a route or navigation request: Instagram's intermediate states
  can visibly undo and reapply the color. Snapshot media geometry before SPA
  navigation, activate only when a real viewer surface mounts/becomes fullscreen,
  and hold the surface reference through its close animation.

## 6. How social-web-wrapper filters break on DOM updates

- Any userscript/content-blocker over a first-party SPA is coupled to that app's
  private internals (class names, route shapes, GraphQL query names, rotating
  `doc_id`s). Instagram/Facebook rotate `doc_id`s on a ~weeks cadence and rename
  `xdt_api__v1__*` keys, so selector/query-based tools need periodic re-capture.
  This is why Lillygram keeps a [selector reference table](blocking-and-selectors.md)
  and prefers structural signals (e.g. "key contains `feed__timeline`",
  "near-fullscreen `<video>`") over brittle exact class names where possible.
  — Reverse-engineering references (instaloader, instagram-private-api) and
  scraping write-ups document the `doc_id` rotation + `xdt_api__v1__*` shapes.
   _[add specific source URLs on backfill]_

## 7. Reliable first-tap handling for lazy delegated controls

- WebKit's `touch-action: manipulation` removes the historical double-tap zoom
  delay, but it cannot associate a tapped visual layer with a sibling link or
  bypass application code that consumes an already-delivered click.
- If a real permalink exists, a capture-phase listener can resolve it before
  Instagram's delegated bubble handler and use `location.assign()`; unlike
  `history.pushState()`, that initiates a real navigation.
- The confirmed DM reel card is different: before opening it has no permalink
  (`reelAnchors=0`). Its first trusted touch lazily upgrades the visual card.
  Lillygram therefore lets that touch finish, re-hit-tests the same point
  after 120 ms, and invokes the current upgraded element. Retrying the stale
  element or an assumed anchor does not work.
- The retry is limited to stationary taps on large media-card surfaces and is
  skipped if the route changed or the URL-less overlay already opened. This is
  the important safety boundary; applying automatic retries to arbitrary DM
  controls would create accidental activations.

## Sources

_To be completed when web search is available. Canonical Apple documentation
referenced above:_
- Apple Developer: `WKUserScript`, `WKUserScriptInjectionTime`,
  `WKUserContentController`, `WKContentRuleList`, `WKContentRuleListStore`,
  `WKWebView`, `WKWebViewConfiguration`, `WKWebsiteDataStore`.
- MDN: responsive images (`srcset`).
- WebKit: [More Responsive Tapping on iOS](https://webkit.org/blog/5610/more-responsive-tapping-on-ios/).
- Apple: [Handling Events](https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/SafariWebContent/HandlingEvents/HandlingEvents.html).
- MDN: [`Location.assign()`](https://developer.mozilla.org/en-US/docs/Web/API/Location/assign),
  [`History.pushState()`](https://developer.mozilla.org/en-US/docs/Web/API/History/pushState),
  and [`Event.composedPath()`](https://developer.mozilla.org/en-US/docs/Web/API/Event/composedPath).
- _[verify]_ WWDC WebKit sessions on warm-up/performance; community write-ups on
  eliminating white flash and warming WKWebView; IG `doc_id` rotation references.
</content>
