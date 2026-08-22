# Favorites Feed

## Contract

Home is a local allowlist over Instagram timeline pages. It is not a custom
ranking system and it does not attempt to mutate Instagram's official Favorites
list.

`FavoritesStore` persists `[ProfileSummary]` under a key namespaced by the
backend account UUID. Switching accounts immediately swaps the active allowlist;
selections can never leak from one account into another.

## Data flow

1. Home refuses to request a timeline when no favorites are selected.
2. The backend fetches one timeline page for the authenticated account.
3. `instagram.py` drops all media recognized as Reel products.
4. The backend returns the remaining page and its next cursor without sorting.
5. `AppStore` applies a second Reel exclusion and retains only authors whose
   lowercase username is in `FavoritesStore.usernames`.
6. SwiftUI renders only that final list.

An empty filtered page is expected when none of the selected accounts appear in
that timeline page. The UI may request the next page explicitly. It never shows
unselected items to fill space.

## Invariants

- Never sort, reorder, synthesize, or duplicate media.
- Never fall back to the unfiltered page.
- Never use a favorites list from another backend account ID.
- Never render a Reel even if its author is selected.
- Treat missing authors, unknown media shapes, and conversion failures as
  non-renderable.
- Keep pagination user-driven and bounded by the per-account read cap.

## Differences from the retired WebView implementation

The old app harvested Instagram's web Favorites page, intercepted streamed JSON,
spliced Relay edges, synchronized the official Favorites list, and used DOM
hiding as a final backstop. All of that code was deleted. The native contract is
smaller: stable REST media models plus an exact local author allowlist.
