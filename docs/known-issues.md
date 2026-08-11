# Known Issues & Regressions

Ordered by priority. Each has a status and a concrete next step. Update this file
as issues are fixed or found.

---

## 0. Device-polish observability and deterministic fixes (2026-07-27)

**Requirement:** R4 (plus R1 marker integrity). **Status:** deterministic bugs fixed;
selector/geometry/animation changes pending a fresh physical-device round.

This pass follows the stale-device-build diagnosis in
`research-2026-07-27-device-polish.md`. Build number is now **2** and startup
prints `[BI-BUILD] device-polish-observability v2`; the next device round must
confirm that exact console line before judging behavior.

**Verified in code and fixed:**

- Pull-to-refresh now has explicit `idle` → `pullCommitted` → `rebuilding`
  phases. The committed phase keeps the current document uncovered and the
  native refresh control active with no splash; only after 0.4 s does the
  rebuild splash appear and the actual re-harvest/home load begin. Whether the
  spinner is visually clear below Instagram's live header still needs device
  confirmation.
- `selfClassChurn()` no longer suppresses Instagram removing a `__bi_*` hide
  marker. Marker removal is treated as real work and the owning article is
  immediately re-filtered; the jsdom gate now covers this regression.
- A successful harvest/density result destroys and detaches its offscreen
  `WKWebView`, reducing the steady-state process from five Instagram documents
  back to the four persistent tabs.
- Native bottom geometry now follows each page's `biNav` state. A page only
  receives the 100-point outer tab-bar clearance while its native tab bar is
  visible, and SwiftUI respects the bottom safe area when the tab bar is hidden.
  The DM inner-scroller padding remains as a reasserted fallback.
- Home and DM title positioning invariants are reasserted on every applicable
  pass. Direct resolves its profile identity before attempting the inbox title,
  removing the first-pass ordering dependency.

**Implemented conservatively; needs device confirmation:**

- DM reel entry now marks a share-card activation before forwarding it, hides
  the newly mounted viewer in the MutationObserver microtask, waits briefly for
  stable fullscreen geometry (hard 400 ms reveal fallback), then reveals with a
  centered scale/opacity transition. Reduce Motion bypasses it. The URL-less
  card detector is a broad large-media-card heuristic, so the device round must
  also confirm ordinary shared posts/photos are never gated as reels.
- The geometric home-caret rule and heuristic DM message-scroller selection are
  intentionally retained pending real DOM evidence. They now reassert their
  styles and emit bounded captures rather than being broadened blindly.

**Diagnostics added for the next round:** every native load/reload/recovery and
navigation lifecycle event has an id/reason plus active tab, URL, loading state,
and offset; userscript boots include document/frame ids and lifecycle/route
logs; `apply()` reports named-stage errors and sampled timings; bounded
`[header-scan]`, `[dm-header]`, `[dm-scroll]`, `[dm-pop]`, and `[feed-remount]`
lines capture the remaining live selector/animation/refetch questions. These
logs do not by themselves prove that random home refreshes, header/caret
instability, DM bottom reachability, DM reel animation, DM inbox centering, or
general slowness are resolved.

---

## 0a. First on-device polish pass (2026-07-26)

**Requirement:** R4. **Status:** implemented, pending on-device verification.

A real-device pass surfaced a cluster of jank/correctness issues. Note: the two
commits that preceded this one (`ce2d8eb`, `1f5c977`) claimed to fix several of
these (watchdog reloads, header stability, DM header/scroll, DM reel pop) but
their actual diffs only touched an Xcode asset-catalog setting and the star
button's icon/label — none of the described JS/Swift changes were ever made.
This entry is the real implementation.

