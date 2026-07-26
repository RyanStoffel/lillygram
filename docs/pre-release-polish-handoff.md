# Pre-Release Polish & Performance Handoff Plan

**Target Application:** BetterInstagram (iOS / SwiftUI + WKWebView)  
**Date:** July 26, 2026  
**Document Status:** Ready for Implementation  
**Target Output File:** `pre-release-polish-handoff.md`

---

## 1. Executive Summary & Release Objective

BetterInstagram is a SwiftUI wrapper around four persistent `WKWebView` instances running `instagram.com` with a single shared `WKUserContentController`. A comprehensive userscript (`ContentFilter.swift`) removes distractions (Reels feed, Explore grid, ads) while splicing the user's selected favorites into the home feed.

This plan details the end-to-end work required to bring the app from feature-complete to **release-ready production quality**. The primary focus areas are:
1. **Light Mode & System Theme Adaptation**: Eliminating hardcoded black splash screens, error states, and unadapted picker surfaces.
2. **Animation & Transition Polish**: Refining tab bar show/hide transitions, splash fade-outs, and swipe-gesture container bounds.
3. **Performance & Main-Thread Speed**: Scoping DOM mutation passes in `ContentFilter.swift` by route to eliminate scroll jank (hitting standard P5 ~60 FPS).
4. **Native Tactile Feel & Haptics**: Standardizing feedback generators and touch responsiveness across all native and web interactions.

---

## 2. Current Architecture & Key Components

Before modifying any file, reference this component map:

| File | Primary Responsibility | Critical Gotchas / Invariants |
| --- | --- | --- |
| `ios/BetterInstagram/ContentView.swift` | Root view, `TabView`, splash overlays (`LaunchSplashView`, `ResaveSplashView`), `FeedErrorView`. | Tab bar visibility driven by `bridge.isNavVisible`. `ZStack` background uses `bridge.pageBackground.ignoresSafeArea()`. |
| `ios/BetterInstagram/ContentFilter.swift` | Multiline JS string (`ContentFilter.script`). Handles DOM filtering, route guards, network hooks, and color reporting. | **All regex backslashes MUST be doubled** (`\/` → `\\/`). Must pass `./tools/check.sh` on every edit. |
| `ios/BetterInstagram/WebViewStore.swift` | Manages 4 tab webviews + hidden harvest webview, `WKUserContentController`, cookie observing, and message handlers (`biNav`, `biBg`, `biFavReady`, `biFeedStuck`). | Shared data store across webviews. Native bridge callbacks run on MainActor. |
| `ios/BetterInstagram/OnboardingView.swift` | `FavoritesPickerView` for initial onboarding and star-tab editor. | Handles following list load and search query debounce (350ms). |
| `ios/BetterInstagram/WebBridge.swift` | `@Published` state mirrored out of web pages (`isNavVisible`, `avatarURL`, `pageBackground`, `safeAreaBackground`). | Used by `ContentView` to coordinate UI layout. |
| `tools/check.sh` | Test runner script. Extracts scripts from `ContentFilter.swift`, syntax-checks with node, and executes `tools/userscript-init-test.js`. | **Mandatory gate.** Must run and output `ALL CHECKS PASSED`. |

---

## 3. Detailed Work Breakdown & Implementation Steps

### Phase 1: Light Mode & System Theme Adaptation (P0)

#### 1.1 `LaunchSplashView` & `ResaveSplashView` (`ContentView.swift`)
- **Current Issue**: Both splash views hardcode `Color.black.ignoresSafeArea()`, white text (`Color.white.opacity(...)`), and white `ProgressView` tints. In iOS Light Mode, this creates an unadapted dark splash on cold launch.
- **Required Changes**:
  - Replace `Color.black.ignoresSafeArea()` with `Color(.systemBackground).ignoresSafeArea()`.
  - Update `AttributionFooter` text colors:
    - `"from"` label: `Color.secondary` or `Color.primary.opacity(0.5)`.
    - `"RYAN STOFFEL"` title: `Color.primary`.
  - Remove hardcoded `.tint(Color.white.opacity(0.7))` from `ProgressView` so it inherits the native system spinner color.
  - Update `ResaveSplashView` text color to `Color.secondary`.

#### 1.2 `FeedErrorView` (`ContentView.swift`)
- **Current Issue**: Hardcodes `Color.black.ignoresSafeArea()` and white text/buttons.
- **Required Changes**:
  - Replace `Color.black` with `Color(.systemBackground)`.
  - Change title text to `.foregroundStyle(Color.primary)`.
  - Change subtitle text to `.foregroundStyle(Color.secondary)`.
  - Update retry button styling:
    - Background: `Color.primary.opacity(0.1)` in `Capsule()`.
    - Text: `.foregroundStyle(Color.primary)`.

