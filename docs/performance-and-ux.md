# Performance & UX Standards

This doc turns **R4 ("polished, fast, native-feeling")** into concrete,
measurable standards and the implementation techniques to hit them. R4 is
"met" when these standards are met. Sources are in
[research-notes.md](research-notes.md).

> Citation status: initial version reflects established WKWebView guidance
> (Apple docs / WWDC) and the techniques already in this codebase. Items marked
> _[cite pending]_ get a live source link when web search is available.

## Measurable standards

| # | Standard | Target | How to check |
| --- | --- | --- | --- |
| P1 | Cold launch → first tab interactive | < 1.5 s to a usable home shell (stories/header), feed content ≤ ~1 s after | Stopwatch on a cold launch; the launch splash must not be the *last* thing on screen for longer than the harvest+render. |
| P2 | Tab switch | Instant (no reload, no white flash) | Switching tabs shows already-warm webviews; no spinner appears on switch. |
| P3 | Flash-of-blocked-content | **Zero** | No reel/ad/non-favorite ever visibly renders then disappears. |
| P4 | Layout shift from removal | **Zero** | No gaps, empty containers, or jumps where an element was stripped. |
| P5 | Feed scroll | ~60 fps, no stutter | Scroll the favorites feed; injected JS must not jank the main thread. |
| P6 | DM media quality | Full-res, never upscaled-blurry | A reel/post shared in DMs renders at full quality. |
| P7 | No visible hacks | Nothing looks broken | No dead buttons, half-removed UI, "← Favorites" headers, or debug artifacts. |
| P8 | White/blank flashes | **Zero** | No white flash on launch, navigation, or story open/close. |

## Techniques

### Launch & warmth (P1, P2, P8)
- **Persistent webviews, all preloaded during the launch splash (2026-07-21).**
  `WebViewStore` still builds the home webview eagerly in `init()`, but
  `ContentView.preloadSecondaryTabs()` now also immediately triggers creation
  of search/direct/profile right on appear, instead of waiting for each tab's
  first visit — using the launch splash's own dead time (already covering the
  favorites harvest) to hide the extra work, so there's no visible load delay
  the first time a user switches tabs. `store.webView(for:)` still does the
  actual creation (`ensureWebView`), and `createdTabs` is marked for all four
  up front so `webContent(for:)` never shows the loading placeholder in
  practice. Once created, tab switches never reload — same warm-tab guarantee
  as before, just front-loaded. _[cite pending]_
- **Shared data store + content controller.** One `WKWebsiteDataStore.default()`
  and one `WKUserContentController` across tabs → shared cookies/session and a
  single script install; secondary tabs can preload right after login. _[cite pending]_
- **Separate base and immersive backgrounds.** `isOpaque = false` + each
  webview's Instagram-reported base color (`biBg`) avoids white flashes without
  turning Direct conversations black. One non-interactive native painter above
  the `TabView` owns the status-bar safe area, avoiding the tab container's
  default black fill. `biPresentation` atomically applies a temporary black
  override only for Stories and confirmed reel viewers, then restores the cached
  base color on close. Routes and navigation requests do not speculatively
  change color: the userscript snapshots pre-route media geometry and publishes
  immersive state only when a new viewer surface mounts or an existing element
  becomes fullscreen — except that story and reel-permalink routes front-run
  geometry: `isImmersiveSurface()` short-circuits true on those paths so the
  synchronous `onRouteChange`→`updateScrollLock`→`postPresentation` pass flips
  the safe area to black the instant the URL changes, before geometry confirms
  (kills the page-color flash at viewer open). It holds that state through the
  close animation until the surface disappears. This avoids Instagram's intermediate navigation states,
  which caused black-base-black flicker. Inactive preloaded tabs cannot overwrite
  active chrome, and all safe-area changes disable animation. _[cite pending]_