**Header logo instability ("goes left" / caret flashes).** `fixHomeHeader()`
gated both centering the logo box *and* hiding its caret sibling behind
`logoBox.querySelectorAll('svg').length === 1`. Any transient extra svg in
that box (a badge, a nested caret IG sometimes renders there instead of as a
sibling) failed the count check and skipped the whole block for that pass —
leaving the logo unstyled (visually "snapped left") and the caret unhidden
until a later pass happened to see exactly one svg again. Fixed: centering and
caret-hiding are now identity-based ("hide every svg in the box that isn't the
known logo node") instead of count-gated, so a transient extra icon can never
skip the fix.

**DM header username not centered.** No DM-specific header handling existed.
Added `fixDMHeader()` (thread route only): finds the header via the same
bounding-rect walk `fixHomeHeader()` uses (from the "Back" icon instead of the
logo), identifies the title control as the header's clickable child with real
text that isn't the back button or an icon-only control, and absolutely
centers it — the same technique as the logo, chosen because the header's own
flex layout visibly favors whichever side (back vs. call/video/info icons) is
narrower. Left tappable (unlike the decorative home logo) since it opens
thread details.

**DM thread can't scroll all the way down.** The message list scrolls inside
its own inner container (fixed header + fixed composer around it), which the
webview-level `contentInset.bottom` clearance (reserved for the floating
native tab bar) never reaches — so the last message(s) could end up hidden
behind the tab bar with nothing left to scroll. Added `fixDirectThreadScroll()`
(thread route only): finds the tallest actually-overflowing `overflow-y:
auto/scroll` container and gives it real bottom padding, once, idempotently.

**DM reel opens by sliding in from the right.** A reel opened from a DM share
card renders in Instagram's own overlay dialog, which its web client
animates like a page navigation (slide from the right) rather than a native
viewer. Added a one-shot `__bi_reel_pop` scale/opacity CSS animation, applied
to that dialog the moment the DM-scoped reel lock engages (`updateScrollLock`
→ `maybeAnimateReelEntry`), so it pops from center instead.

**Home feed appears to "refresh itself" on leaving a story or comments.** Ruled
out the JS feed watchdog as the cause: `armFeedWatchdog()` sets
`window.__biWatchArmed` once per real page load and never rearms on SPA route
changes (closing a story/comments doesn't reload the page), so it cannot be
responsible for a *repeated*, every-time flash. The likely mechanism is
Re-rendered/re-virtualized feed article nodes being briefly unfiltered after
Instagram's own client remounts the feed route on return to `/`, until the
next `apply()` pass re-hides them. Mitigated by making `onRouteChange()` run
`apply()` immediately (via `requestAnimationFrame`, bypassing the normal
throttle wait) specifically when the route lands back on `/`, shrinking that
window as much as possible from our side. **Not fully diagnosed** — this may
partly be Instagram's own web client re-fetching/remounting the feed on
navigation back (arguably inherent, not introduced by the wrapper). Needs a
follow-up device pass watching `[BI-DEBUG]`/`[feed]`/`[present]` logs timed
around a story/comments close to confirm whether the perceived "refresh" is
purely the DOM-filter flash (now shortened) or an actual navigation/reload.

**Pull-to-refresh.** Added a `.medium` haptic the instant the pull commits
(previously none), delayed showing the full-screen splash by 0.4s so the
native `UIRefreshControl` spinner is visibly spinning under the header first
(previously the splash could cover it almost immediately), and switched the
spinner tint from a hardcoded white to `.secondaryLabel` for light-mode
correctness. Also guarded `handlePullToRefresh()` against re-entry.

**Still open / not addressed this pass:** general "feels slow" — `apply()` is
already route-scoped (contrary to the handoff doc's claim it wasn't); a real
fix needs on-device profiling (Instruments Time Profiler during feed scroll)
to find the actual hot path rather than guessing.

### Follow-up pass (same day, second device round)

Device testing after the above showed three of the fixes didn't actually land
and surfaced one new root cause:

- **DM header fix targeted the wrong screen.** The report ("my name isn't
  centered") was the **inbox** list header (own username + account-switcher
  chevron, e.g. "r.stoffel.62 ⌄"), not the thread header `fixDMHeader()` was
  scoped to (`/direct/t/`, gated on a "Back" icon that doesn't exist on the
  inbox route) — so it never ran. Split into `fixDMThreadHeader()` (unchanged
  logic) and `fixDMInboxHeader()` (new): the inbox title has no reliable
  anchor icon, so it's found by matching text against the username already
  resolved from the nav row (`window.__biLastProfileHref`, populated
  independently per-webview since each tab is its own JS realm).
- **Home logo caret reappears on scroll.** The previous fix hid caret svgs by
  DOM relationship (nested in the logo's box, or its next sibling) — which
  breaks the moment that relationship shifts, and a scroll-triggered
  compact/sticky header variant does exactly that. Replaced with a geometric
  check: after centering the logo box, hide anything small sitting near the
  header's horizontal center, regardless of how it nests. Robust to *how* the
  caret remounts, only cares *where* it visually sits.
- **Cold-start "loads in, then flashes as it reloads" with IG's own nav
  showing.** Root cause: `finishHarvest()`'s post-harvest `deliverFavEdges()`
  can unblock the *pre-reload* page's held feed request immediately, which can
  render real favorites and flip `favoritesFeedReady` true (dropping the
  splash) a moment before the already-scheduled 0.3s-later reload fires — so
  the user sees the splash drop, then Instagram's raw page (with its own
  chrome, before our filters catch up) for the reload's duration, then
  favorites again. This reload itself is not skippable on a true cold start
  (see #1's root cause: the initial SSR-embedded HTML, not the XHR, is what
  actually renders, and only a reload gets favorites into a fresh SSR embed).
  Fixed by re-arming `favoritesFeedReady = false` at the moment the reload is
  scheduled, so the splash stays up for the whole cycle and only the
  *reloaded* page's own `biFavReady` drops it.
- **DM reel still slides in from the right.** Broadened the overlay-container
  search (role=dialog, then the scroll-lock container, then the nearest
  fixed/absolute-positioned near-fullscreen ancestor) and switched from a CSS
  class/keyframes animation to a JS-driven `!important` inline
  transform/opacity transition, since `!important` inline outranks a CSS
  transition class Instagram might be using. **Still unverified** — if
  Instagram drives the slide by reassigning this same element's inline
  `transform` every frame (a JS/Framer-Motion-style animation rather than a
  CSS class), no inline-style trick on that element can win: assigning
  `.style.transform = x` from JS clears any prior `!important` on that
  property regardless of who set it. Added a `[dm] reel pop applied
  role=...` log; if the slide persists, check whether that log fires at all
  (wrong element found) versus fires but is visually overridden (wrong
  animation mechanism, needs a live capture of what's actually driving it).

---

## 1. Favorites feed regression — home feed spins / renders too few  ⚠️ TOP PRIORITY

**Requirement:** R1. **Status:** RESOLVED (2026-07-14, confirmed on device — favorites render).

**Symptom.** The favorites home feed hung on an infinite loading spinner under
the stories tray. `[favsplice] swapped favorites into home response` logged, yet
`[feed] all N articles hidden` and nothing rendered.

**Real root cause (proven).** Instagram **server-streams the home feed into the
page HTML** (`<script type="application/json" data-sjs>` RelayPrefetchedStreamCache
blocks) and renders the **initial** feed from that streamed data — **not** from
the feed XHR. The long-standing splice patched the *XHR* response (lazy getters
on `responseText`), which nothing rendered from: the screen showed Instagram's
algorithmic accounts (twotimevae, stealth.mode.savings, _bellramirez), the DOM
`filterArticle` hid them all → spinner. Diagnostics proved the harvested edges
were fine: `[edgediff]` showed the FAV and HOME edge node+media keys byte-identical,
`[favshape]` showed all had renderable media — yet `[feed]` only ever listed
algorithmic authors, so favorites never entered the DOM. This is why it "worked
hours ago then broke with no code change": Instagram shifted the initial render
from the XHR path to SSR, and the code had to follow.

**The fix.** `installSSRFeedSplice()` in `ContentFilter.swift` hooks `JSON.parse`
at document-start; for any parsed object carrying a `feed__timeline` connection it
replaces `.edges` with the harvested favorites and sets `page_info.has_next_page
= false` **before Relay hydrates**. Instagram's bootloader parses the streamed
blocks with the global `JSON.parse`, so this catches the SSR render. Edges are
made available synchronously at document-start via native preamble
`window.__biFavEdgesPreload` (`WebViewStore.installUserScripts` appends it when
`cachedFavEdgesJSON` exists; `harvestExtract` re-installs scripts before the
post-harvest home reload). The XHR splice stays for infinite-scroll pages. Logs:
`[favsplice] SSR feed splice armed (N edges)` / `spliced favorites into SSR feed
data`. See `favorites-feed.md`.

Also hardened in the same pass: `sanitizeFavEdges()` (single choke point — keeps
only renderable `node.media` post edges, de-dupes by `media.pk||id||code`,
**never sorts**) and `feedVariant()` + `window.__biNativeFavMode` (if Instagram's
own request is already `variant=favorites`, leave the feed untouched and stand the
DOM author-filter down — Instagram renders favorites natively).

**Follow-ups.** Density (~2–3 posts) still open — see #2. The one-time
diagnostic logs (`[favshape]`, `[edgediff]`, verbose per-article `[feed]`
census) have been trimmed now that the cause is understood; `reportFeedHealth()`
still logs a single `[feed] N articles, M hidden` summary line for ongoing
operational visibility.

---

## 2. Favorites feed density ceiling (~2–3 posts)

**Requirement:** R1 (quality of). **Status:** implemented (density pass), pending
on-device verification.

Instagram streams only ~2–3 posts into the favorites page HTML and its favorites
pagination reports `has_next_page: false`, so the harvest alone can't get more.
The density pass (`WebViewStore.densifyHarvest()` → `ContentFilter.densityScript`)
now fetches each favorite's recent profile media (`/api/v1/feed/user/<id>/`,
30-day window, ≤12/user, ≤50 total) and **appends** it to the streamed edges —
template-cloned edges, real api/v1 media, de-duped, clips skipped, **never
sorted**, fail-safe fallback to streamed-only. See `favorites-feed.md` → Density
pass.

**Known risk.** A prior attempt to *synthesize* timeline edges made Relay throw;
this pass mitigates by cloning real harvested edges and using real api/v1 media
objects, but a device run must confirm Relay renders the appended posts (watch
`[BI-density] appended N`, then the `[feed]` census showing them `(shown)`; if
the spinner returns, the fail-safe streamed-only path is one flag away).

**Verify on device.** Feed should show noticeably more than 3 posts, all from
favorites, streamed posts first, then per-account recents.

---

## 3. Account-only search not enforced on results

**Requirement:** R3. **Status:** implemented (2026-07-21), pending on-device
verification of the exact response shape.

Explore entry points/routes were already blocked. Added a data-layer filter:
`filterSearchPayload()` (and its helpers `looksLikeSearchPayload`,
`stripNonAccountSearchKeys`, `filterSearchSections`, `looksLikeSearchText`) in
`ContentFilter.swift` recognizes any fetch/XHR response carrying a top-level
`users` array and strips known non-account keys (`hashtags`, `places`, `clips`,
`medias`, `media_grid`, `reels`, `top_results`, `keyword_results`,
`explore_grid`, `ai_agent_response`, `about_this_account`) plus non-account
entries from a generic `sections` container — all **before** Instagram's
search UI renders, via the same network-response-rewrite choke points already
used for the feed (`installFetchFilter`, `installXHRFilter` /
`rewriteFeedText`), so there's no flash of post/hashtag/AI content to hide
after the fact (R4). This runs independently of `favoritesOn` /
`__biNativeFavMode`, which only gate the *feed* splice. `fixSearchPage()` also
gained a DOM backstop, `hideNonAccountSearchResults()` — hides post/reel/
hashtag/place links and stray "Tags"/"Places"/"Top" tab controls — but this is
secondary only; the data-layer strip is the primary mechanism. Log:
`[search] filtered search results to accounts-only (xhr)` / `[fetch] filtered
search results to accounts-only ...`.

**Assumption to verify on device.** The exact key names above were inferred
from the known topsearch shape (`payload.users`, see
`blocking-and-selectors.md`) and general Explore/search conventions — they
were **not** captured from a live search response in this sandbox. Watch for
the `[search]` log firing on a real query; if it never fires (or a post/
hashtag/AI block still renders), the real response uses different key names
and this needs a fresh capture + key update. The DOM backstop's "Tags/Places/
Top" tab-label matching is also a guess at current IG search-tab copy and may
need updating if Instagram changes it.

---

## 4. Cold-start reload flash

**Requirement:** R4 (P8). **Status:** partially eliminated (2026-07-21) — reload
is now skipped on warm relaunches where it would be a no-op; still happens (as
the correct fallback) on a genuine cold start or whenever content changed.

**Background.** `cachedFavEdgesJSON` was (and remains) purely in-memory — it is
never persisted, so on every app **process** launch it starts `nil`: the home
tab's very first `.load()` in `WebViewStore.init()` always fires before any
harvest can complete, meaning every launch was a true cold start requiring the
load → harvest → reload cycle, not just the very first run after install.
`SplashView` masks this. If the harvest is slow or fails, the splash falls back
after ~20 s.

**The fix.** `WebViewStore` now persists the harvested edges JSON to
`UserDefaults` (`biCachedFavEdgesJSON`) on every successful harvest, and reads it
back **synchronously in `init()`, before the home webview's first `.load()`**,
arming `window.__biFavEdgesPreload` for that very first paint. This is never
trusted blindly: `finishHarvest()` only skips the post-harvest reload when the
**live** harvest that follows is byte-identical to what was preloaded from disk
(`preloadedFromDiskJSON`) — proof the already-rendered SSR splice used exactly
that data, so a reload would repaint nothing new. Any difference at all
(account switch, changed picks, new posts since last launch, or no disk cache
yet — the true first-ever-run case) falls through to the existing reload
unchanged. `applyFavoritesSelection()` and `reharvestAndReloadHome()` (resave /
retry / pull-to-refresh) explicitly clear `preloadedFromDiskJSON` so this skip
can only ever fire from the natural launch-time harvest, never those flows.

**Next step.** Verify on device across a few real relaunches that the skip
actually fires (`[BI-harvest] disk preload matched live harvest; skipping
post-harvest reload`) when favorites haven't changed, and that a changed
favorites list / new posts still correctly falls back to the reload.

**Follow-up (2026-07-27): the `7b4e3e1` re-arm fix genuinely landed (verified
via `git show`) but does not stop the flash — it reproduces every cold launch.**
Full diagnosis in `research-2026-07-27-coldstart-reload-flash.md`. Two real,
stacked gaps, not one: (1, primary/structural) `biFavReady` — the only thing
that sets `favoritesFeedReady = true` — fires the instant harvested data is
spliced into a parsed response (`installSSRFeedSplice()`'s `JSON.parse` hook,
or the XHR splice in `rewriteFeedText()`), with no check that the page has
actually run its own DOM-filter pass yet; `ensureStyleInjected()` (the CSS hide
injection) and `fixHomeHeader()` (logo centering, caret hiding, favorites star)
only run inside `apply()`, which is on its own independent `requestAnimationFrame`/
`document.body` timer (`start()`) with zero ordering relationship to `biFavReady`.
(2, contributing) `finishHarvest()` calls `deliverFavEdges()` — which unblocks
the still-visible pre-reload page's held feed request — one line **before**
re-arming `favoritesFeedReady = false`, so that page can independently
re-flip the flag (or run an uncovered `scheduleApply()`) in the gap before the
fixed 300 ms reload timer fires.

**Implemented (2026-07-27), both halves of the recommended fix.** (1)
`ContentFilter.swift`: the three `biFavReady` call sites now call
`markFavDataReady()` instead of posting directly; `biFavReady` only actually
posts from `maybePostFavReady()` once **both** `window.__biFavDataReady` and a
new `window.__biFirstApplyDone` (set in a `finally` block at the end of
`apply()`, so it's true after the first pass regardless of whether a later
stage threw) are true — so `favoritesFeedReady` can no longer flip true before
this document's own `ensureStyleInjected()`/`fixHomeHeader()` pass has run. (2)
`WebViewStore.swift`'s `finishHarvest()`: when a post-harvest reload is about
to happen, `favoritesFeedReady = false` is now set **before** delivering
edges, and `deliverFavEdges(includingHome:)` skips the home tab specifically
in that branch (the about-to-be-discarded pre-reload page never gets a chance
to react); the now-pointless fixed 0.3 s pre-reload delay was also removed
since the splash's coverage no longer depends on it. `tools/check.sh` passes
and a simulator build succeeds. **Needs on-device confirmation** that the
flash is actually gone across a few real cold launches — static analysis and
the jsdom harness can't observe the real HTML-streaming/paint timing this bug
lives in. See `research-2026-07-27-coldstart-reload-flash.md` for the full
diagnosis and line citations.

**Hardened same day: bounded fallback on the apply()-gate.** A first on-device
run after the above landed hit a **separate, pre-existing** failure — the
harvest webview never reached `didFinish` across four straight generations (no
`[BI-nav] ... event=didFinish reason=harvest-generation-N` and no
`[BI-harvest] count=` in the console at all), so `finishHarvest()` was never
even reached, and the disk-preloaded SSR splice also never matched
(`[favsplice] spliced favorites into SSR feed data` never logged) — both
mechanisms this fix doesn't touch. That run would have hung under the old code
too (nothing ever made `biFavReady`'s underlying data-ready condition true),
but it exposed a real gap in the new apply()-gate: if `apply()` ever stalls or
throws for a reason unrelated to favorites, gating `biFavReady` on it with no
escape hatch can turn a cosmetic flash into a permanent hang — worse than the
bug it fixes. `markFavDataReady()` now arms a bounded 1.5 s fallback timer: if
`apply()` hasn't completed by then, `biFavReady` posts anyway
(`[favsplice] apply() did not complete within 1.5s of data-ready; posting
biFavReady anyway`). Normal case is unaffected (apply()'s first pass typically
completes well under 1.5 s of `document.body` existing). The harvest-webview-
stuck-at-didCommit symptom itself is still open and unrelated — likely
Instagram-side throttling from the watchdog's own rapid-fire retry loop (four
full page loads of instagram.com in under 90 s); needs a longer device capture
to confirm whether `didFinish` eventually fires late or never at all.

**Second device round found a real, pre-existing infinite-loop bug, now
fixed.** With the harvest no longer hanging, a fresh log showed the SSR splice
succeeding at the data layer (`[favsplice] spliced favorites into SSR feed
data`) but the DOM briefly still showing 0 visible favorites
(`[feed] 2 articles, 2 hidden` — React hadn't yet hydrated the spliced data
into the article nodes `filterArticle()` was evaluating). That's expected to
self-correct via the MutationObserver within the watchdog's normal 9 s window
— except the `biFavReady` handler (`WebViewStore.swift`, `userContentController
didReceive`) was unconditionally resetting `feedRecoveryAttempts = 0` on
**every** `biFavReady`, including ones that fire without the feed ever
actually showing a favorite. That replenished `handleFeedStuck()`'s intended
"one automatic recovery, then show the retry screen" budget on every single
reload cycle, producing exactly what was reported: reload → `biFavReady`
fires → budget resets → watchdog finds it still stuck 9 s later → auto-recover
again → reload → repeat forever, splash re-showing each time, never reaching
`FeedErrorView`. This predates today's flash fix (the reset line is untouched
by it) — the flash fix likely only made it easier to notice by changing when
`biFavReady` fires relative to the DOM hydration race. Fixed: the reset was
removed from the `biFavReady` handler; the budget now only refills on an
explicit new attempt (`applyFavoritesSelection()`, `retryFavoritesFeed()`, or
an account switch via `resetAccountDerivedState()`), so a feed that's still
stuck after one watchdog-triggered recovery now correctly reaches the retry
screen instead of looping. `tools/check.sh` and a simulator build both pass.
**Needs on-device confirmation**, along with the original flash fix.

---

## 4a. Swipe-back white flash (2026-08-10)

**Requirement:** R4. **Status:** implemented, pending on-device confirmation.

**Symptom (reported, issue #3).** Swiping right to go back — e.g. leaving a
DM thread for the inbox — showed roughly a 1s flash of a blank white screen
before landing on the previous screen.

**Root cause.** `allowsBackForwardNavigationGestures` was `true`.
`WKWebView`'s built-in interactive swipe-back gesture is documented WebKit
behavior that forces a full document reload when the gesture lands on a
same-document (`history.pushState`) history entry — exactly how Instagram's
own client-side routing implements DM thread ↔ inbox and most other in-app
transitions. The reload's blank initial paint, before the injected
document-start CSS/JS re-applies, is the flash. A programmatic `goBack()`
call does not have this problem: for a same-document entry it fires a
`popstate` event with no network reload.

**The fix.** `WebViewStore.makeWebView` sets
`allowsBackForwardNavigationGestures = false` and instead adds a
`UIScreenEdgePanGestureRecognizer` pair per webview (left edge → `goBack()`,
right edge → `goForward()`), calling the API directly on gesture end instead
of letting WebKit drive its own interactive transition. `canGoBack`/
`canGoForward` gate no-ops when there's no history in that direction.

**Needs on-device confirmation** that the flash is gone and that the edge
gesture doesn't conflict with any Instagram-side horizontal swipe interaction
near the screen edges (e.g. a DM message swipe-to-reply).

---

## 4b. Preferences (star) button disappearing intermittently (2026-08-11)

**Requirement:** R4. **Status:** implemented, pending on-device confirmation.

**Symptom (reported, issue #4).** The injected star control button ("Lillygram
Controls", top-left of the home header) sometimes disappears and does not come
back.

**Root cause.** `fixHomeHeader()` found its header container via a strict
bounding-rect walk (width ≥ 90% viewport, 0 < height < 150, no nested
`<article>`) up to 12 ancestors from the logo, and the star-button
(re)injection check lived *after* that walk, inside the same early-return
guard. Any single pass where the walk failed to match — a transient
compact/sticky header variant, an in-flight header animation, or any other
momentary layout state — bailed out of `fixHomeHeader()` entirely before ever
reaching the button check. If Instagram had also remounted the header element
itself around the same time (removing the previously-injected button along
with the old node), the button was never reattached until a later pass
happened to satisfy the strict geometry again — sometimes never, for the rest
of that page view.

**The fix.** Split button (re)attachment into its own `ensureStarButton()`,
called unconditionally on every `fixHomeHeader()` pass with either the
strictly-matched header or a permissive fallback (`logo.closest('header')` /
the logo's parent) when the strict walk misses. The logo-centering/caret-hiding
work (which genuinely needs the strict geometry to avoid mis-centering) still
returns early on a miss, but no longer takes the star button down with it.

**Needs on-device confirmation** across a scroll-heavy session (the scroll-
triggered compact header variant is the most likely trigger for the geometry
walk to miss).

---

## 4c. Safe area not black for Stories/Reels, occasionally wrong color otherwise (2026-08-11)

**Requirement:** R4. **Status:** implemented, pending on-device confirmation.

**Symptom (reported, issue #5).** The native top/bottom safe-area painter was
buggy: it should always show the same color as the current page's main
background — except pure black for Stories/Reels — but instead the safe area
sometimes turned white on the home page (most noticeably around opening a
Story), and did not reliably match on other screens.

**Root cause.** `WebBridge.safeAreaBackground` is meant to be pinned to black
while `biPresentation` reports an immersive Story/Reel viewer (per
`architecture.md`'s own description of the intended design), but
`WebViewStore.setPresentation(locked:immersive:for:)` never actually read its
`immersive` parameter when setting the safe-area color — it always used the
cached page background, `immersive` was only ever stored into `immersiveCache`
for later (unrelated) reads. The same gap existed in
`publishCachedPresentation(for:)` (used on tab switch). Compounding it: the
web-side `reportBackgroundColor()` ran on every `apply()` pass unconditionally
— including while a Story/Reel viewer was open — sampling the *viewer's own*
composited colors (which can include transient white progress-bar/control
chrome) and posting them as `biBg`, which the native handler applied straight
to `safeAreaBackground` with no immersive guard. In light mode, opening a
Story on home (cached base color = white) reproduces exactly the reported
symptom: a white safe area where black is required.

**The fix.** `setPresentation()` and `publishCachedPresentation()` now set
`bridge.safeAreaBackground = .black` whenever the relevant webview is
immersive, falling back to the cached base color otherwise.
`reportBackgroundColor()` (`ContentFilter.swift`) now returns early while
`isImmersiveSurface(shouldLockScroll())` is true, so it stops sampling/posting
`biBg` for the duration of the viewer instead of racing the black override.
The native `biBg` handler also gained a defensive check against
`immersiveCache` so a message already in flight when immersive state flips
can't slip through either.

**Needs on-device confirmation**, particularly: opening/closing Stories and DM
reels in both light and dark mode, and switching tabs to Search/Direct/Profile
to confirm each one's own safe-area color matches that page's actual
background.

---

## 4d. Leaving comments via the back arrow reloads home (2026-08-11)

**Requirement:** R4. **Status:** implemented, pending on-device confirmation.

**Symptom (reported, issue #6).** Viewing a post's comments and leaving via
the on-screen back arrow reloaded the home page instead of just returning to
it — home is supposed to stay loaded (warm, no reload) the whole time.

**Root cause.** `installCommentBackRouting()` already intercepted the click on
comments' back-arrow control, but only called `e.preventDefault()` and then
relied on Instagram's own click handler still being attached to run the
actual (client-side, no-reload) close/back behavior. That assumption doesn't
hold for the mobile full-page comments view, which can be a genuine
server-rendered route with no client router listening on that control at all
— `preventDefault()` alone then either does nothing (stuck on comments,
unreported because it reads as "unresponsive," not "reload") or, if some
*other* ancestor handler still performs a real navigation, produces exactly
the reported full document reload.

**The fix.** The handler now drives the transition itself instead of gambling
on Instagram's own handler: `history.back()` (or `goToPath('/')` if there's no
history to go back to), plus `e.stopPropagation()` so nothing else double-
handles the same click. `history.back()` consumes the same-document history
entry the comments view opened on and fires a `popstate` Instagram's own
router listens to regardless of whether a click handler exists on this
specific control — the identical no-reload mechanism the swipe-back fix
(#4a / issue #3) already relies on.

**Needs on-device confirmation**, both for the dialog and full-page comments
variants, and that this doesn't fire on unrelated icons that happen to also
carry `aria-label="Back"`.

---

## 4e. Resave/retry double-reloads home, splash drops then reappears (2026-08-11)

**Requirement:** R1, R4. **Status:** implemented, pending on-device
confirmation.

**Symptom (reported, issue #7).** Selecting new favorites and hitting Save:
splash appears correctly, drops, the new favorites don't show for a few
seconds (stale/wrong feed visible), then the splash pops back up, then the
correct favorites finally show.

**Root cause.** `applyFavoritesSelection()` (and, for retry/pull-to-refresh/
watchdog-recovery, `reharvestAndReloadHome()`) called `harvestFavorites()`
*and* immediately, unconditionally reloaded the home tab in the same breath —
before the harvest could possibly have produced any data
(`cachedFavEdgesJSON` was still `nil` at that point). `finishHarvest()`
*separately* reloads home once real edges exist, gated on
`didReloadHomeForFavorites` — but both call sites had just reset that flag to
`false`, so `finishHarvest()`'s own reload still fired afterward: two reloads
per selection change, not one. The first (blind) reload's page has no
favorites preload at all, so it can independently satisfy the
`biFavReady`/`markFavDataReady()` data-ready gate on stale or empty content
and flip `favoritesFeedReady` true — which the resave splash (`ContentView`)
is directly bound to, so it drops onto that wrong content. The *second*,
real reload (from `finishHarvest()`) then re-arms `favoritesFeedReady = false`
before it loads, popping the splash back up, until its own `biFavReady`
finally flips it true for good with the correct data. Pull-to-refresh is not
user-visibly affected by this same bug because its splash is instead gated on
`refreshPhase == .rebuilding`, not on `favoritesFeedReady`, for the whole
rebuild window — but retry-from-error-screen and watchdog-recovery share the
resave splash's `favoritesFeedReady`-gated logic and were equally exposed.

**The fix.** Both call sites now only perform the immediate reload when a
harvest *isn't* going to run at all (`favorites.isFilterEnabled` false, or no
session — mirrors `harvestFavorites()`'s own guard); otherwise they call
`harvestFavorites()` and let `finishHarvest()`'s existing gated reload be the
**only** reload, once real data exists. The splash already covers the screen
for the whole harvest window regardless (nothing to protect by reloading
early), so this removes a redundant reload rather than changing any
user-visible timing.

**Needs on-device confirmation**: save a favorites change and confirm exactly
one splash cycle, landing directly on the correct favorites with no visible
intermediate feed.

---

## 5. Sync custom (app) favorites → official Instagram Favorites list

**Requirement:** R1. **Status:** two-way reconcile implemented and
device-confirmed (2026-07-21) — both add and remove now work end to end.

**Key finding (device-confirmed 2026-07-14): `set_besties` (any module) writes
the CLOSE FRIENDS list (`is_bestie`), NOT the Favorites list
(`is_feed_favorite`); and the `api/v1/friendships/favorite|besties` endpoints
reject the web session (`400 useragent mismatch`).** The real favorites write is
a **GraphQL mutation** (captured from the web "Add to favorites" chevron):
`POST /api/graphql`, `fb_api_req_friendly_name=
usePolarisUpdateFeedFavoritesUpdatableFavoriteMutation`, `doc_id=27127248780249605`,
`variables={"data":{"add":[ids],"remove":[],"source":"favorites_management"}}`
(unfavorite = `usePolarisUpdateFeedFavoritesUpdatableUnfavoriteMutation`,
`doc_id=27275847402052259`, with the id in `remove`). `add`/`remove` are arrays,
so the whole sync is one call. It needs the page's `fb_dtsg` + `lsd` anti-CSRF
tokens, scraped from the page HTML (`"DTSGInitialData",[],{"token":…}` /
`"LSD",[],{"token":…}`). **`doc_id`s rotate (~weeks) — re-capture when
`confirmed=0` returns.** A **one-time cleanup** (`cleanedCF=N`, latched via
UserDefaults `biDidCleanBesties`) removes the picks from Close Friends
(set_besties `remove`).

**Per-account ground truth.** The besties list probes fail on the web session
(`400 {"message":"useragent mismatch"}` — the bulk-read endpoint wants the app
UA; `bestie_list/` is a 404), so the sync uses `/api/v1/friendships/show/<id>/`
per pick instead. The favorites flag there is **`is_feed_favorite`** (Favorites
list); `is_bestie` is Close Friends and only used as fallback when
`is_feed_favorite` is absent. Per pick the sync: skips already-favorited,
surfaces `NOT-FOLLOWED(cannot favorite): …` (Instagram only allows Favorites
for followed accounts; `set_besties` silently ignores the rest), and **verifies
after the write** (`confirmed=N`). A `[sync] flags` log line dumps each pick's
raw `follow/bestie/fav` flags.

**UI caveat — fixed (2026-07-21).** The star badge on density-appended posts was
missing because `densityScript` (`ContentFilter.swift`) filled the appended
item's missing fields with `null`, including `friendship_status` — and Instagram
reads that field from **`media.user.friendship_status`**, not from a top-level
field on the media object itself (confirmed by inspecting a real streamed edge's
shape). A first attempt set `item.friendship_status` directly and had zero
effect — silently wrong nesting level, not a no-op — until checking the actual
persisted harvest JSON's structure caught it. The fix sets
`item.user.friendship_status = { following: true, is_feed_favorite: true }`
(we already know this is true — it's the only reason the account was fetched).
Device-confirmed: previously star-less density-appended posts (kangaroo_coder,
kipung_park) render the star correctly after this fix. The "Remove from
favorites" menu entry was not separately re-tested but should follow the same
field.

**Triggers.** The sync runs (a) when picks are applied in the favorites editor
and (b) **once per launch** after the home tab finishes loading, so a
failed/partial sync self-heals on boot; if the launch sync wrote changes it
re-harvests so the feed follows.

**Verify on device.** After changing picks (or just relaunching), `[BI-sync]`
should log `wrote favorites add=N ok=N confirmed=N … remove=R removedOk=R
removedConfirmed=… cleanedCF=K` (or `already in sync`). `confirmed < add` means
the favorite/ endpoint is being rejected — capture the web chevron's request in
devtools. `NOT-FOLLOWED` names picks that need a follow first.

**Remove-side reconcile (2026-07-21, implemented, device-confirmed).** Bug
found live: a favorite deselected in-app kept showing in the feed because (a)
`syncFavoritesToInstagram()` only ever added — nothing ever unfavorited an
account on the real Instagram account once removed from the app's picks, and
(b) `densityScript` (`ContentFilter.swift`) seeded its "who to fetch extra
posts for" list from **every author already present in the streamed favorites
edges**, not just the current picks — so a stale real-Instagram favorite kept
getting MORE profile posts density-appended even after being deselected in-app.
Since the bulk favorites-list-read endpoint is blocked (can't enumerate
Instagram's real Favorites list to diff against), the fix doesn't try to: it
persists (`UserDefaults` key `biSyncedFavoriteUsernames`) the username list this
app itself most recently confirmed as synced, and on every sync diffs that
against the current picks — anything dropped gets unfavorited via the
mutation above (`remove` array, `UNFAV_DOC_ID`/`UNFAV_FN`). This only ever
removes what this app itself added; a favorite the user set up directly in the
real Instagram app is never touched. `densityScript` was also fixed to use the
streamed edges only as an id lookup shortcut, never as an independent source of
who to fetch — density targets are strictly the current picks. **Confirmed on
device 2026-07-21:** a stale test favorite ("nasa," added during an earlier
onboarding test) was removed via `[BI-sync] ... remove=1 removedOk=1`, and the
next harvest cycle correctly stopped streaming its posts and started streaming
the real current picks instead, density included.

One rough edge observed live: the immediate post-write verification
(`removedConfirmed`) can read `0` even when the unfavorite mutation succeeded
(`removedOk=1`) — Instagram's `friendships/show` read-after-write appears to
lag briefly behind the actual removal, so `removedConfirmed` is a soft signal,
not proof of failure; the next harvest is the real confirmation. Also: a
launch-time re-harvest triggered by the sync's `remove` can race a still-in-flight
density fetch from the *previous* harvest cycle in the same hidden webview,
observed live as that cycle's density silently erroring out
(`fetch=...:err` for every id) — harmless (the existing fail-safe fallback to
streamed-only edges absorbs it and the next cycle succeeds normally), but worth
knowing if `[BI-density] ... :err` shows up right after a favorites change.

**Onboarding disclosure (fixed 2026-07-22).** The picker now states that saving
changes also updates the user's official Instagram Favorites list. The sync
continues to add selections and remove only accounts this app previously added.

### Proposed: doc_id resilience (discussion, not a finished spec)

**The problem restated.** `FAV_DOC_ID` (`27127248780249605`) and the unfavorite
mutation's `doc_id` (`27275847402052259`) are string literals in
`syncFavoritesToInstagram()`. Instagram rotates these ~weeks. Today, when a
`doc_id` goes stale the mutation call presumably 400s or comes back with a
GraphQL `"errors"` body (the existing `if (r.ok && t.indexOf('"errors"') ===
-1)` check treats that as `wrote = 0`), so the post-write verification loop
reports `confirmed=0`. Nothing acts on that beyond a `print("[BI-sync] ...")`
line a human has to notice in Xcode console, then manually re-capture the new
`doc_id` from the web "Add to favorites" chevron in devtools and hand-edit the
Swift source. There's no server, no remote config, and no App Store release
channel to push a fix through (see #8) — any real fix has to live entirely in
what ships in the binary today.

**Option A — discover `doc_id` dynamically at runtime, so it's never hardcoded.**
This is the option worth taking seriously, because `fb_dtsg`/`lsd` already prove
the *pattern* works: those tokens are scraped straight out of
`document.documentElement.innerHTML` because they're small, universal JSON
blobs (`"DTSGInitialData",[],{"token":...}` / `"LSD",[],{"token":...}`) that
*every* page ships, since practically every mutating request needs them.

The favorites `doc_id` is not in the same position, and I don't think it's
safe to assume it's scrape-able the same way:

- A `doc_id` is generated at build time by Meta's relay-compiler for one
  specific named mutation. Meta's web client code-splits per-feature (the
  favorites mutation is invoked from one specific UI affordance — the profile
  overflow menu's "Add/Remove Favorites" toggle) rather than shipping every
  query module on every page. The sync script runs inside the **home feed**
  page's JS context (`webViews[.home]`, not a profile page, and never having
  opened that specific menu), so there is no strong reason to expect that
  mutation's compiled module — and the `doc_id` embedded inside it — is even
  present in that page's loaded JS at all, the way `fb_dtsg`/`lsd` provably
  are on every page.
- Even if it were present somewhere in a loaded chunk, there is no known
  stable, generic marker to find it by (unlike `"DTSGInitialData",[],{...}`,
  which is a fixed, documented-by-convention key). It would live inside
  Meta's minified/obfuscated module-registry internals
  (`__d(...)`/`require(...)`-style definitions), which are not a public
  contract and could easily be *more* volatile than the `doc_id` itself.
- Reliably obtaining it would most likely require actually triggering the
  real "Add to Favorites" menu in the DOM (simulated taps on a live profile's
  overflow menu) so its module loads, then reaching into whatever internal
  registry holds it — trading one fragile hardcoded string for a fragile,
  higher-surface-area DOM+internals scrape that runs some real risk of
  triggering the mutation for real (with unintended `add`/`remove` sets) if
  the automation doesn't stop at the right step.

  I have not verified any of the above against a live Instagram session —
  and per this task's own constraint I did not attempt to (no live network
  experiments this session). So this is reasoned from the existing scraping
  code and the general Relay/Comet bundling model, not confirmed. **Concrete,
  cheap way to actually settle it:** next time the `doc_id` needs re-capturing
  from devtools anyway (the existing manual procedure), also search the
  loaded page source / JS bundles (Sources panel, or grep
  `document.documentElement.innerHTML` plus fetched script bodies) for the
  literal friendly-name string (`usePolarisUpdateFeedFavoritesUpdatableFavoriteMutation`)
  and see whether a numeric id sits next to it in something that looks like a
  generic name→id manifest (as opposed to being buried in obfuscated
  per-module code). If it's there and looks stable across a couple of page
  loads, dynamic discovery becomes worth building. If not, it isn't.

  **I'm not confident enough in this to implement it blind**, and getting it
  wrong risks firing a malformed/misdirected favorites mutation against the
  user's real account — so this stays a proposal pending that manual check,
  not something built this session.

**Option B — degrade gracefully, make failure visible instead of silent.**
Whether or not Option A ever pans out, the sync already self-heals on a
schedule (runs once per launch, so it retries automatically — see
"Triggers" above) but does so **silently**: a stale `doc_id` today produces
nothing but a console line, indistinguishable from any other transient
hiccup, for however many weeks until a human happens to be watching Xcode
console at the right time. Making that failure *visible and persistent*
(survives past the current console session, distinguishable from a one-off
network blip) is low-risk, additive, and doesn't change any network
behavior — it only decides whether repeated `confirmed < add` results get
remembered and exposed. This is the piece implemented below (see "What was
implemented").

**Open product question — explicitly not decided here.** Whether a degraded
signal should just sit as internal state (for a future settings screen /
debug view) or actually surface a user-facing banner/badge right now — and if
so, where and with what copy — is a UI/product call, not a
low-risk-and-obvious one, so it is intentionally left open rather than
guessed at.

**What was implemented (2026-07-21).** Only the failure-**visibility** piece,
scoped to `WebViewStore.swift`: `syncFavoritesToInstagram()`'s result string is
now parsed for `add=`/`confirmed=` counts. When `confirmed < add` (previously
just a printed line), `favoritesSyncDegraded` — a new persisted
(`biFavoritesSyncDegraded` in `UserDefaults`) `@Published` flag mirroring the
existing `feedStuck` pattern — flips true and a single explicit
`[BI-sync] DEGRADED: ...` log line names the likely cause (stale `doc_id`) and
points at this doc section. It flips back false the next time a sync fully
confirms. Nothing about the sync's actual network behavior, retry cadence, or
add/remove logic changed. No UI consumes the flag yet (see the open product
question above) — it's there for `[BI-sync]` grep-ability today and a future
settings-row/banner to read tomorrow. Dynamic `doc_id` discovery (Option A)
was **not** implemented — see above.

---

## 6. Favorites `UserDefaults` keys are not namespaced per account

**Requirement:** R1. **Status:** partially mitigated (2026-07-23); full
namespacing still open.

All favorites state is stored under **global** `UserDefaults` keys —
`FavoritesStore`'s picks + onboarding flag, and `WebViewStore`'s
`biCachedFavEdgesJSON` / `biSyncedFavoriteUsernames` / `biFavoritesSyncDegraded`
/ `biDidCleanBesties`. Nothing is scoped to the Instagram account, and all four
webviews share one `WKWebsiteDataStore`, so switching accounts in Instagram web
leaves the previous account's state in place.

**Mitigated.** Account identity is now keyed on the **`ds_user_id`** cookie
(not `sessionid`, whose value also rotates on re-auth/2FA within one account).
A changed `ds_user_id`, or a logout, runs
`WebViewStore.resetAccountDerivedState()`: bumps the harvest generation,
clears the cached + persisted fav edges, drops the sync baseline and the
degraded flag, resets the resolved profile URL and the launch-sync latch, and
reinstalls the user scripts so `__biFavEdgesPreload` can't SSR-splice the old
account's posts into the new one's feed.

**Still open.** The *picks* themselves (`FavoritesStore`) stay global, so
account B inherits account A's selected usernames, and the next launch sync
will write them to account B's real Instagram Favorites list. Proper fix:
namespace every favorites key by `ds_user_id` (`bi.<userid>.favorites`, …) with
a one-time migration of the existing global keys into the current account's
namespace. That touches `FavoritesStore.swift` and was deliberately left out of
the WKWebView hardening pass rather than done half-way.

**Interim mitigation for a user who switches accounts:** re-open the favorites
editor and re-save, which re-syncs the picks against the account now signed in.

---

## 7. Instagram-web fragility

**Requirement:** all. **Status:** inherent.

Everything rides Instagram-web internals — query friendly-names, rotating
`doc_id`s, the `xdt_api__v1__*` keys, DOM selectors, the streamed-HTML mechanism.
Any of these can change and silently break a feature. See the reference table in
[blocking-and-selectors.md](blocking-and-selectors.md) for what to re-capture.

**Next step.** When a feature silently stops working, re-capture the current
value from a live session (`[BI-DEBUG]` request logs / devtools) and update the
selector reference.

---

## 8. Distribution posture (not App Store viable)

**Requirement:** context. **Status:** accepted.

Wrapping Instagram, using private feed shapes, and mutating the favorites list
put this outside App Store review norms. It is a personal/side-load-class app.
No action unless distribution goals change.

---

## 9. Carried-forward risks (audited, deliberately not changed)

**Status:** known and accepted; each has a concrete next step if it bites.

- **Synthetic Relay cursors on density-appended edges.** `densityScript` sets
  `edge.cursor = 'bi-<media id>'` on appended edges. This sits right next to the
  documented spinner invariant (a Relay connection wants edges in Instagram's
  original cursor order). It has been device-confirmed working, and the
  connection sets `has_next_page = false`, so nothing ever pages *from* these
  cursors — which is almost certainly why it's safe. **Do not restructure the
  splice to "fix" it.** If the spinner returns after a density change, the
  cheap diagnostic is to append with the *template edge's* cursor left
  untouched and see whether the spinner clears; a real guard would be asserting
  the synthetic prefix never appears on a streamed (non-appended) edge.
- **Subframe injection.** Both user scripts are still injected with
  `forMainFrameOnly: false`, so every iframe installs its own body
  `MutationObserver` and runs the full `apply()` chain, none of which targets
  anything that lives in an iframe. `installSSRFeedSplice()` now has a
  top-frame guard (a subframe's `JSON.parse` is a different realm and can never
  see the streamed feed blocks); the rest was left alone because nothing proves
  no Instagram surface renders in a subframe. Next step: log frame URLs from
  the userscript on a real session for a few minutes; if only the top frame
  ever appears, flip to `forMainFrameOnly: true`.
- **Body-observer cost.** The observer watches `document.body` with
  `subtree: true` plus `class`/`style` attribute changes — very high-rate on a
  DM thread. It's throttled (`scheduleApply`, 300 ms, deferred past active
  touches) and the per-mutation work is cheap, but `apply()` itself runs ~20
  full-document passes. If scroll stutter shows up, narrow the
  `attributeFilter` or scope the observer to `main`.
- **`WebViewStore` lacks type-level `@MainActor`.** It mutates `@Published`
  state from `DispatchQueue.main` closures instead. Swift 5 language mode mutes
  the diagnostics; a Swift 6 migration would surface them. Not a concurrency
  migration to do casually.

---

## Housekeeping notes

- `ios/README.md` and `ios/project.yml` are stale (old fetch-filter approach,
  iOS 17). `docs/` supersedes them; consider updating or deleting them.
</content>