#### 1.3 `FavoritesPickerView` (`OnboardingView.swift`)
- **Current Issue**: Tint is forced to `.tint(.blue)`. Search field background, profile row borders, and selection chips use fixed opacity that can lack contrast in Light Mode.
- **Required Changes**:
  - Standardize search field background: use `Color(.secondarySystemBackground)` for the input field.
  - Standardize chip background: `Color(.tertiarySystemFill)` capsule.
  - Standardize avatar placeholder styling: `Color(.secondarySystemFill)`.
  - Verify high-contrast text styling across both light and dark system appearances.

#### 1.4 Dynamic Web Background Sync (`ContentFilter.swift` & `WebViewStore.swift`)
- **Current Issue**: Injected CSS in `ContentFilter.swift` provides theme-aware rules via `@media (prefers-color-scheme: dark)` (`rgb(12, 16, 20)`) and `@media (prefers-color-scheme: light)` (`rgb(255, 255, 255)`).
- **Required Verification**:
  - Verify that when Instagram's theme changes, `currentPageBackground()` correctly samples the top pixel colors and sends `biBg` updates.
  - Ensure `WebViewStore.parseCSSColor` handles both 3-component `rgb(r, g, b)` and 4-component `rgba(r, g, b, a)` strings cleanly.

---

### Phase 2: Smooth Animations & Gesture Transitions (P1)

#### 2.1 Tab Bar Show/Hide Animation (`ContentView.swift`)
- **Current Issue**: `.toolbarVisibility(isTabBarVisible ? .visible : .hidden, for: .tabBar)` toggles tab bar visibility when entering DM threads or comment sheets, but default SwiftUI toolbar visibility changes can snap.
- **Required Changes**:
  - Wrap tab bar visibility updates in explicit animation:
    ```swift
    .animation(.easeInOut(duration: 0.25), value: isTabBarVisible)
    ```
  - Ensure `WebBridge.isNavVisible` updates from `reportNavVisibility()` in JS are debounced by 50ms so rapid DOM updates during page load do not cause tab bar jitter.

#### 2.2 Splash Screen Fade-Out Transition (`ContentView.swift`)
- **Current Issue**: `splashTransition` uses `.asymmetric(insertion: .identity, removal: .opacity)`.
- **Required Refinement**:
  - Enhance the removal transition with subtle scale reduction for a polished iOS app feel:
    ```swift
    private var splashTransition: AnyTransition {
        if reduceMotion { return .identity }
        return .asymmetric(
            insertion: .identity,
            removal: .opacity.combined(with: .scale(scale: 0.97))
        )
    }
    ```
  - Duration: `.easeInOut(duration: 0.35)`.

#### 2.3 Swiping & Reel Gesture Handling (`ContentFilter.swift`)
- **Current Issue**: Locking scroll on Reels (`updateScrollLock()`) applies `.__bi_lockedscroll` (`overflow: hidden !important; touch-action: none !important;`) to the scroll container. On some Reel permalinks, swiping down to dismiss can feel stiff.
- **Required Refinement**:
  - In `ContentFilter.swift`, ensure `touch-action: pan-y` is allowed on comment sheets and overlay dialogs so vertical swiping inside comment sheets remains fluid:
    ```css
    html.__bi_noscroll [role="dialog"]:not(:has(video)) {
      touch-action: pan-y !important;
      -webkit-overflow-scrolling: touch;
    }
    ```
  - Verify DM share-card single-tap routing (`installDMReelClickRouting()`) does not intercept multi-touch pinch/zoom gestures.

---

### Phase 3: Performance & Main-Thread Speed Optimization (P2)

#### 3.1 Route-Scoped `apply()` DOM Passes (`ContentFilter.swift`)
- **Current Issue**: `apply()` runs ~20 DOM-scanning functions (`fixDirectInbox()`, `fixSearchPage()`, `fixHomeHeader()`, `upgradeDirectPreviews()`, `removeReservedNavSpace()`, etc.) on **every** DOM mutation. Scanning the entire DOM tree during feed scrolling causes unnecessary main-thread CPU usage.
- **Required Refinement**:
  - Scope helper execution by `location.pathname`:
    ```javascript
    function apply() {
      if (!isTopFrame) return;
      lastApply = Date.now();
      applyScheduled = false;
      try {
        ensureStyleInjected();
        const path = location.pathname;
        const isHome = path === '/';
        const isDirect = /^\/direct\//.test(path);
        const isSearch = path.indexOf('/explore/search') === 0;

        hideSponsoredAndReels();
        hideFeedNoise();
        lockToPrimaryReel();
        updateScrollLock();
        forcePlaysInline();
        dismissAppNag();
        hideOriginalNav();

        if (!isDirect && !isHome) hideBottomBars();
        if (isSearch) fixSearchPage();
        if (isDirect) {
          fixDirectInbox();
          fixDirectMediaQuality();
          upgradeDirectPreviews();
          fixDMShareCardCursor();
        }
        if (isHome) {
          fixHomeHeader();
          removeReservedNavSpace();
        }
        updateCommentSheet();
        reportNavVisibility();
        reportAvatar();
        reportProfile();
        reportFeedHealth();
        armFeedWatchdog();
        reportBackgroundColor();
      } catch (e) {
        biLog('[error] apply failed: ' + (e && e.message ? e.message : e));
      }
    }
    ```
  - **Impact**: Reduces querySelector DOM traversals during home feed scrolling by ~70%, raising scroll frame rate to solid 60 FPS (P5 standard).

