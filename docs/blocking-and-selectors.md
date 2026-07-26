# Blocking Rules & Selector Reference

How each removed/altered surface is enforced, and a reference of the fragile
Instagram-specific hooks that break when Instagram ships web changes. All of this
lives in `ContentFilter.swift` unless noted.

## Reels blocking (R2)

Reels are blocked at every layer because Instagram surfaces them through routes,
feed data, and DOM:

- **Routes.** `routeDecision()` sends `/reels/` and `/explore/` to home; enforced
  in the SPA `history` hook, the boot-time location guard, and the native
  `WKNavigationDelegate` (`blockedExactPaths = /reels, /explore`, matched only
  on Meta-family hosts — path-only matching also cancelled unrelated sites'
  `/reels`//`/explore` pages).
- **Feed items.** `isReelArticle(article)` detects reels by reel-permalink
  anchors (`a[href^="/reel/"]`, `a[href^="/reels/"]`) and clip SVG labels
  (`svg[aria-label="Clip"|"Reel"]`); `hideSponsoredAndReels()` hides them.
  `filterTimelineEdges()` / `feedMediaAllowed()` drop `product_type === 'clips'`
  and ad/injected items from feed responses. **Fixed (2026-07-21):**
  `hideSponsoredAndReels()`'s bare-anchor rule (hide any `a[href^="/reel/"]`
  not wrapped in an `<article>`) used to run unconditionally, so it also
  caught a friend's shared-reel card inside a DM thread (DM messages aren't
  `<article>`-wrapped) — directly undermining the R2 exception below. It's now
  skipped entirely on `/direct/` routes.
- **Chrome.** Injected CSS hides the Explore nav link (`a[href="/explore/"]`),
  the Reels nav link (`a[href="/reels/"]`), and the Reels tab icon
  (`svg[aria-label="Reels"]`). These three are also now covered by a
  `WKContentRuleList` (`BlockingRules.json`, compiled and added in
  `WebViewStore.compileContentRuleList()`) — a static, always-true
  `css-display-none` rule applied by WebKit's networking/rendering layer,
  off the main thread, before the page's own JS/CSS runs. This is
  **additive, not a replacement**: the CSS above is unchanged and remains the
  primary, unconditional mechanism; the content rule list is a defense-in-depth
  layer that fails silently (logged, not fatal) if compilation ever fails.

### DM single-reel lock (the R2 exception)

A reel opened from a DM plays, but reel-chaining is disabled:

- **Detection.** `isReelPermalink()` for `/reel/<id>/` `/reels/<id>/`, **and**
  `activeReelVideo()` for the URL-less DM overlay viewer (recognized by a
  near-fullscreen `<video>` — ≥85% width / ≥60% height — excluding home/stories).
  A geometry match alone is corroborated by `dmOverlaySignal()` — is the
  pathname under `/direct/`, or does the video sit inside a `[role="dialog"]`
  layer — but this is a failure guard, not a gate: if corroboration fails
  (only logged via `biLog`), the video is still treated as the DM reel
  viewer. A false positive (locking some other fullscreen video) is low-cost;
  a false negative would let reel-chaining slip through R2.
- **Locking.** `shouldLockScroll()` + `scrollLockContainer(video)` lock the
  viewer's own scroll/scroll-snap container; `installGestureLocks()` blocks
  touch/wheel/keyboard scrolling (comment sheets & inputs exempted);
  `preventNativeFullscreen()` suppresses the system player (which is its own
  scroll surface, and would restore swipe-to-next outside the DOM lock) —
  **scoped to the lock**: the `HTMLMediaElement`/`Element` fullscreen patches
  must still be installed once at document start, before Instagram captures its
  own references, but they delegate to the originals and only suppress while
  `shouldLockScroll()` is true, so stories/feed/post playback keeps working;
  `biPresentation` atomically disables the native scroll view and marks the
  viewer immersive; preloaded next reels are hidden reversibly (cleared when the
  lock releases); and SPA navigation from one reel permalink to a *different*
  one is swallowed. Back/exit stays untouched.

**DM share-card single tap (resolved and confirmed 2026-07-22).** Instagram Web
requires two taps on the same shared reel in both WKWebView and mobile Safari.
Live diagnostics established the actual cause and card shape: the first trusted
tap lands on an `IMG`/`DIV` and lazily arms or upgrades the card, while the
pre-open thread DOM contains no reel permalink at all (`reelAnchors=0`). This
ruled out permalink forwarding as the primary solution; disabling delayed
UIScrollView touches, adding `cursor: pointer`, and routing through an anchor
cannot fix a card whose actionable element does not exist yet.

