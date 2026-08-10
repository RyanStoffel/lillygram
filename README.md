# Lillygram

A SwiftUI iOS app that wraps the real `instagram.com` mobile site in
persistent `WKWebView`s — using your own Instagram login — and injects a
userscript-style JS/CSS layer that strips the compulsive-use surfaces:
algorithmic feed, Reels discovery, and content-search/Explore. **Goal: an
Instagram that still feels like the native app, minus the parts engineered to
keep you scrolling.** No private/native Instagram API, no jailbreak — the
same category of technique as a browser content blocker or userscript.

Current version: **0.2.0** (build 4). Pre-release; being prepared for
TestFlight (see [Status & known limitations](#status--known-limitations)).

## Inspiration

Lillygram exists because of my girlfriend, Lilly. She's the one who kept
wishing Instagram was just "the people I actually care about" — no Reels
funnel, no algorithmic feed, nothing pulling her in every time she opened the
app to check a friend's story. This app is my attempt to actually build that
for her: a favorites-only feed, no Reels rabbit hole, search that's just for
finding people. She's the inspiration for the whole project, and the app is
named after her.

## What it does

| Requirement | Behavior |
| --- | --- |
| **Favorites-only home feed** | The home feed shows only posts from accounts on your real Instagram Favorites list — no algorithmic suggestions, ads, or Reels. |
| **No Reels, with one exception** | Reels are blocked everywhere (no tab, no feed/search surfacing) except a Reel a friend sends you in DM, which plays without chaining into more Reels. |
| **Account-only search** | Search returns profile results only — no posts, hashtags, or Explore-style content discovery. |
| **Native-feeling polish** | Persistent webviews, fast launch, full-quality DM media, flash-free blocking, 60fps scrolling — the wrapper should never feel like a wrapper. |

See [`docs/product-requirements.md`](docs/product-requirements.md) for the
full, non-negotiable contract these behaviors are held to.

## How it works

One SwiftUI shell around four persistent `WKWebView`s (home, search, direct,
profile) sharing a single `WKUserContentController`, which injects one
JavaScript userscript at document-start into every page. The userscript
blocks Reels/Explore, splices your Favorites into the home feed by hooking
Instagram's own server-streamed response, filters search results, locks
DM-shared Reels from chaining, and reports state back to Swift over
`postMessage`. Zero third-party dependencies — pure SwiftUI + WebKit.

Full design: [`docs/architecture.md`](docs/architecture.md). The favorites
splice is the most complex and fragile piece — read
[`docs/favorites-feed.md`](docs/favorites-feed.md) before touching feed code.

## Build

`ios/Lillygram.xcodeproj/project.pbxproj` is hand-edited and
authoritative (iOS 26 deployment target). `xcodegen` is **not** used —
regenerating from `ios/project.yml` would drop the hand edits.

```sh
xcodebuild -project ios/Lillygram.xcodeproj -scheme Lillygram \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Test

There's no iOS test target. The injected JS is validated with a jsdom
harness that extracts the userscript from `ContentFilter.swift`, syntax-checks
it, and asserts initialization reaches `MutationObserver.observe()`:

```sh
cd tools && npm install && npm test   # ./check.sh
```

Run this after every `ContentFilter.swift` edit — `node --check` alone can't
catch an init-time throw, which silently disables the whole filter. Runtime
behavior against real Instagram is otherwise only confirmed on
device/simulator via the `[BI-DEBUG]` / `[BI-harvest]` console logs.

## Project layout

```
ios/                    SwiftUI app (Lillygram.xcodeproj)
  Lillygram/
    ContentFilter.swift   the injected userscript (all web-side behavior)
    WebViewStore.swift    owns the webviews, bridge handlers, favorites sync
    ContentView.swift     root TabView, splashes, onboarding
    FavoritesStore.swift  UserDefaults-backed favorites selection
tools/                  Node/jsdom harness that validates ContentFilter.swift
docs/                   source of truth — architecture, requirements, known issues
```

## Documentation

Start with [`docs/README.md`](docs/README.md), which indexes:

- [`product-requirements.md`](docs/product-requirements.md) — the 4 hard requirements + acceptance criteria
- [`architecture.md`](docs/architecture.md) — system design
- [`favorites-feed.md`](docs/favorites-feed.md) — the favorites splice
- [`blocking-and-selectors.md`](docs/blocking-and-selectors.md) — blocking mechanics + fragile Instagram selectors
- [`performance-and-ux.md`](docs/performance-and-ux.md) — measurable native-feel standards
- [`known-issues.md`](docs/known-issues.md) — regressions and open problems
- [`audit.md`](docs/audit.md) — best-practice scorecard against the current build

## Status & known limitations

Pre-release, self-hosted (not on the public App Store — a reverse-engineered
feed splice against Instagram's private GraphQL/SSR responses isn't a good
fit for full App Store review; see `docs/known-issues.md` #8). Being
distributed to a small group of testers via TestFlight instead. In brief:

- Favorites feed, Reels blocking, and favorites-list sync are implemented and
  device-confirmed.
- Account-only search filtering is implemented but pending full on-device
  verification against live Instagram search traffic.
- The feed splice is inherently fragile — it depends on Instagram's current
  GraphQL/SSR shape and can break when Instagram changes it. It fails safe
  (watchdog + retry + a native error screen) rather than spinning forever.

Full detail in [`docs/known-issues.md`](docs/known-issues.md).

## Versioning

Semantic versioning (`MARKETING_VERSION` in the Xcode project);
`CURRENT_PROJECT_VERSION` is the build number, bumped on every release.
Changes are tracked in [`CHANGELOG.md`](CHANGELOG.md).

## License

[MIT](LICENSE)
