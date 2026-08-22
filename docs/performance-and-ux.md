# Performance and UX

R4 requires native behavior, not merely a successful request.

## Launch

- Render the launch surface immediately.
- Restore only `/v1/session` at launch.
- Do not fetch feed, Stories, search, profiles, or DMs until that surface opens.
- A missing backend URL or token lands directly on sign-in.

## Navigation

- Use persistent SwiftUI tab state.
- Do not recreate network clients with shared mutable state. `APIClient` is a
  small actor value per operation and the backend serializes per account.
- Preserve already-loaded tab content until an explicit refresh.

## Pagination

- Feed, profile media, thread lists, and messages request bounded pages.
- Never bulk-fetch an account history on app open.
- Loading another page is explicit and consumes the per-account read budget.

## Media

- Use `AsyncImage` for remote images.
- Retain one `AVPlayer` per visible native video view; pause it on disappearance.
- Only Story and isolated DM-Reel playback may autoplay.
- Never pre-create players for offscreen Reels or recommendation chains.

## Failure states

- Favorites filtering fails closed.
- Challenge, verification, and rejected-session states replace content with an
  explicit reconnect screen.
- A backend 409 refreshes account state once. It never resubmits Instagram
  credentials or repeats the failed upstream action.
- Empty content, network failure, and safety-limit exhaustion remain distinct
  user-visible states.

## Visual standards

- True black background and white primary text in dark mode.
- No web loading flashes, browser chrome, continuously repainting animations,
  decorative card stacks, or placeholder algorithmic content.
- Respect Dynamic Type and native accessibility labels.

## Verification

For every release:

1. Run `uv run --directory backend --extra test pytest -q`.
2. Build the simulator target with the command in `AGENTS.md`.
3. Launch the built app in Simulator and inspect the real sign-in/session surface.
4. Before claiming Instagram behavior, run the configured backend against a
   designated test account and verify logs contain no credentials, tokens, proxy
   URLs, or session dictionaries.
