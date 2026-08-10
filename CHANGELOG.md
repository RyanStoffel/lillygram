# Changelog

All notable changes to this project are documented here. Versions follow
`MARKETING_VERSION (CURRENT_PROJECT_VERSION)` from the Xcode project.

## [0.2.0] (build 5) — 2026-08-09

### Changed
- Replaced the `mailto:` bug-report flow with direct submission as a GitHub
  Issue on a new private `RyanStoffel/lillygram-bugs` repo. Reports now
  capture the reporter's name; a GitHub Pages dashboard
  (`ryanstoffel.github.io/lillygram-bugs`) lists them for private viewing.
  Also fixed a stale hardcoded "1.0 (1)" app-version string in the bug
  report form's System Information section.

## [0.2.0] (build 4) — 2026-08-09

### Changed
- Renamed the app from BetterInstagram to **Lillygram**, top to bottom: Xcode
  project/target/scheme, bundle id (`com.betterinstagram.app` ->
  `com.lillygram.app`), display name, GitHub repo
  (`RyanStoffel/better-instagram` -> `RyanStoffel/lillygram`), Pages URLs,
  in-app links, docs, and tooling.
- Switched code signing to `Automatic` (was a hardcoded `CODE_SIGN_IDENTITY`)
  for App Store Connect API-driven archiving.
- Fixed two dead `betterinstagram.app` legal links in the favorites-editor
  footer that were never updated when the working Privacy/Terms pages shipped.

## [0.2.0] (build 3) — 2026-08-09

First push of the working app to `main` (previously only planning docs).
Consolidates the `develop` and `feature/pre-release-polish` work.

### Added
- Favorites-only home feed via an SSR/XHR response splice (`docs/favorites-feed.md`).
- Reels blocking with the DM-shared-Reel exception (locked, non-chaining playback).
- Account-only search-result filtering.
- Two-way sync between in-app favorites picks and the real Instagram Favorites list.
- Feed watchdog + bounded auto-recovery + native retry screen (fail-safe instead of an infinite spinner).
- Theme-aware (light/dark) splash, error, and favorites-picker UI.
- Fast-click / haptic touch handling and native-feeling pull-to-refresh.
- `WKContentRuleList`-based static blocking for Explore/Reels nav chrome, layered in front of the JS/CSS blocking.
- Settings screen: Report a Bug, Privacy Policy, Terms of Service (hosted on GitHub Pages), reading the real bundle version instead of a hardcoded string.
- `tools/` jsdom validation harness for the injected userscript.
- Rebranded app icon set (removed Meta/Instagram-owned glyph and lockup assets, replaced with original artwork).

### Fixed
- Header logo stability, DM header/inbox centering, DM scroll-to-bottom.
- Cold-start reload flash and reel-pop transition jank.
- Several home-feed watchdog/reload loop regressions.

### Known limitations
See [`docs/known-issues.md`](docs/known-issues.md) — notably: the feed splice
is inherently coupled to Instagram's current GraphQL/SSR shape, and
distribution is self-hosted (not App Store) by design.

## [0.1.0] (build 2)

Initial working WKWebView client: home/search/direct/profile tabs, the
core favorites-splice feed filter, and Reels/Explore blocking.
