# Changelog

All notable changes to this project are documented here. Releases use the Xcode
`MARKETING_VERSION`; CI assigns TestFlight build numbers from the released
commit count and workflow attempt.

## [0.8.0] - 2026-08-21

### Added
- Direct message sending. One message per explicit tap through
  `POST /v1/direct/threads/{id}/messages`, metered as a write so the per-account
  hourly cap and new-account warm-up both apply. No auto-reply, batching, or
  scheduled send, and a failed send keeps the typed text instead of retrying.
- `sent_by_viewer` on direct messages, so chat bubbles align by author.

### Changed
- Complete UI overhaul matched to Instagram's iOS dark appearance: serif wordmark
  header, gradient-ringed stories tray, edge-to-edge feed posts with the standard
  action row, tap-to-advance story viewer, chat bubbles with a pinned composer,
  profile stats over a tight three-column grid, and capsule search fields.
- New `Theme.swift` holds every colour, font, and metric; surfaces no longer
  hard-code styling. `NativeViews.swift` was split into `AppShell`, `FeedScreen`,
  `MessagesScreen`, and `ProfileScreen`.
- The bottom bar is hand-built rather than `TabView`, which on iOS 26 renders a
  floating glass capsule instead of Instagram's flat edge-to-edge bar.

## [0.7.0] - 2026-08-21

### Added
- Authenticator (TOTP) sign-in. Save Instagram's setup key once and the backend
  derives the current 6-digit code locally on every login, with no SMS
  delivery, device-approval prompt, or manual code entry.
- `PUT /v1/auth/totp-seed` stores or clears the key. An invalid key is rejected
  before it is persisted rather than at the next login.

### Removed
- `POST /v1/auth/request-sms`, `POST /v1/auth/verify-sms`, and
  `POST /v1/auth/check-approval`, plus their native controls. SMS was never
  delivered for the test account, and the approval check could not work by
  design: a fresh password login creates a new unapproved challenge, so
  approving in the official app never completed it.

### Security
- The authenticator seed is Fernet-encrypted at rest alongside session and
  proxy data, and is never logged or returned by the API.

## [0.6.1] - 2026-08-21

### Fixed
- Forces Instagram's Bloks two-factor flow into SMS fallback mode instead of
  accepting its default official-app approval route when SMS was requested.
- Adds an explicit **I Approved in Instagram** completion path. After approving
  the transient request in the official app, users can check that approval once
  without discarding the pending verification context.

## [0.6.0] - 2026-08-21

### Added
- Explicit one-shot **Request One SMS Code** flow when Instagram advertises SMS
  for the current two-factor challenge.
- Passwordless SMS verification against the exact pending challenge, avoiding a
  second password login that could invalidate or replace the code context.

### Security
- Persists only the minimal SMS challenge identifier/context, Fernet-encrypted
  with a ten-minute expiry. Passwords and codes are never persisted.
- Rejects duplicate SMS requests while one context is pending and counts both
  requesting and verifying against the per-account login-attempt limit.

## [0.5.2] - 2026-08-21

### Fixed
- Verification and backup codes are now entered through a secure masked field.
  Password, verification-code, and proxy fields are cleared immediately after
  every submission so a failed login cannot leave secrets visible onscreen.
- A rejected two-factor attempt no longer reports only "credentials rejected."
  It asks the user to confirm the password and use a fresh authenticator, SMS,
  or unused backup code without echoing the submitted value.

## [0.5.1] - 2026-08-21

### Fixed
- Two-factor login no longer incorrectly claims Instagram sent a code. The
  backend now classifies Instagram's sanitized two-factor response as
  authenticator-app or SMS verification and surfaces method-specific guidance.
  Unknown flows point to authenticator, SMS, or backup codes without claiming
  Lillygram can send or retrieve them.

## [0.5.0] - 2026-08-21

### Added
- Fully native SwiftUI Home, Stories, photo/video posting, account-only Search,
  Profile, read-only Messages, Settings, authentication states, and isolated
  one-item playback for a Reel shared in a DM.
- FastAPI backend wrapping `instagrapi` 2.18.16 with typed REST models,
  Docker packaging, health endpoint, multipart uploads, and focused contract
  tests.