`installDMReelClickRouting()` handles both card shapes. If a permalink exists,
it resolves the nearest unambiguous reel URL and routes directly. For the
device-confirmed URL-less shape, a stationary one-finger tap on a large DM media
card is allowed to reach Instagram first; after 120 ms, the handler verifies
that the route is unchanged and no reel overlay is active, hit-tests the same
screen coordinate again, and clicks the now-current element. This converts
Instagram's arm-then-activate sequence into one physical tap. Scrolls, avatars,
text messages, and inputs remain untouched. Confirmed by the user on simulator.
Runtime log: `[dm] activating URL-less card after first touch target=...`.

`webView.isInspectable = true` remains enabled in DEBUG builds for future live
DOM diagnostics.

**DM preview blur (2026-07-21, one concrete fix landed, needs on-device
verification).** `upgradeDirectPreviews()` fetches a higher-resolution
thumbnail via Instagram's own internal `/api/v1/oembed/` web endpoint (not the
public, since-deprecated Meta Graph API oEmbed product — a different,
still-functional endpoint) when a share card's image is too small for its
display size. Confirmed firing and swapping in a new image on-device, but
still blurry — likely because the fetch never passed `maxwidth`, so Instagram
returned its own (probably too-small) default thumbnail size. **Fix:** the
fetch now requests `&maxwidth=1080`; fail-safe (existing `.catch()`/`r.ok`
fallback is unchanged if the param is ignored or rejected). **Verify**: watch
the `[dm] upgraded preview ... oembedWH=...` log — if `oembedWH` is still
smaller than `displayW * dpr` even with `maxwidth=1080`, Instagram's internal
oembed endpoint caps below what this app needs, and the next idea (extracting
`image_versions2` directly from whatever endpoint delivers the DM thread's
initial message history — same JSON-scanning technique as
`ContentFilter.harvestScript` — since realtime/incoming shares may ride a
transport this app can't intercept) becomes worth building for real, not just
proposing.

## Search (R3)

- **Explore blocked.** Explore entry points and `/explore/` routes are blocked
  (CSS + route guards above).
- **Data-layer result filter (primary).** `filterSearchPayload()` recognizes
  any fetch/XHR response carrying a top-level `users` array (`looksLikeSearchPayload`)
  and strips known non-account keys (`hashtags`, `places`, `clips`, `medias`,
  `media_grid`, `reels`, `top_results`, `keyword_results`, `explore_grid`,
  `ai_agent_response`, `about_this_account`) plus non-account entries from a
  generic `sections` container (`filterSearchSections`), before Instagram's
  search UI renders — wired into the same choke points as the feed filter
  (`installFetchFilter`, `installXHRFilter`/`rewriteFeedText`), independent of
  `favoritesOn`/`__biNativeFavMode`. Search results are never SSR-streamed the
  way the home feed is, so there's no document-start `JSON.parse` block to
  hook here; the network-response rewrite is the equivalent choke point. Log:
  `[search] filtered search results to accounts-only (xhr)` / the `[fetch]`
  equivalent. ⚠️ **Assumption, not device-captured**: the key names above are
  inferred from the known topsearch shape below and general Explore/search
  conventions — re-capture and update if the `[search]` log never fires on a
  real query.
- **`fixSearchPage()`** fixes layout on `/explore/search` (hides the stray
  "Cancel", widens the input) and now also calls
  `hideNonAccountSearchResults()` — a **backstop only**: hides post/reel/
  hashtag/place links and stray "Tags"/"Places"/"Top" tab controls that slip
  past the data-layer filter above. Not the primary mechanism.
- Profile search used by onboarding hits
  `/api/v1/web/search/topsearch/?context=blended&query=…` (accounts extracted
  from `payload.users`) — the same `payload.users` shape the data-layer filter
  above keys off of for the main Search tab.

## Feed hygiene & chrome fixes

- `hideFeedNoise()` hides "Suggested for you / Suggested posts / Suggested reels
  / Reels" units. `filterArticle()` also hides `Sponsored`/`Ad` articles and (for
  R1) non-favorite authors on the home path.
