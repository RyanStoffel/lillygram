# Native Migration Assessment

## Assessment of the retired app

The previous iOS target was a SwiftUI shell around four persistent
`WKWebView`s, plus a fifth temporary harvest webview.

- `ContentView.swift` owned the tab shell, splashes, onboarding, and WebView
  presentation.
- `WebViewStore.swift` coordinated WebKit configuration, cookie-based login
  detection, navigation policy, recovery, script messages, favorites harvest,
  and Instagram web requests.
- `ContentFilter.swift` contained roughly 3,000 lines of injected JavaScript and
  CSS for DOM blocking, network interception, SSR/XHR feed splicing, selector
  repairs, and shared-Reel locking.
- `WebBridge.swift`, `WKWebView+NoAccessory.swift`, and `BlockingRules.json`
  existed only to support WebKit.
- `FavoritesStore.swift` persisted a local picker, while
  `OnboardingView.swift` also contained native settings and bug reporting.

The reusable pieces were product contracts, native assets, the selected-profile
model, the bug reporter, release tooling, and the account-change principle that
account-derived state must reset. Web cookies were not a reusable backend
session model.

## Deleted

- Every `WKWebView` and WebKit import.
- Injected JavaScript/CSS, selectors, MutationObserver logic, content rules,
  XHR/fetch/JSON interception, Favorites edge harvesting, density synthesis,
  official-Favorites mutation, web navigation recovery, and message handlers.
- The Node/jsdom userscript harness and its CI job.
- Web-only tutorial/bridge/accessory files and stale WebView research docs.

## Ported forward

- The four non-negotiable product rules, updated for native data models.
- Per-account selected profiles, now correctly namespaced by backend account ID.
- Native settings/legal links and direct GitHub bug reporting.
- Existing app icon and assets.
- Fail-closed Home and isolated DM-shared-Reel behavior.
- Release metadata validation and TestFlight deployment workflow.

## Rebuilt

- Native SwiftUI Home, Stories, post/story composers, account-only Search,
  Profile, read-only Messages, Settings, authentication states, and one-item
  shared-Reel playback.
- A typed HTTPS client with Keychain bearer-token storage.
- FastAPI backend with encrypted per-account `instagrapi` settings, stable device
  identity, optional stable proxy, account locks, durable rate budgets, random
  pacing, warm-up, and challenge isolation.
- Backend contract tests and CI gates.

## Deferred or externally blocked

- **Backend hosting:** no provider, domain, or production URL was supplied. The
  Dockerized service and configurable client URL are complete; deployment is an
  operator step.
- **Proxy provisioning:** per-account configuration is complete. Purchasing and
  validating distinct residential/mobile proxies is external.
- **DM sending:** intentionally deferred. Lillygram reads DMs and hands replies
  to Instagram rather than exposing a risky private-API write endpoint.
- **Automatic challenge resolution:** intentionally not implemented. The account
  freezes and the user verifies through Instagram.
- **Live-account verification:** no Instagram credentials were available in this
  environment. Library signatures and mocked contracts are verified, but a
  designated test account must validate current upstream response shapes and
  uploads.

## Risk statement

No technical design can make unofficial private-API access ban-proof. This
migration minimizes avoidable risk and makes failures account-local, but it does
not convert an unsupported Instagram integration into a supported one.
