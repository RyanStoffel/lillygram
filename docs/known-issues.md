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

## 5. Sync custom (app) favorites → official Instagram Favorites list

**Requirement:** R1. **Status:** two-way reconcile implemented, pending on-device
verification of the read endpoint.

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

**UI caveat.** The star badge / "Remove from favorites" menu on density-appended
posts renders from OUR spliced media JSON (null-filled friendship data), so its
absence there does NOT indicate server state — verify in the official Instagram
app/web instead.

**Triggers.** The sync runs (a) when picks are applied in the favorites editor
and (b) **once per launch** after the home tab finishes loading, so a
failed/partial sync self-heals on boot; if the launch sync wrote changes it
re-harvests so the feed follows.

**Verify on device.** After changing picks (or just relaunching), `[BI-sync]`
should log `wrote favorites add=N ok=N confirmed=N … cleanedCF=K` (or `already
in sync`). `confirmed < add` means the favorite/ endpoint is being rejected —
capture the web chevron's request in devtools. `NOT-FOLLOWED` names picks that
need a follow first. Remove-side reconcile (unfavoriting deselected picks) is
still open: the bulk list-read endpoints reject the web UA
(`400 useragent mismatch`), so there is no way yet to enumerate server-side
favorites that are not current picks.

**Note.** The sync intentionally mutates the user's real Instagram Favorites
(including removing entries deselected in-app); this side-effect should be
stated in onboarding copy.

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
