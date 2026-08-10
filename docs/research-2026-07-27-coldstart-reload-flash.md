# Cold-start reload flash — still reproduces every launch (2026-07-27)

**Status: diagnosis below, fix implemented same day.** This doc was originally
research-only (no source change). The "Recommended fix" section has since been
implemented in `ContentFilter.swift` / `WebViewStore.swift` exactly as
described (both halves); `tools/check.sh` and a simulator build both pass. It
has **not** been confirmed on a physical device yet — do that before marking
`known-issues.md` §4 fully resolved. Diagnoses why the fix in `7b4e3e1`
("re-arm `favoritesFeedReady = false` at the moment the reload is scheduled",
documented in `known-issues.md` §4 follow-up) did not stop the native-chrome
flash on a cold launch, despite the diff actually matching what the
commit/doc claims (verified via `git show 7b4e3e1` / `973fe8a` — unlike the
`ce2d8eb`/`1f5c977` no-op commits `known-issues.md` §0a already flags, that
fix really landed; it just didn't close the whole gap).

## Verdict

**Two real, code-verified gaps, not one.** The documented fix only closes the
*scheduling* race (make sure nothing reloads while `favoritesFeedReady` is
stale-true). It does not close the *signal* race: `biFavReady` — the only
thing that ever sets `favoritesFeedReady = true` — proves the favorites
**data** was spliced into a parsed response, not that the page has **visually**
applied its own filtering yet. Nothing in the pipeline waits for the
reloaded page's first DOM-filter pass before telling native it's safe to drop
the splash. That gap exists on every load (including the very first one) but
is masked on the very first cold paint by the splash's own fade timing; on the
post-harvest reload it is not masked, because the reload additionally re-arms
`favoritesFeedReady` on a **fixed 300 ms timer that starts *after* the
pre-reload page has already been unblocked**, widening the exact window the
fix was trying to close.

Confidence: **high** on both mechanisms being real (verified via direct code
reading and line citations below); **not yet device-confirmed** which one
dominates, or whether they compound. See "What would prove which" at the end.

## Root cause 1 (primary): `biFavReady` means "data spliced," not "page styled" — high confidence, structural

- `favoritesFeedReady` is set `true` **only** from the `biFavReady` message
  handler, unconditionally, with no other check:
  `WebViewStore.swift:1607-1609`.
- `ContentView.swift`'s `activeSplash` (`ContentView.swift:152-162`) drops the
  splash the instant `favoritesFeedReady` flips true, then fades it out over
  0.35 s (`ContentView.swift:113`, `splashTransition` at `:139-146` — insertion
  is `.identity` but **removal is `.opacity.combined(with: .scale)`**, i.e. the
  underlying `WKWebView` is genuinely visible, blended in, throughout that
  350 ms).
- `biFavReady` is posted from three call sites in `ContentFilter.swift`, all
  gated only on "have we posted it once for this document" — never on "has
  this document actually run its own DOM-filter pass":
  - `installSSRFeedSplice()`'s `JSON.parse` hook, `ContentFilter.swift:590-599`
    — fires the instant the browser executes whatever inline `<script
    type="application/json" data-sjs>` block contains the streamed
    `feed__timeline` connection. This runs **during HTML parsing**, driven
    entirely by wherever Instagram happens to place that data block in the
    stream — there is no ordering relationship to the rest of this file's own
    setup.
  - `rewriteFeedText()`'s native-favorites-mode branch, `:691-693`.
  - `rewriteFeedText()`'s successful-splice branch, `:707-709`.
- Meanwhile, the thing that actually makes the page look filtered —
  `ensureStyleInjected()` (appends the `<style id="__bi_filter_style">`
  element that hides `a[href="/reels/"]`, `a[href="/explore/"]`, `svg[aria-label="Reels"]`,
  sets the dark/light background) and `fixHomeHeader()` (centers the
  Instagram wordmark, hides the stray caret, adds the favorites star —
  literally the visual difference between "Instagram's raw nav" and this
  app's nav) — **only ever run inside `apply()`** (`ContentFilter.swift:2599`,
  `run('style', ensureStyleInjected)` at `:2614`; `fixHomeHeader` is also only
  called from `apply()`, further down the same function).
- `apply()` itself is not called until `start()`'s `document.body` check
  passes (`ContentFilter.swift:2805-2818`):
  ```js
  function start() {
    if (document.body) {
      observer.observe(document.body, {...});
      apply();
    } else {
      requestAnimationFrame(start);
    }
  }
  start();
  ```
  At `.atDocumentStart` injection time `document.body` is guaranteed `null`
  (this is exactly the precondition `tools/check.sh`'s jsdom gate asserts), so
  the **first** `apply()` — the first time the CSS actually gets appended to
  `<head>` and the header actually gets restyled — is deferred to at least the
  next `requestAnimationFrame` after `<body>` exists. That is a completely
  separate, uncoordinated timer from whichever `<script data-sjs>` block trips
  the `JSON.parse` hook above.
- Net effect: nothing in this file (or in `WebViewStore.swift`'s `biFavReady`
  handler) ever asks "has `apply()` run at least once on *this* document" before
  telling native it's safe to reveal the page. `architecture.md`'s claim that
  the CSS hides apply "before first paint" is the aspirational design intent,
  not what the code actually enforces — the `<style>` element is *defined* at
  document start but not *appended to the DOM* until first `apply()`, and
  nothing pins `apply()` ahead of `biFavReady`.

This is a **structural** gap present on every page load, not just the reload.
It best explains why the flash is deterministic ("every single time") rather
than intermittent: it isn't a rare network-timing coincidence, it's a missing
ordering guarantee that's present in the code on every load. The reason the
very first cold paint (page load #1, behind `LaunchSplashView`) doesn't
visibly flash the same way is very likely the 350 ms fade happening to give
`apply()` (typically sub-100 ms once `document.body` exists) enough of a head
start that the DOM is already styled by the time the fade makes it visible —
not that the race doesn't exist there too.

## Root cause 2 (contributing): `deliverFavEdges()` reaches the pre-reload page before the re-arm, and the re-arm's own reload is needlessly delayed — high confidence, code-verified

`finishHarvest()` (`WebViewStore.swift:909-969`):

```
932   cachedFavEdgesJSON = json
933   deliverFavEdges()                    // <- pushes fresh edges to the
                                            //    STILL-VISIBLE pre-reload home
                                            //    page, unblocking its held
                                            //    feed request (see below)
938   installUserScripts()
...
961               favoritesFeedReady = false     // <- re-arm (this is 7b4e3e1's fix)
962               DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ... }
965                   self.reload(home, reason: ...)
```

`deliverFavEdges()` (`:997`) calls `window.__biSetFavEdges` on **every** live
webview, home included, via `callAsyncJavaScript` — asynchronous, no return
value awaited. On the pre-reload home page, `__biSetFavEdges`
(`ContentFilter.swift:958-980`) resolves `favEdgesResolve`, which is what
`installXHRFilter`'s held `variant=home` request (`ContentFilter.swift`
`prefetchFavoriteEdges()` / the `send` override around line 1030-1050) was
waiting on. That releases the **real network request** for the home feed on
that page, whose response — once it actually completes and gets read — runs
through the same `rewriteFeedText()` splice path that posts `biFavReady`
(`ContentFilter.swift:707-709`) if `window.__biFavReadyPosted` on that page
hasn't already latched true.

The re-arm at line 961 runs synchronously right after this, so in Swift terms
"false" is set before any of that page's JS has had a chance to run — but the
JS itself is asynchronous IPC plus a real network round trip, so it is **not**
bounded by that ordering. Two concrete windows follow directly from this:

- **True first-ever launch (no disk cache yet), or any launch where the
  pre-reload page's SSR splice didn't already post `biFavReady`.** The now
  freshly-unblocked home XHR can complete and splice successfully at any
  point after `deliverFavEdges()` — including inside the 300 ms gap between
  the re-arm and the scheduled `reload()`, or even fractionally after
  `reload()` fires if the response was already in flight before navigation
  tore the old document down. Either way `favoritesFeedReady` flips true from
  a page that is about to be discarded, not from the reloaded page.
- **The normal warm-cache case** (disk-preloaded edges present, which is the
  every-day state after the first run): the pre-reload page's SSR splice
  already posted `biFavReady` once at its own document-start, so
  `window.__biFavReadyPosted` is already `true` on that page and this specific
  re-trigger is guarded off. But `deliverFavEdges()` still runs `scheduleApply()`
  (`ContentFilter.swift:972`) on the **fully visible, not-yet-re-armed**
  pre-reload page — a real, uncovered DOM-filter pass happens on-screen at an
  arbitrary moment between `deliverFavEdges()` and the re-arm one line later,
  purely because the fix re-arms `favoritesFeedReady` *after* delivering
  edges instead of before/instead-of.

Separately, the reload's own **fixed 0.3 s delay** (`WebViewStore.swift:962`,
unchanged since before `7b4e3e1` — that commit only added the re-arm line
immediately above it, per `git show 7b4e3e1`) has no load-bearing reason tied
to the splash: the splash is already back up as soon as `favoritesFeedReady`
flips false, so nothing requires waiting 300 ms before actually navigating.
That delay only widens the window described above without buying anything for
the splash's own coverage.

## Ruled out

- **A second, independent reload source firing ~2 s after first paint.**
  Checked `webViewWebContentProcessDidTerminate` / `didFail` /
  `didFailProvisionalNavigation` recovery (`recoverTab`, `recoverHarvestWebView`)
  — these are bounded, error-triggered, not something that fires
  deterministically on a clean cold launch. `resetAccountDerivedState()` only
  runs on an account switch/logout. `armFeedWatchdog()`
  (`ContentFilter.swift:2377-2389`) uses a 9000 ms timer, not ~2 s, and only
  fires when the feed genuinely never rendered a favorite — inconsistent with
  the reported "reappears looking normal" outcome. The once-per-launch launch
  sync (`WebViewStore.swift` `didFinish`, `!didRunLaunchSync` branch) can
  trigger a second `harvestFavorites()` if it wrote changes, but
  `didReloadHomeForFavorites` is already `true` by then, so `finishHarvest`'s
  reload branch is skipped for that second harvest — it cannot be a second
  reload source under normal operation.
- **The documented fix not actually landing (the `ce2d8eb`/`1f5c977` pattern).**
  Checked directly: `git show 7b4e3e1 -- ios/BetterInstagram/WebViewStore.swift`
  shows the `favoritesFeedReady = false` line was genuinely added exactly
  where the commit message and `known-issues.md` say, and `973fe8a` later
  added a `generation == self.harvestGeneration` guard around the same reload
  closure (hardening, not a revert). The current file on disk matches both
  diffs. This is not a repeat of the earlier fake-fix pattern.

## What would prove which (needs device confirmation)

Both mechanisms are real in the code; device logs would show which one is
actually responsible for the visible flash (they are not mutually exclusive):

- Add a temporary timestamp comparison between the `[favsplice] SSR feed
  splice armed` / `spliced favorites into SSR feed data` log lines and the
  `[apply-perf]` or a one-off `[apply] first pass done` log on the *reloaded*
  document only — if `biFavReady` logs before the first `apply()` completes on
  that document, root cause 1 is confirmed directly.
  `armFeedWatchdog`'s existing `[watchdog]`/`[feed]` logs already carry a
  `documentID`; correlate against that.
  - **Note for future dated entries in this section:** if a later pass adds
    this logging, put it here as a dated update per this doc's own convention
    rather than opening a new file, to keep `docs/` lean.
- Watch whether `[favsplice] swapped favorites into home response` /
  `[favsplice] SSR feed splice armed` logs a **second** time, on the
  **pre-reload** navigation id, between `[BI-harvest] ... completed` and the
  `post-harvest-generation-N` reload's own `[BI-nav] id=... event=didStart` —
  if so, root cause 2 is firing.

## Recommended fix

Both are worth doing; together they close the gap instead of narrowing it.

1. **Decouple "data ready" from "page ready" (closes root cause 1, the
   deterministic one).** In `ContentFilter.swift`, don't let the three
   `biFavReady` call sites post directly. Instead have them set a
   document-scoped flag (e.g. `window.__biFavDataReady = true`) and have the
   **tail of `apply()`** (after `run('style', ensureStyleInjected)` and
   `run('home-header', fixHomeHeader)` have executed at least once) check
   `if (window.__biFavDataReady && !window.__biFavReadyPosted) { postBiFavReady(); }`.
   This guarantees `favoritesFeedReady` can only ever flip true on the native
   side after the *same document* has actually appended its hide-CSS and
   restyled the header — the literal thing whose absence is "Instagram's own
   raw nav." No native-side change is required for this half.
2. **Stop letting the pre-reload page react after the reload is already
   decided (closes root cause 2).** In `finishHarvest()`, when the code has
   already decided a reload is coming (`!preloadAlreadyCorrect` branch), set
   `favoritesFeedReady = false` **before** calling `deliverFavEdges()` (or
   skip delivering to the `home` webview specifically in that branch — the
   other tabs still need it to release their own held requests, home does
   not, since it's about to reload with the fresh edges preloaded anyway).
   Reorder to: compute `preloadAlreadyCorrect` → if reloading, re-arm
   `favoritesFeedReady = false` first → then `deliverFavEdges()` (scoped to
   non-home tabs in the reloading branch) → schedule the reload. This removes
   the window where the about-to-be-discarded page can independently flip the
   splash-driving flag.
3. **Drop or shrink the fixed 0.3 s pre-reload delay** (`WebViewStore.swift:962`)
   once (2) is in place — it no longer buys any splash-coverage safety, only
   latency. If there's a reason it exists beyond that (e.g. giving in-flight
   `deliverFavEdges()` calls to the *other* tabs time to land before home's
   `URL` changes and their generation checks might matter), document that
   reason inline; otherwise reload immediately after the re-arm.

None of this touches the splice invariants in `favorites-feed.md` (order,
de-dup, lazy getters) — this is purely about when native is told it's safe to
reveal the page, not about what gets rendered.
