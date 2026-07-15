# The Favorites-Only Home Feed

This is the hardest, most fragile part of BetterInstagram and the subject of the
current regression. Read this before touching anything that produces, orders, or
splices favorites edges. It implements **R1**.

## The core problem

Instagram's home page renders in a "mode" fixed at load. A home-mode client
**cannot** render favorites-mode feed data (it spins), and the favorites page
(`/?variant=favorites`) is a stripped sub-page with **no live stories tray** and
a "← Favorites" header. We want the **real home page** (live stories + real
header + native story open/close) but with **only favorites' posts** in the
feed. So we keep the real home page and **swap the feed data underneath it.**

## The pipeline (6 steps)

1. **Sync app picks → Instagram's server Favorites list.**
   `WebViewStore.syncFavoritesToInstagram()` resolves each picked username → user
   id (`GET /api/v1/users/web_profile_info/?username=…`, id at `data.user.id`)
   and writes the set into Instagram's server-side Favorites ("besties") list via
   `POST /api/v1/friendships/set_besties/`
   (`module=favorites_home_list&source=audience_manager&add=<JSON ids>&remove=[]`,
   headers `X-IG-App-ID: 936619743392459` + `X-CSRFToken` from cookie). This is
   what makes R1 read from the **official** Favorites list. Native log:
   `[BI-sync] set_besties status=200 synced=N/N`.

2. **Harvest the favorites feed in a hidden webview.**
   `WebViewStore.harvestFavorites()` loads `https://www.instagram.com/?variant=favorites`
   in a hidden offscreen `WKWebView` (attached off-screen to the key window so
   WebKit fully processes it; shares cookies via the default data store). A real
   **navigation** is the only thing that makes Instagram stream the favorites
   feed into the page HTML — a plain `fetch()` of that URL returns only the app
   shell (no feed data).

3. **Extract streamed edges.** On the hidden webview's `didFinish`,
   `ContentFilter.harvestScript` runs (`callAsyncJavaScript`). It walks every
   `<script>` block of the page HTML, finds the timeline connection
   (`xdt_api__v1__feed__timeline__connection`, key contains `feed__timeline`),
   and returns its `edges` **unmodified, in Instagram's original order**, as
   JSON. Log: `[BI-harvest] count=N markers={conn,ft,relay,bbox}`.

4. **Deliver to the home tab.** Native caches the JSON and pushes it to the
   visible webviews via `window.__biSetFavEdges(payload)`. It also reloads the
   home tab once after the first successful harvest so the (now cached) splice
   lands deterministically. The home tab **holds** its feed request until the
   edges arrive (`prefetchFavoriteEdges()` waiter, ~10s timeout).

5. **Splice with lazy getters.** In the home tab, `installLazyRewrite()` (called
   from the patched `XMLHttpRequest.prototype.open`) installs **lazy getters** on
   the feed XHR's `responseText`/`response`. On first read at `readyState 4` it
   computes the rewrite once: `spliceFavoriteEdges()` replaces the timeline
   connection's `.edges` with the favorite edges and sets
   `page_info.has_next_page = false`. **Lazy getters are load-bearing:**
   Instagram reads `responseText` from its *own* `onreadystatechange`, which
   fires *before* a `readystatechange` listener we could add — so a listener-
   based rewrite is read too late and never renders. The lazy getter is computed
   on whoever reads first. Log: `[favsplice] swapped favorites into home response`.

6. **DOM fallback filter.** The home page also **server-streams a few
   algorithmic posts into its HTML** that never pass through the XHR splice.
   `filterArticle()` (run from `apply()` and the `MutationObserver`) hides any
   home-feed article whose author is not in `favSet` (app picks) **or**
   `favAuthors` (authors of the harvested favorites). Unknown authors are left
   alone so a real favorite is never hidden by a failed lookup.

## The SSR splice (load-bearing — this is what actually renders favorites)

Instagram **server-streams the home feed into the page HTML** (`<script
type="application/json" data-sjs>` RelayPrefetchedStreamCache blocks) and renders
the **initial** feed from that streamed data — **not** from the feed XHR. So the
XHR splice above (steps 5–6) lands in a response nothing renders from; on its own
the feed shows Instagram's algorithmic accounts, which `filterArticle` then hides
→ infinite spinner.

`installSSRFeedSplice()` fixes this: it hooks the global `JSON.parse` at
document-start, and for any parsed object containing a `feed__timeline`
connection it replaces `.edges` with the harvested favorites (`sanitizeFavEdges`
applied) and sets `page_info.has_next_page = false` **before Relay hydrates**.
Instagram's bootloader parses the streamed blocks with `JSON.parse`, so this
catches the initial SSR render and Instagram renders favorites natively (stories
tray intact). The harvested edges must be available **synchronously** at
document-start, so native injects them as the preamble global
`window.__biFavEdgesPreload` (`WebViewStore.installUserScripts` when
`cachedFavEdgesJSON` exists; `harvestExtract` re-installs scripts before the
post-harvest home reload). The XHR splice stays for infinite-scroll pages. Logs:
`[favsplice] SSR feed splice armed (N edges)` / `spliced favorites into SSR feed
data`.