- Per-account encrypted session/device/proxy storage, hashed app tokens,
  account-local locks and challenge states, randomized pacing, durable hourly
  limits, three-day new-account write warm-up, and configurable stable proxies.

### Changed
- Favorites are now a local per-account allowlist over paginated timeline
  pages. Empty or failed filtering never falls back to algorithmic content.
- DMs are read natively, while replies hand off to Instagram. No DM write,
  batch action, auto-reply, or mass-messaging endpoint exists.
- CI and the TestFlight release gate now run backend safety contracts before
  building the native app.

### Removed
- All `WKWebView`, injected JavaScript/CSS, DOM selectors, response splicing,
  WebKit bridge/cookie/navigation recovery code, hidden feed harvesting,
  content rules, and the Node/jsdom userscript harness.

### Known limitations
- A production HTTPS backend and any residential/mobile proxies still require
  external deployment and provisioning.
- Unofficial private-API access can still trigger Meta challenges or account
  restrictions. No architecture can guarantee ban-free use.
- Current upstream response shapes and uploads still require verification with
  a designated test account before family accounts.

## [0.4.2] — 2026-08-11

### Fixed
- Preferences (star) button could disappear from the home header and never
  come back if a header-geometry check missed on a transient scroll/animation
  state. Button (re)attachment no longer depends on that check succeeding.
- Native top/bottom safe area was never actually forced to black for Stories
  and Reels (the `immersive` flag was tracked but never applied), and a
  background-color sampler kept running during an open viewer and could
  overwrite whatever color was showing with the viewer's own transient chrome
  color. Safe area now reliably pins to black while a Story/Reel viewer is
  open and restores the correct page color when it closes.
- Leaving a post's comments via the on-screen back arrow could reload the
  home page instead of returning to it. The back-arrow handler now drives the
  same-document history transition itself instead of depending on
  Instagram's own click handler still being attached.
- Saving a favorites change showed the update splash, dropped it onto stale
  content, then popped it back up before finally showing the correct
  favorites — caused by an extra, redundant home reload racing the real
  post-harvest reload. Removed the redundant reload so there's exactly one
  splash cycle per save.

## [0.4.1] — 2026-08-10

### Fixed
- Preferences tutorial's spotlight backdrop blurred the rest of the screen
  instead of just dimming it, making the surrounding Settings & Support
  content unreadable. It's now a plain dim (no blur) so the background stays
  legible while the current step is highlighted.

## [0.4.0] — 2026-08-10

### Added
- Interactive coach-mark tutorial for Settings & Support: on first open it
  spotlights "Report a Bug" and the new beta status row against a
  blurred/dimmed backdrop, explaining that the app is in beta and how to
  report issues. Replayable anytime via a new "Take the Tour" row.
- Beta status badge in Settings & Support's About section.
- Placeholder app icon: pink background with a bold white "L".

## [0.3.1] — 2026-08-10

### Fixed
- Swipe-right-to-go-back (e.g. leaving a DM thread) showed a ~1s white/blank
  flash before landing on the previous screen. Root cause:
  `allowsBackForwardNavigationGestures`'s built-in interactive gesture forces
  a full document reload when the swipe lands on a same-document
  (`history.pushState`) SPA history entry, which is exactly how Instagram's
  DM thread <-> inbox transition works. Replaced it with manual
  `UIScreenEdgePanGestureRecognizer`s that call `goBack()`/`goForward()`
  directly, which fire a same-document `popstate` with no reload.

## [0.3.0] — 2026-08-09

### Added
- GitHub Release-driven CI/CD: every release published from `main` is
  validated, archived, distribution-signed, uploaded to App Store Connect,
  and monitored until it is valid and available to Internal Testers.
- CI gates for release metadata, the injected JavaScript harness, an unsigned
  iOS simulator build, and archive-time bug-report configuration injection.

### Changed
- Formalized prompt classification and semantic release rules so fixes bump
  patch, features bump minor, breaking changes bump major, and non-runtime
  docs/tests/CI work does not create redundant TestFlight builds.

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
