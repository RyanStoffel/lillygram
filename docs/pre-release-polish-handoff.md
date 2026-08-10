# Pre-Release Polish & Performance Handoff Plan

**Target Application:** Lillygram (iOS / SwiftUI + WKWebView)  
**Date:** July 26, 2026  
**Document Status:** Updated Post-Device Testing — Ready for Review & Execution  
**File Location:** `docs/pre-release-polish-handoff.md`

---

## 1. Executive Summary & Status Update

Lillygram is a SwiftUI wrapper around four persistent `WKWebView` instances running `instagram.com` with a single shared `WKUserContentController`. A comprehensive userscript (`ContentFilter.swift`) removes distractions (Reels feed, Explore grid, ads) while splicing the user's selected favorites into the home feed.

### Recently Resolved Items (Confirmed Working)
- **Top & Bottom Safe-Area Color Matching**: The top status-bar safe area and bottom footer safe area now continuously match Instagram's page/header background color (`#0c1014` / `rgb(12, 16, 20)` in Dark Mode, white in Light Mode).
- **Background Sampling**: Web background sampling via `reportBackgroundColor()` correctly mirrors theme changes to native chrome.

### Remaining Open Focus Areas for Release Candidate
1. **Performance & Main-Thread Speed**: Scoping DOM mutation passes in `ContentFilter.swift` to eliminate scroll jank (target P5 ~60 FPS standard).
2. **Transitions & Animations**: Refining tab bar show/hide transitions, reel modal pop transitions, and splash fade-outs.
3. **Instagram Header Logo Stability**: Permanent CSS + JS fix for logo centering so it never jumps left or displays caret icon artifacts.
4. **DM Tab Scrolling & Header Layout**: Ensuring DM message lists can scroll fully to the bottom and centering the username in the DM top header.
5. **Pull-to-Refresh Polish & Haptics**: Adding tactile haptic feedback and spinner visibility before showing update splashes.
6. **Light Mode Theme Adaptation**: Updating `LaunchSplashView`, `ResaveSplashView`, `FeedErrorView`, and `FavoritesPickerView` for full Light Mode support.

---

## 2. Current Architecture & Component Map

| File | Primary Responsibility | Key Invariants / Notes |
| --- | --- | --- |
| `ios/Lillygram/ContentView.swift` | Root view, `TabView`, splash overlays (`LaunchSplashView`, `ResaveSplashView`), `FeedErrorView`. | Tab bar visibility driven by `bridge.isNavVisible`. `ZStack` background uses `bridge.pageBackground.ignoresSafeArea()`. |
| `ios/Lillygram/ContentFilter.swift` | Multiline JS string (`ContentFilter.script`). Handles DOM filtering, route guards, network hooks, and color reporting. | **All regex backslashes MUST be doubled** (`\/` → `\\/`). Must pass `./tools/check.sh` on every edit. |
| `ios/Lillygram/WebViewStore.swift` | Manages 4 tab webviews + hidden harvest webview, `WKUserContentController`, cookie observing, and message handlers (`biNav`, `biBg`, `biFavReady`, `biFeedStuck`). | Shared data store across webviews. Native bridge callbacks run on MainActor. |
| `ios/Lillygram/OnboardingView.swift` | `FavoritesPickerView` for initial onboarding and star-tab editor. Also houses `AppSettingsView` and `BugReportView`. | Handles following list load and search query debounce (350ms). |
| `ios/Lillygram/WebBridge.swift` | `@Published` state mirrored out of web pages (`isNavVisible`, `avatarURL`, `pageBackground`, `safeAreaBackground`). | Used by `ContentView` to coordinate UI layout. |
| `tools/check.sh` | Test runner script. Extracts scripts from `ContentFilter.swift`, syntax-checks with node, and executes `tools/userscript-init-test.js`. | **Mandatory gate.** Must run and output `ALL CHECKS PASSED`. |

---

## 3. Detailed Technical Action Plan

### Section 1: Performance & Main-Thread Speed (P0)