## Two home-feed modes (splice vs. native favorites)

Instagram's home feed switcher (home ↔ Favorites) is **persisted server-side**,
so the home page can issue its root feed query (`PolarisFeedTimelineRootV2Query`)
as **either** `variant=home` or `variant=favorites`. Both use the same
`doc_id`/friendly-name.

- **`variant=home`** — the algorithmic feed. This is the case the splice was
  built for: hold the request, then swap in favorite edges (pipeline above).
- **`variant=favorites`** — IG is serving the favorites feed **natively**. Do
  **NOT** splice: re-serializing/overwriting a native favorites response makes
  IG's Relay renderer throw (`[jserr] Script error.`) and the feed hangs on the
  spinner. `feedVariant()` detects this in `installXHRFilter`'s `send`; the first
  favorites-variant request sets `window.__biNativeFavMode`, which makes the
  lazy rewrite pass every feed response through untouched **and** stands the DOM
  author-filter down (every post is already a favorite). Syncing besties can flip
  a session into this mode — which is why a code revert alone won't restore the
  splice path if IG has switched the home feed to Favorites server-side.

## Invariants (violate these and the feed breaks)

The first two invariants are now **enforced in code** by `sanitizeFavEdges()`,
which runs at the single choke point (`__biSetFavEdges`) where harvested edges
enter the live feed: it keeps only `node.media` posts, strictly de-dupes by
`media.pk||id||code`, and preserves incoming order (never sorts). It does not
license reordering upstream — order still has to arrive correct — but it stops
duplicate/non-post edges from ever reaching the splice.

- **NEVER reorder / sort the spliced edges.** A Relay feed connection requires
  edges in their original **cursor order**. Sorting (e.g. by `taken_at`) or
  re-arraying breaks cursor monotonicity and Instagram's Relay renderer **hangs
  on the infinite loading spinner** — the swap log succeeds but nothing renders.
- **NEVER put duplicate media ids in the connection.** Duplicate edges hang
  Relay the same way. If you ever merge multiple sources, de-dupe strictly by
  `media.pk || media.id || media.code` and keep only real posts (`node.media`).
- **Keep the lazy-getter splice.** Do not "simplify" it back to a
  `readystatechange` listener — that reintroduces the read-ordering bug.
- **Keep the request as `variant=home`.** We do not flip the outgoing request to
  favorites; we swap the *response*. (See dead-ends.)

## Dead ends (do not retry — each was verified broken)

- **Request rewrite (flip `variant` home→favorites in the outgoing body).**
  Server ignores it and returns the algorithmic feed; the home request's only
  feed field is `variant`. Referrer spoofing didn't help either.
- **Synthesizing / hand-building timeline edges.** Instagram's bundled Relay
  renderer throws (surfaces only as a cross-origin `Script error.`). Matching the
  media shape field-for-field did not help.
- **`fetch('/?variant=favorites')`** — returns the app shell only
  (`markers conn=0 feed__timeline=0`); feed data streams only on real navigation.
- **Client-side author-filter of the algorithmic feed** (no splice) — too sparse;
  favorites rarely appear in the algo feed.
- **Self-rendered custom DOM feed** — not native; janky.
- **Loading `/?variant=favorites` as the visible page** — shows correct
  favorites but strips the stories tray and shows a "← Favorites" header; copying
  Instagram's stories markup loses its JS handlers.
- **Reorder/dedupe-less pagination merge** — the current regression (spinner).

## Density ceiling

The harvest returns only **~3 posts** — everything Instagram streams into the
favorites page HTML on first load. Its own pagination reports
`has_next_page: false` for that feed, so scrolling/replaying the favorites
pagination does not reliably yield more (a cursor-replay attempt logged
`replayLoops=0`). To show a fuller feed (e.g. a month of every favorite's posts)
the only viable path is a **different data source** — fetch each favorite's own
recent profile media and append it — and it must be appended **without ever
reordering** the connection and **without duplicate ids**. Not yet built.

## Files & symbols

- Native: `WebViewStore.syncFavoritesToInstagram()`, `harvestFavorites()`,
  `harvestExtract()`, `deliverFavEdges()`, `didReloadHomeForFavorites`,
  `cachedFavEdgesJSON`.
- Web (`ContentFilter.swift`): `harvestScript`, `installLazyRewrite()`,
  `rewriteFeedText()`, `sanitizeFavEdges()`, `spliceFavoriteEdges()`, `extractTimelineEdges()`,
  `edgeAuthors()`, `window.__biSetFavEdges`, `prefetchFavoriteEdges()`,
  `filterArticle()` / `articleAuthor()`, `favSet` / `favAuthors`.
- App selection: `FavoritesStore`, `OnboardingView` (`FavoritesPickerView`).

## Known coupling / caveat

The feed reflects Instagram's **server-side** Favorites list. The app's
onboarding picks drive it only because `syncFavoritesToInstagram()` writes them
into that list — which **mutates the user's real Instagram Favorites**. There is
no confirmed endpoint to *read* the current server list, so the sync currently
only **adds** picks; pre-existing Instagram favorites are not removed and could
also appear. See `known-issues.md`.
</content>
