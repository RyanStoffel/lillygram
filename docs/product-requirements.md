# Product Requirements

These four requirements are hard and non-negotiable. A change that violates one
is a bug, not a trade-off.

## Product goal

A distraction-reduced Instagram client that preserves deliberate social actions
without exposing algorithmic discovery surfaces. Lillygram is intentionally not
feature-complete Instagram.

## R1: Favorites-only Home

Home shows posts only from the accounts selected by the current user in
Lillygram. Instagram does not provide a stable private-API Favorites feed
endpoint, so selection is local and namespaced to the authenticated account.

Acceptance criteria:

- Every Home post is authored by a selected account.
- No ad, suggested post, Reel, or unselected account is rendered.
- Instagram timeline order is preserved. Lillygram never sorts or synthesizes
  timeline order.
- Pagination fetches one page at a time.
- Empty selection, an empty filtered page, or an upstream failure fails closed.
  Algorithmic content is never shown as a fallback.

## R2: No Reels, with one exception

There is no Reels tab, Reel feed, Reel search, Reel profile grid, Reel creation,
or algorithmic Reel surfacing.

The only exception is one Reel attached to a direct message. That specific item
may open in a self-contained native player.

Acceptance criteria:

- Timeline and profile-media conversion remove Reel products before returning
  native models.
- Search has no Reel endpoint or result type.
- A DM Reel opens only when the message model marks it as a shared Reel.
- The player has no next item, swipe-to-next, recommendation, related content,
  or route into a Reel surface.
- Closing the player returns to the originating message thread.

## R3: Account-only search

Search finds Instagram accounts and nothing else.

Acceptance criteria:

- The backend exposes only `/v1/search/accounts` for search.
- Native search renders `ProfileSummary` results only.
- No post, Reel, hashtag, place, AI summary, or Explore result type exists in the
  search contract.

## R4: Polished, fast, native-feeling

Every shipped screen is native SwiftUI. There is no `WKWebView`, injected
JavaScript, DOM filtering, or browser chrome.

Acceptance criteria:

- Tabs preserve their state and do not bulk-fetch unopened surfaces at launch.
- Feed, profile media, and messages paginate rather than loading entire account
  histories.
- Media uses native `AsyncImage` and `AVPlayer` surfaces.
- Loading, empty, challenge, reconnect, and upstream-failure states are explicit.
- The app uses true black in dark mode and does not flash unfiltered content.
- A backend or private-API failure never weakens R1 through R3.

## Supported deliberate actions

Lillygram additionally supports viewing and posting Stories, creating individual
photo/video feed posts, viewing profiles, reading DMs, and settings/account
controls. Posting and story uploads remain low-frequency, user-initiated actions.
DM replies hand off to Instagram because unofficial DM writes are higher risk.