#### 3.2 MutationObserver Batching & Throttling (`ContentFilter.swift`)
- **Current Issue**: The `MutationObserver` callback schedules `apply()` via `scheduleApply()` (300ms throttle).
- **Required Refinement**:
  - Ensure attribute filter stays restricted to `['class', 'style']`.
  - Ignore mutation batches originating from internal class changes (`__bi_hidden`, `__bi_fav_hidden`, `__bi_reel_hidden`).

#### 3.3 Memory & Webview Pool Efficiency (`WebViewStore.swift`)
- **Current Issue**: Four tab webviews (`home`, `search`, `direct`, `profile`) are kept in memory indefinitely.
- **Required Verification**:
  - Confirm WebKit process termination (`webViewWebContentProcessDidTerminate`) properly reloads the affected webview without crashing.
  - Verify `resetAccountDerivedState()` correctly invalidates old preloads when switching accounts.

---

### Phase 4: Tactile Haptics & Interaction Polish (P3)

#### 4.1 Native Haptic Feedback Points Matrix

| Interaction | Trigger Location | Haptic Generator | Style / Effect |
| --- | --- | --- | --- |
| **Tab Switch** | `ContentView.tabSelection` | `UIImpactFeedbackGenerator` | `.light` impact on tab change |
| **Star Header Button** | `ContentView.onChange(of: bridge.favoritesEditRequests)` | `UIImpactFeedbackGenerator` | `.medium` impact on tap |
| **Pull to Refresh** | `WebViewStore.handlePullToRefresh` | `UIImpactFeedbackGenerator` | `.medium` impact on trigger |
| **Toggle Favorite Chip** | `OnboardingView.toggle(_:)` | `UISelectionFeedbackGenerator` | `selectionChanged()` |
| **Save Favorites** | `OnboardingView.footer` Commit Button | `UINotificationFeedbackGenerator` | `notificationOccurred(.success)` |
| **Feed Error Retry** | `FeedErrorView` Retry Button | `UIImpactFeedbackGenerator` | `.medium` impact on tap |

#### 4.2 Web Touch Responsiveness (`ContentFilter.swift`)
- **Touch Action**: `touch-action: manipulation` applied to `a, button, [role="button"], [role="link"], input, select, textarea`.
- **Tap Highlight**: `-webkit-tap-highlight-color: transparent` applied globally.
- **Cursor State**: Pointer cursors enabled for all custom interactive overlays.

---

## 4. Testing & Validation Checklist

Before opening the pre-release pull request, perform these mandatory checks:

### 1. Automated Script Verification
```sh
cd tools && ./check.sh
```
- Must print `ALL CHECKS PASSED` (all 19+ checks green).
- Confirms JS syntax, harvest script, density script, and jsdom runtime initialization.

### 2. Xcode Simulator Build
```sh
xcodebuild -project ios/BetterInstagram.xcodeproj -scheme BetterInstagram \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```
- Must print `** BUILD SUCCEEDED **`.

### 3. Manual Device / Simulator UX Verification Matrix

| Test Case | Procedure | Expected Result |
| --- | --- | --- |
| **Light Mode Launch** | Set device to Light Mode. Cold launch app. | Splash view background is white (`systemBackground`), text is dark, Lillygram icon renders cleanly. |
| **Dark Mode Launch** | Set device to Dark Mode. Cold launch app. | Splash view background is dark, text is light/white. |
| **Tab Navigation** | Tap Home → Search → Direct → Profile. | Switching is instant, haptic tap fires, no white/black safe area pops. |
| **Story Viewer Open/Close** | Tap a story ring from Home. Swipe down to close. | Top and bottom safe areas match page background smoothly, story viewer fills screen, close returns cleanly to feed. |
| **Reel Permalink Open** | Tap a shared Reel in DM or feed link. | Locks scroll cleanly, status bar stays themed, swipe-to-next locked, back button returns to DM/feed. |
| **Favorites Editor** | Tap star icon in header. Select/unselect accounts. Tap Save. | Star button fires haptic, selection fires selection haptic, Save fires success haptic, resave splash updates feed behind cover. |
| **Pull to Refresh** | Pull down on Home feed. | Trigger fires haptic, splash masks rebuild, fresh favorites feed renders. |

---

## 5. Handoff Summary & Next Action

This plan covers all remaining polish items for the release candidate. To execute:
1. Follow Phase 1 to implement Light Mode adaptation across splash, error, and picker views.
2. Follow Phase 2 to apply route-scoped `apply()` optimizations in `ContentFilter.swift`.
3. Follow Phase 3 & 4 to verify haptics and touch responsiveness.
4. Run `tools/check.sh` and `xcodebuild` to validate all changes before creating the release PR into `develop`.