#### 1.1 Watchdog & Page Reload Loop Prevention (`ContentFilter.swift` & `WebViewStore.swift`)
- **Problem**: `armFeedWatchdog()` previously re-armed on route changes (like returning from stories, reels, or comment sheets). If DOM re-hydration lagged, `feedLooksStuck()` fired `biFeedStuck`, triggering an automatic re-harvest and full home webview reload.
- **Action Required**:
  - Permanently disarm `armFeedWatchdog()` once initial feed ready is posted (`window.__biFavReadyPosted`).
  - Remove `window.location.assign('/')` 300ms fallback in `goToPath()` to prevent forced page reloads on SPA history back.

#### 1.2 Route-Scoped `apply()` DOM Passes (`ContentFilter.swift`)
- **Problem**: `apply()` runs ~20 DOM-scanning functions (`fixDirectInbox()`, `fixSearchPage()`, `fixHomeHeader()`, `upgradeDirectPreviews()`, `removeReservedNavSpace()`, etc.) on **every** DOM mutation. Scanning the entire DOM tree during feed scrolling causes main-thread CPU spikes.
- **Action Required**:
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

        if (!isHome) hideBottomBars();
        if (isSearch) fixSearchPage();
        if (isDirect) {
          fixDirectInbox();
          fixDMHeader();
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
  - **Impact**: Cuts DOM traversal calls on feed scroll by ~70%, targeting a solid 60 FPS (P5 standard).

#### 1.3 `scheduleApply()` Latency & Observer Filtering (`ContentFilter.swift`)
- **Action Required**:
  - Reduce `scheduleApply()` throttle from 300ms to 150ms for snappier DOM hiding response.
  - Enable `attributeOldValue: true` on `MutationObserver` and filter out self-inflicted `__bi_*` class toggles (`selfClassChurn`) so internal hides do not re-trigger observer loops.

---

### Section 2: Header Logo Stability & DM Polish (P1)

#### 2.1 Instagram Header Logo & Caret Stabilization (`ContentFilter.swift`)
- **Problem**: Instagram dynamically injects caret/chevron SVGs (`svg[aria-label="Down chevron icon"]`) inside or next to `logoBox`. When SVG count > 1, `logoBox` position reset from `absolute` to `static`, snapping the logo to the left.
- **Action Required**:
  - Add CSS rule to hide carets/chevrons:
    ```css
    svg[aria-label*="chevron" i], svg[aria-label*="down" i], svg[aria-label*="caret" i] {
      display: none !important;
    }
    ```
  - Update `fixHomeHeader()`: scan and hide caret parent elements, then enforce `logoBox` styling:
    `position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); z-index: 2; pointer-events: none;`.

#### 2.2 DM Header Username Centering (`ContentFilter.swift`)
- **Action Required**:
  - Add `fixDMHeader()` to center account handles / thread headings in the DM header bar:
    `position: absolute; left: 50%; transform: translateX(-50%); text-align: center;`.

#### 2.3 DM Thread Bottom Scrolling (`WebViewStore.swift` & `ContentFilter.swift`)
- **Problem**: Setting fixed `bottomTabBarClearance` (100pt) clipped the bottom of DM message lists when the tab bar was hidden.
- **Action Required**:
  - In `WebViewStore.makeWebView`: set `contentInset.bottom = (target == .direct) ? 34 : Self.bottomTabBarClearance`.
  - In CSS: ensure `section[role="region"]` and DM containers have `-webkit-overflow-scrolling: touch` and `overscroll-behavior-y: contain`.

---

### Section 3: Animations & Transitions (P1)

#### 3.1 DM Reel Pop-Center Animation (`ContentFilter.swift`)
- **Problem**: Shared Reels sent in DMs slid in from the right like a web page navigation.
- **Action Required**:
  - Add CSS keyframe animation for Reel modal/dialog containers:
    ```css
    @keyframes biPopCenter {
      0% { transform: scale(0.85); opacity: 0; }
      100% { transform: scale(1); opacity: 1; }
    }
    div[role="dialog"]:has(video), section[role="dialog"]:has(video) {
      animation: biPopCenter 0.22s cubic-bezier(0.175, 0.885, 0.32, 1.255) !important;
      transform-origin: center center !important;
    }
    ```

#### 3.2 Tab Bar Show/Hide Animation (`ContentView.swift`)
- **Action Required**:
  - Add `.animation(.easeInOut(duration: 0.25), value: isTabBarVisible)` to tab bar visibility changes.

#### 3.3 Splash Screen Fade-Out Transition (`ContentView.swift`)
- **Action Required**:
  - Refine `splashTransition`:
    ```swift
    private var splashTransition: AnyTransition {
        if reduceMotion { return .identity }
        return .asymmetric(
            insertion: .identity,
            removal: .opacity.combined(with: .scale(scale: 0.97))
        )
    }
    ```

---

### Section 4: Pull-to-Refresh Polish & Haptics (P2)

#### 4.1 Pull-to-Refresh Haptics & Spinner Delay (`WebViewStore.swift`)
- **Action Required**:
  - Add `UIImpactFeedbackGenerator(style: .medium).impactOccurred()` on pull trigger.
  - Set `refresh.tintColor = .secondaryLabel` for light/dark mode compatibility.
  - Introduce a 0.35s delay before setting `refreshingViaPull = true` so the user sees the refresh spinner spin under the header before transitioning to the update splash.

#### 4.2 Native Haptic Points Matrix

| Interaction | Trigger Location | Haptic Generator | Style / Effect |
| --- | --- | --- | --- |
| **Tab Switch** | `ContentView.tabSelection` | `UIImpactFeedbackGenerator` | `.light` impact on tab change |
| **Header Control Button** | `ContentView.onChange(of: bridge.favoritesEditRequests)` | `UIImpactFeedbackGenerator` | `.medium` impact on tap |
| **Pull to Refresh** | `WebViewStore.handlePullToRefresh` | `UIImpactFeedbackGenerator` | `.medium` impact on trigger |
| **Toggle Favorite Chip** | `OnboardingView.toggle(_:)` | `UISelectionFeedbackGenerator` | `selectionChanged()` |
| **Save Favorites** | `OnboardingView.footer` | `UINotificationFeedbackGenerator` | `notificationOccurred(.success)` |
| **Report Bug / Settings** | `OnboardingView` settings buttons | `UIImpactFeedbackGenerator` | `.light` impact on tap |

---

### Section 5: Light Mode & System Theme Adaptation (P2)

#### 5.1 System Backgrounds & Contrast (`ContentView.swift` & `OnboardingView.swift`)
- **`LaunchSplashView` & `ResaveSplashView`**:
  - `Color.black` → `Color(.systemBackground)`.
  - Attribution text: `.secondary` and `.primary`.
  - Remove hardcoded white `ProgressView` tints.
- **`FeedErrorView`**:
  - `Color.black` → `Color(.systemBackground)`.
  - Retry button: `Color.primary.opacity(0.1)` in `Capsule()`.
- **`FavoritesPickerView`**:
  - Search field: `Color(.secondarySystemBackground)`.
  - Selection chips: `Color(.tertiarySystemFill)`.

#### 5.2 Dynamic Theme CSS (`ContentFilter.swift`)
- Include theme-aware media queries:
  ```css
  @media (prefers-color-scheme: dark) {
    html, body { background-color: rgb(12, 16, 20) !important; }
    section[role="dialog"], div[role="dialog"], section[role="region"] { background-color: rgb(12, 16, 20) !important; }
  }
  @media (prefers-color-scheme: light) {
    html, body { background-color: rgb(255, 255, 255) !important; }
    section[role="dialog"], div[role="dialog"], section[role="region"] { background-color: rgb(255, 255, 255) !important; }
  }
  ```
- JS fallback helper: `defaultPageColor()` returns `rgb(12, 16, 20)` in dark mode and `rgb(255, 255, 255)` in light mode.

---

## 4. Verification & Validation Protocol

Before opening the PR, run:

1. **Automated Test Gate**:
   ```sh
   cd tools && ./check.sh
   ```
   - All 19+ checks must pass (`ALL CHECKS PASSED`).

2. **Xcode Build & Archive Verification**:
   ```sh
   xcodebuild -project ios/Lillygram.xcodeproj -scheme Lillygram \
     -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
     CODE_SIGNING_ALLOWED=NO build
   ```
   - Must output `** BUILD SUCCEEDED **`.

3. **App Store / TestFlight Build**:
   - `ASSETCATALOG_COMPILER_APPICON_NAME = Lillygram` in `project.pbxproj`.
   - Distribute archive via Xcode Organizer -> TestFlight.

---

## 5. Execution Summary

This handoff plan outlines the exact technical requirements and architectural invariants needed to take Lillygram to release candidate status. Awaiting instructions to proceed.
