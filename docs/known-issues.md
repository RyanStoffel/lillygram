# Known Issues & Regressions

Ordered by priority. Each has a status and a concrete next step. Update this file
as issues are fixed or found.

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

**Follow-ups.** Density (~2–3 posts) still open — see #2. Diagnostic logs
(`[favshape]`, `[edgediff]`, verbose `[feed]` census) can be trimmed now that the
cause is understood.

---

## 2. Favorites feed density ceiling (~3 posts)

**Requirement:** R1 (quality of). **Status:** open; blocked on a safe approach.

Instagram streams only ~3 posts into the favorites page HTML, and its favorites
pagination reports `has_next_page: false` (a cursor-replay attempt logged
`replayLoops=0`). So the harvest can't get more from that feed.

**Next step (safe).** Add a **separate data source**: fetch each favorite's own
recent profile media, filter to a recency window, and **append** to the spliced
connection — **without reordering** and **without duplicate ids** (the two things
that caused issue #1). Treat as a distinct, carefully-verified change; do not
bolt it onto the working path until #1 is confirmed stable.

---

## 3. Account-only search not enforced on results

**Requirement:** R3. **Status:** partially implemented.

Explore entry points and routes are blocked, but `fixSearchPage()` only adjusts
search *layout* — it does not filter search **results** to accounts-only, so
posts/hashtags/AI results can still appear.

**Next step.** Filter the search screen to profile results only: strip non-account
result sections (posts grid, hashtag/place rows, "for you"/AI blocks) via the
data layer (topsearch/Explore search responses) and/or a DOM pass, keeping only
`users`.

---

## 4. Cold-start reload flash

**Requirement:** R4 (P8). **Status:** mitigated, not eliminated.

On first launch the home tab loads, then reloads once after the favorites harvest
so the splice lands deterministically. `SplashView` masks this. If the harvest is
slow or fails, the splash falls back after ~20 s.

**Next step.** Reduce/remove the reload by making the first home paint wait on
cached favorites when available; keep the splash as the mask, not the fix.

---

## 5. App favorites ↔ Instagram favorites coupling (mutates the real list)

**Requirement:** R1 (side-effect). **Status:** by design, flagged.

The feed reflects Instagram's **server-side** Favorites list, so
`syncFavoritesToInstagram()` **writes the app's picks into the user's real
Instagram Favorites** (`set_besties`). There is no confirmed endpoint to *read*
the current list, so the sync only **adds** — pre-existing Instagram favorites
are not removed and may also appear in the feed.

**Next step.** Find a "list favorites" endpoint (devtools capture) to reconcile
(remove picks the user deselected); until then, document the side-effect in
onboarding copy.

---

## 6. Instagram-web fragility

**Requirement:** all. **Status:** inherent.

Everything rides Instagram-web internals — query friendly-names, rotating
`doc_id`s, the `xdt_api__v1__*` keys, DOM selectors, the streamed-HTML mechanism.
Any of these can change and silently break a feature. See the reference table in
[blocking-and-selectors.md](blocking-and-selectors.md) for what to re-capture.

**Next step.** When a feature silently stops working, re-capture the current
value from a live session (`[BI-DEBUG]` request logs / devtools) and update the
selector reference.

---

## 7. Distribution posture (not App Store viable)

**Requirement:** context. **Status:** accepted.

Wrapping Instagram, using private feed shapes, and mutating the favorites list
put this outside App Store review norms. It is a personal/side-load-class app.
No action unless distribution goals change.

---

## Housekeeping notes

- `ios/README.md` and `ios/project.yml` are stale (old fetch-filter approach,
  iOS 17). `docs/` supersedes them; consider updating or deleting them.
- `harvestCollectorScript` in `ContentFilter.swift` is currently unused (the
  pagination collector was removed) — safe to delete when convenient.
- `FloatingNavBar.swift` is dead code (excluded from the target).
</content>