- `fixHomeHeader()` centers the Instagram logo, injects the `#__bi_star_btn`
  favorites button on the left, and hides Instagram's feed-switcher **caret**
  sibling. ⚠️ Keep the **conservative** version (`logoBox.querySelectorAll('svg')
  .length === 1` guard + hide a tiny `<44px` caret sibling); an aggressive
  svg-hiding rewrite broke rendering.
- `currentPageBackground()` samples and composites Instagram's visible top-edge
  layers for each webview, including translucent header materials rather than
  falling through to the opaque black page underneath. Direct inboxes and
  conversations retain that color. Stories and
  confirmed reel viewers temporarily override only the native safe area to
  black via `biPresentation`; base-color reporting pauses while the viewer is
  open, so closing restores the cached color without a second DOM sample.
- `visibleCommentSheet()` recognizes both Instagram comment variants: a dialog
  with a visible comment input or `Comments` heading, and the mobile full-page
  view with both its top `Comments` heading and visible composer. While either is
  open, `biNav` hides the native tab bar. Detection runs through the throttled
  `apply()` pass rather than directly on every DOM mutation, and closing is
  confirmed after 250 ms so transient React rerenders cannot flicker the native
  bar. The full-page back arrow's default link navigation is cancelled during
  event capture without stopping propagation, so Instagram's own close handler
  can still run without a Home navigation and reload. Closing comments restores
  the tab bar.
- `fixDirectMediaQuality()` / `upgradeDirectPreviews()` swap DM share-card
  preview `<img>`s to their largest `srcset` candidate (R4: no blurry previews).

## Fragile hooks reference

These are Instagram-web internals. **They will break when Instagram updates**;
when a feature silently stops working, re-capture the current value from a live
session (via the `[BI-DEBUG]` request logs / browser devtools) and update.

| Hook | Current value / shape | Used for | Breaks when |
| --- | --- | --- | --- |
| Home feed query (friendly name) | `PolarisFeedTimelineRootV2Query` | identify + splice the home feed request | IG renames the query |
| Home feed `doc_id` | `37025692570410168` | (diagnostic) | rotates every few weeks |
| Pagination query | `PolarisFeedRootPaginationCachedQuery(_subscribe)` (`doc_id 27452620037680645`) | recognize infinite-scroll pages | rotates / renamed |
| Timeline connection key | `xdt_api__v1__feed__timeline__connection` (contains `feed__timeline`) | find `.edges` in responses / streamed HTML | IG renames the XDT key |
| Feed variant field | request var `"variant": "home"` | detect the home root request | schema change |
| Favorites list write | `POST /api/v1/friendships/set_besties/` (`module=favorites_home_list`, `source=audience_manager`) | sync app picks → IG favorites | endpoint/param change |
| Username → id | `GET /api/v1/users/web_profile_info/?username=…` → `data.user.id` | resolve favorites | endpoint change |
| Web App ID header | `X-IG-App-ID: 936619743392459` | private-API calls | rotated app id → 403 |
| Reel article markers | `a[href^="/reel/"]`, `svg[aria-label="Clip"\|"Reel"]` | detect reels in feed | DOM/label change |
| Logo / header | `svg[aria-label="Instagram"]` + nearest header container | center logo, inject star | header markup change |
| DM reel viewer | near-fullscreen `<video>` heuristic (≥85%/60% viewport), corroborated (not gated) by `/direct/` route or a `[role="dialog"]` ancestor | DM single-reel lock | viewer markup change; still heuristic — corroboration is a logged failure guard, not a filter, so it can't fully rule out misfires |
| Streamed feed markers | `RelayPrefetchedStreamCache`, `__bbox`, `feed__timeline` | harvest streamed edges | SSR mechanism change |
| Search response shape | `payload.users` (accounts) alongside `hashtags`/`places`/`clips`/`medias`/`media_grid`/`reels`/`sections`/etc. (assumed, not device-captured) | `filterSearchPayload()` strips non-account keys (R3) | IG renames/restructures search response keys — re-capture via `[BI-DEBUG]`/devtools if `[search]` never logs |

## Escaping gotcha

Every regex in these hooks lives inside a Swift string literal, so **backslashes
are doubled** (`\/` → `\\/`, `\s` → `\\s`). Validate edits by extracting the
string and running `node --check`.
</content>
