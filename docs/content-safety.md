# Content Safety

Lillygram no longer blocks web content with selectors. Safety is enforced by the
REST surface, backend model conversion, and native rendering rules.

## Defense in depth

1. **No discovery routes.** The backend has no Explore, hashtag, place, media
   search, Reel feed, recommendation, or related-content endpoint.
2. **Backend conversion.** Timeline and profile-media converters drop products
   marked `clips`, `reels`, or `reel`.
3. **Client backstop.** Home and profile grids reject `MediaKind.reel` again.
4. **Exact favorites allowlist.** Home requires a selected lowercase username.
5. **Typed shared-Reel exception.** A Reel player is reachable only from a DM
   message whose converted media is both `.reel` and `sharedReel == true`.
6. **Fail closed.** Unknown and incomplete media models are not rendered.

## Search

Only account search exists. Adding a new search result type requires changing the
backend API contract and is therefore a product review point, not a UI selector
change.

## DMs

Threads and messages render natively, and one message can be sent per explicit
tap through `POST /v1/direct/threads/{id}/messages`. Sending is metered as a
write, so the hourly cap and new-account warm-up both apply, and a failure never
retries on its own. There is no auto-reply, scheduled send, batch send, or
mass-messaging path.

## Writes

Feed posts and Stories are one-at-a-time multipart requests. Both require the
account warm-up period and consume the same durable write budget. No scheduled,
batch, auto-reply, auto-like, follow, or mass-action API exists.
