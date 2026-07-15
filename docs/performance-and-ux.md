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
- **Persistent, pre-created webviews.** `WebViewStore` builds all four tab
  webviews once and keeps them warm for the process lifetime; tab switches never
  reload. _[cite pending]_
- **Shared data store + content controller.** One `WKWebsiteDataStore.default()`
  and one `WKUserContentController` across tabs → shared cookies/session and a
  single script install; secondary tabs can preload right after login. _[cite pending]_
- **Opaque backgrounds matched to page.** `isOpaque = false` +
  `backgroundColor` set from the reported page background (`biBg`, black on
  `/stories/`) to avoid white flashes during load/navigation. _[cite pending]_
- **Two splashes to mask feed-assembly work.** Both fire *instantly* (identity
  insertion, fade-out only) and drop on `biFavReady` (favorites rendered) with a
  ~20 s safety fallback so neither can stick. `LaunchSplashView` is the branded
  cold-start screen (Instagram-style wordmark + "from Meta") covering the initial
  harvest + home reload. `ResaveSplashView` (star + "Updating your favorites…")
  covers the re-harvest + reload after the user re-saves favorites, so the swap
  never happens on-screen. `ContentView.activeSplash` picks between them:
  launch before the feed has ever been ready, resave for any later gap (only
  produced by `applyFavoritesSelection`).

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
  truly native; `contentInsetAdjustmentBehavior = .never` + `ignoresSafeArea`
  for correct safe-area handling.
- **Gesture fidelity.** `allowsBackForwardNavigationGestures = true`; the DM
  reel lock disables scroll surgically (only the reel container) so the rest of
  the app keeps native scrolling.
- **No debug leakage in UI.** `[BI-DEBUG]` logging is console-only; no on-screen
  markers.

## Anti-goals / traps

- Do **not** fix jank by adding delays that make launch feel slow (P1 vs P8
  tension): prefer masking with the splash + warm webviews over artificial waits.
- Do **not** solve flash-of-content with post-render removal — that *is* the
  flash. Move the block earlier (CSS at document-start, or the data layer).
- Do **not** let a blocking rule leave an empty container (fails P4/P7) — hide
  the whole clickable/section wrapper, not just the inner element.
</content>
