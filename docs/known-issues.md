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