- **Two splashes to mask feed-assembly work.** Both fire *instantly* (identity
  insertion, fade-out only) and drop on `biFavReady` (favorites rendered) with a
  ~20 s safety fallback so neither can stick. `LaunchSplashView` is the branded
  cold-start screen (Lillygram icon + attribution) covering the initial harvest
  and home reload. `ResaveSplashView` uses the same identity with an "Updating
  your favorites…" status while re-harvest runs, so the swap never happens
  on-screen. `ContentView.activeSplash` picks between them:
  launch before the feed has ever been ready, resave for any later gap. Pull to
  refresh uses an explicit phase machine: `pullCommitted` preserves the current
  page with only the native refresh spinner for 0.4 s; `rebuilding` then starts
  the real re-harvest/load and shows the launch-style splash.

### Flash-free blocking (P3, P4)
- **Document-start injection.** The userscript and its CSS load at
  `.atDocumentStart`, before Instagram's code, so blocked chrome is hidden
  before first paint. _[cite pending]_
- **CSS-first hiding over post-render DOM deletion.** Prefer `display:none` on a
  stable selector (flash-free, no reflow cost) to removing nodes after they
  render. Removing nodes should collapse cleanly (no leftover spacer).
- **Data-layer rewrite before render.** Stripping reels/ads and splicing
  favorites happens on the feed *response* (lazy getters) so React never renders
  the blocked items — no flash, no post-hoc removal. See `favorites-feed.md`.
- **DOM `MutationObserver` only as a fallback**, for streamed/SSR content the
  data layer can't catch — kept targeted to avoid main-thread churn (P5).

### Media quality (P6)
- **`srcset` upgrade.** `fixDirectMediaQuality()` / `upgradeDirectPreviews()`
  swap DM share-card `<img>`s to their largest `srcset` candidate instead of the
  tiny upscaled default.

### Native feel (P5, P7, P8)
- **Real native tab bar** (`TabView`) rather than a web nav, so the bottom bar is
  truly native. The webview ignores the bottom safe area and receives 100 points
  of outer scroll clearance only while `biNav` says the native tab bar is
  visible; hidden-bar routes (including DM threads) respect the safe area and
  receive zero outer clearance.
- **Gesture fidelity.** `allowsBackForwardNavigationGestures = true`; the DM
  reel lock disables scroll surgically (only the reel container) so the rest of
  the app keeps native scrolling.
- **Single-tap DM media.** Instagram's URL-less shared-reel card internally
  requires arm-then-activate taps. The userscript retries the upgraded element
  after the first stationary media-card touch so one physical tap opens it;
  scrolling and non-media controls are excluded.
- **Comments presentation.** Opening a post's comments hides the native tab bar
  for both dialog and mobile full-page variants. Detection is throttled with the
  normal DOM fallback pass and uses a short close confirmation window so React
  rerenders cannot flicker the native bar. The full-page back arrow cancels its
  link navigation during capture while allowing Instagram's close handler to
  continue. Closing comments restores the tab bar with the native toolbar
  transition.
- **No debug leakage in UI.** `[BI-DEBUG]` logging is console-only; no on-screen
  markers.

### Current roadmap

1. **Native accessibility and motion:** explicit tab labels, meaningful loading
   and error semantics, real-Favorites disclosure, and Reduce Motion support.
2. **Adaptive shell geometry:** visibility-aware clearance is implemented;
   replace the current 100-point visible-bar constant with measured native tab
   bar geometry if device logs show it is inaccurate.
3. **Measured launch polish:** add debug signposts and profile cold launch, warm
   tab switches, memory, and feed scrolling before changing preload behavior.
4. **Visible degraded states:** surface persistent favorites-sync degradation
   without ever falling back to algorithmic feed content.
5. **Targeted DOM performance:** profile first, then split broad fallback work by
   route while retaining immediate feed, search, comments, and DM-reel defenses.

## Anti-goals / traps

- Do **not** fix jank by adding delays that make launch feel slow (P1 vs P8
  tension): prefer masking with the splash + warm webviews over artificial waits.
- Do **not** solve flash-of-content with post-render removal — that *is* the
  flash. Move the block earlier (CSS at document-start, or the data layer).
- Do **not** let a blocking rule leave an empty container (fails P4/P7) — hide
  the whole clickable/section wrapper, not just the inner element.
</content>
