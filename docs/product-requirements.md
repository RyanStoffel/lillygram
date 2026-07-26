# Product Requirements

This is the **contract** for BetterInstagram. The four requirements below are
**hard and non-negotiable.** A change that violates one is a bug, not a
trade-off. Each lists rationale and **acceptance criteria** that a future change
can be tested against.

## Product goal

A distraction-reduced Instagram that **feels like the official app**, minus the
surfaces that drive compulsive use (Reels discovery, algorithmic feed, content
search/Explore). The bar is: a friend picking up the phone should see something
indistinguishable from Instagram — until they go looking for the removed
features, which should read as *intentionally absent*, never *broken*.

Non-goals: feature parity with Instagram; supporting accounts the user is not
logged into; a web-browser-like experience.

---

## R1 — Favorites-only home feed

**The home feed shows ONLY posts from accounts on the user's official Instagram
Favorites list** (Instagram's real in-app "Favorites" feature — not a custom,
app-local list). Nothing else ever appears in the home feed: no algorithmic
"suggested" posts, no ads, no reels, no accounts the user hasn't favorited.

**Rationale.** The algorithmic home feed is the primary distraction surface.
Restricting it to a small, user-curated set converts Instagram from an infinite
feed into a "check in on people I care about" utility.

**Acceptance criteria**
- With favorites set, every post rendered in the home feed is authored by an
  account on the user's Instagram Favorites list.
- Zero algorithmic/suggested/ad/reel items render in the home feed.
- The live stories tray and the real Instagram header remain intact (this is a
  home-feed filter, not a different screen).
- Selection is driven by the user's **Instagram Favorites list**; the in-app
  onboarding picker must keep that list in sync (see `favorites-feed.md`).
- No infinite loading spinner; the feed renders its favorites and settles.

> **Status: currently the fragile centerpiece.** It has a working
> implementation and a history of regressions. See `favorites-feed.md` and
> `known-issues.md`.

---

## R2 — No Reels, with one exception

**Reels are blocked everywhere** — there is no Reels tab, no reels interleaved
in the home feed, and no reels surfaced through search or Explore.

**The single exception:** when a friend sends the user a reel in a DM, the user
can watch **that specific reel**. They must **not** be able to scroll from it
into more reels — playback of the sent reel only: no swipe-to-next, no "up next"
/ related reels, no reel chaining.

**Rationale.** Reels are the most engineered-for-compulsion surface. The DM
exception preserves normal social interaction (a friend sharing something)
without reopening the infinite-reels funnel.

**Acceptance criteria**
- No Reels entry point in navigation; `/reels/` and `/explore/` routes never
  render as reel surfaces (redirect/behave as home).
- No reel items appear in the home feed or in search/Explore results.
- A reel opened from a DM (permalink `/reel/<id>/`, `/reels/<id>/`, **or** the
  URL-less DM overlay viewer) plays normally.
- From that reel, swipe/scroll to the next reel is disabled; no related/next
  reels are reachable. Exiting back to the DM works normally.

---

## R3 — Account-only search

**Search can only be used to look up accounts/profiles.** No content results of
any kind: no posts, no reels, no hashtag feeds, no AI/"about this" summaries, no
Explore grid. Account/profile results only.

**Rationale.** Search-as-content-discovery is a second algorithmic funnel.
Restricting search to "find a person" keeps its social utility while removing the
browse/Explore behavior.

**Acceptance criteria**
- The search screen returns **account/profile** results only.
- No posts, reels, hashtag/place feeds, AI summaries, or Explore grid render on
  the search screen or its results.
- Tapping into search never lands on an Explore/browse surface.

> **Status: implemented (2026-07-21), pending on-device confirmation.** Explore
> entry points/routes are blocked, and search results are now filtered to
> accounts-only at the data layer (`filterSearchPayload()` in
> `ContentFilter.swift`, stripping posts/hashtags/places/AI blocks from search
> responses before render) with a DOM backstop as secondary defense. This
> could not be tested against real Instagram search traffic in this sandbox —
> the exact response key names are inferred, not captured live — so it is not
> yet claimed to fully close all four acceptance criteria until confirmed on
> device. See `known-issues.md` #3.

---

## R4 — Polished, fast, native-feeling

The experience must be **as close to the official Instagram app as possible** in
UI, performance, and UX — minus the removed features. Concretely:

- **Fast launch with preloaded content** — no long spinner on open; tabs feel
  instantly available.
- **No blurry previews** — reels/posts a friend sends in DMs show at
  full-quality (no upscaled thumbnails).
- **Smooth scrolling** — 60fps feed scrolling, no stutter from injected scripts.
- **No janky blocking artifacts** — no flash of blocked content before it's
  removed, no layout jumps/gaps where an element was stripped.
- **No visible shortcuts or hacks** — every blocked feature looks
  *intentionally absent*, not broken. No leftover empty containers, dead
  buttons, or half-removed UI.

**Rationale.** The whole value proposition collapses if the app feels like a
janky web wrapper. Polish is a feature, not a finishing touch.

**Acceptance criteria** — see [performance-and-ux.md](performance-and-ux.md),
which translates this requirement into measurable standards (launch-to-content
budget, zero flash-of-blocked-content, no layout shift, full-res DM media, 60fps
scroll) and the implementation techniques to meet them. R4 is considered met when
those standards are met.

---

## How these interact

- R1 (favorites feed) and R2 (no reels in feed) both act on the home timeline;
  the favorites splice must never reintroduce reels, and reel-stripping must
  never blank the favorites feed.
- R4 constrains *how* R1–R3 are implemented: a correct-but-janky block (flash,
  spinner, layout jump) fails R4 even if it satisfies R1–R3.
</content>
