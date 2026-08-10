# Device-polish failure research — 2026-07-27

This report diagnoses the eight physical-device issues reported after commits
`d561ead` and `7b4e3e1`. It is research only; no production Swift or injected
JavaScript was changed.

## 1. Systemic-failure investigation and verdict

### Verdict

**The three changed Swift files are correctly compiled into the only app target.
The highest-confidence systemic finding is instead that the post-fix code was
not built as an iPhone (`iphoneos`) product in the DerivedData used by this
project.** The local iPhone app product predates both fix rounds, while the
post-fix product is a simulator product. This is the best explanation for a
literal 100% no-change result across native UIKit and injected-JavaScript fixes.

Confidence: **high**, but not absolute, because the physical phone was
unavailable during this investigation and its installed executable could not be
read directly.

Concrete evidence:

- Current checkout: `feature/pre-release-polish` at `7b4e3e1`, two commits ahead
  of `origin/feature/pre-release-polish`. The working tree was clean before this
  report was created.
- Recent commits are:
  - `7b4e3e1 fix(ux): correct DM inbox header target, geometric caret hiding,
    mask cold-start reload, harden reel pop`
  - `d561ead fix(ux): header logo stability, DM header/scroll, DM reel pop,
    pull-to-refresh haptics`
  - `c0cec53 docs: update pre-release polish handoff plan...`
- Current source modification times were approximately 22:01–22:02 local time.
  The app at
  `~/Library/Developer/Xcode/DerivedData/BetterInstagram-egynbihzdjcyvmezadezcxblrwmf/Build/Products/Debug-iphoneos/BetterInstagram.app`
  was last built at **17:15:02**, before both fixes.
- That stale `Debug-iphoneos` binary does **not** contain the current distinctive
  userscript strings `[dm] reel pop applied role=` or `[header] dm inbox title
  centered`.
- The Xcode activity log at 22:02 that did compile `ContentFilter.swift` and
  `WebViewStore.swift` targeted **`Debug-iphonesimulator`**, not `iphoneos`.
- A fresh simulator build during this investigation succeeded and its
  `BetterInstagram.debug.dylib` contains both strings plus the pull-to-refresh
  native log. This proves HEAD builds and embeds the current `ContentFilter.script`.
- The phone was listed by `xcrun devicectl list devices` as `unavailable`, so the
  installed bundle could not be checked. The evidence is consistent with Xcode
  building a simulator destination and the tester then opening the older app
  already installed on the physical phone, or with a run-without-building/stale
  device launch.
- `CURRENT_PROJECT_VERSION` remains `1` and `MARKETING_VERSION` remains `0.1.0`,
  so the old and new installations have no user-visible version distinction.

This is stronger evidence than a generic “DerivedData can be stale” theory: the
actual device product in the current project's DerivedData is demonstrably
older than the source, while the later build is demonstrably a simulator build.

### PBX project target-membership check — ruled out

`ios/BetterInstagram.xcodeproj/project.pbxproj` has one `PBXNativeTarget`, named
`BetterInstagram`, and `xcodebuild -list` reports one target and one scheme.
There are no custom build phases, alternate app targets, test hosts, or duplicate
bundle products. The Sources phase is `5892E7A57770CDE243B7F30C` and explicitly
contains all three files:

| File | `PBXBuildFile` entry | Present in app Sources phase |
| --- | --- | --- |
| `ios/BetterInstagram/ContentFilter.swift` | `ContentFilter.swift in Sources` | Yes |
| `ios/BetterInstagram/WebViewStore.swift` | `WebViewStore.swift in Sources` | Yes |
| `ios/BetterInstagram/ContentView.swift` | `ContentView.swift in Sources` | Yes |

The file references resolve under the current project source root,
`/Users/ryanstoffel/Developer/personal/better-instagram/ios`, and the sole app
uses bundle id `com.betterinstagram.app`. The classic “file exists on disk but
is not in Compile Sources” no-op is conclusively ruled out.

`xcodebuild -showBuildSettings` also resolves the current project to the expected
DerivedData directory and `Debug-iphoneos/BetterInstagram.app`. There is no
`EXCLUDED_SOURCE_FILE_NAMES`, alternate Info.plist, generated source directory,
or configuration override that excludes these files.

### Required clean device-validation protocol

Before judging any individual fix again:

1. Make the physical iPhone available and explicitly select **Ryan’s iPhone 17
   Pro** as Xcode's run destination, not an iOS Simulator or “My Mac.”
2. Delete Better Instagram from the phone.
3. In Xcode, use **Product → Clean Build Folder**. If any doubt remains, delete
   only this project's DerivedData folder (`BetterInstagram-egyn...`), then
   reopen the project.
4. Build and Run, not Run Without Building. Confirm the build log paths say
   `Debug-iphoneos`, not `Debug-iphonesimulator`.
5. Confirm the `Debug-iphoneos/BetterInstagram.app` modification time is newer
   than `ContentFilter.swift` and `WebViewStore.swift`.
6. Before testing cosmetics, confirm a temporary unmistakable build identity in
   the device console and UI. The next implementation should print something
   like `[BI-BUILD] polish-v3 commit=7b4e3e1` at app startup and temporarily show
   the same token in an unobtrusive debug-only label. Increment
   `CURRENT_PROJECT_VERSION` as a second check. A console-only marker is useful,
   but a visible marker removes ambiguity if Xcode is attached to the wrong
   process.
7. Use `xcrun devicectl device info apps --device <id>` (once the phone is
   available) to verify that `com.betterinstagram.app` is installed, then launch
   from Xcode and watch for the marker before doing any bug test.

Apple's normal build-and-run flow is documented at
[Building and running an app](https://developer.apple.com/documentation/xcode/building-and-running-an-app).
Cleaning is a practical safeguard here, but the destination mismatch/stale
`iphoneos` artifact is the concrete evidence, not merely folklore about Xcode.

### Userscript installation path — correct

The current injection path is direct and correct:

1. `WebViewStore.init` calls `installUserScripts()` before creating the home
   webview.
2. `installUserScripts()` calls `userContentController.removeAllUserScripts()`,
   installs the favorites preamble, then installs
   `WKUserScript(source: ContentFilter.script, injectionTime: .atDocumentStart,
   forMainFrameOnly: false)`.
3. The shared `WKWebViewConfiguration` receives that same
   `WKUserContentController`.
4. `makeWebView(for:)` creates every persistent tab from that configuration.
5. `ContentView.preloadSecondaryTabs()` creates search, direct, and profile on
   first appearance; all therefore receive the same current script.
6. `didFinish` calls only `ContentFilter.reapplyCall`; that is not the initial
   injection mechanism, but it correctly asks an already-injected document to
   rerun its DOM pass.

There is no alternate `ContentFilter`, duplicate source file, resource-loaded
script, or old userscript identifier.

One lifecycle caveat is worth preserving: `removeAllUserScripts()` changes
**future documents**. It does not remove or replace JavaScript already executing
inside a currently loaded document. `applyFavoritesSelection()` handles its
specific live update with `window.__biSetFavorites(...)`, and the subsequent
home load gets the newly installed full script. Across an actual app rebuild,
the app process and `WebViewStore` are recreated, so this does not explain a
stale script surviving a correctly installed new binary.

### Caches and persisted state — none can preserve the old app code

- `WKWebsiteDataStore.default()` persists Instagram cookies, HTTP cache, local
  storage, and any site-side data. It can affect Instagram's response/DOM, but
  `ContentFilter.script` is supplied by native code to `WKUserContentController`;
  it is not fetched through the website data store.
- No explicit `WKProcessPool` is cached globally. The configuration and its
  implicit process resources live with the new `WebViewStore` for that app
  process. Persistent tab webviews persist only within one app process.
- `biCachedFavEdgesJSON` persists feed payload data. It can alter which favorite
  edges are preloaded, but it cannot preserve an old header function, suppress
  a native haptic, or replace the userscript source. A live harvest byte-checks
  it before skipping a reload.
- `biFavoritesSyncDegraded` is state only; no UI currently consumes it.
- `biSyncedFavoriteUsernames` and `biDidCleanBesties` affect Favorites syncing,
  not these eight polish behaviors.
- `WKContentRuleListStore` may cache the compiled list named
  `BIBlockingRules`, but that list only hides Explore/Reels chrome. None of the
  recent fixes lives there, and `compileContentRuleList()` recompiles from the
  bundled JSON each launch.

Deleting the app is still appropriate for the clean validation protocol because
it removes ambiguity, but no discovered cache can explain native and JS code
both staying old after a genuinely fresh install.

### Test-gate result and what it does not prove

`tools/check.sh` passes completely at HEAD:

- all three extracted scripts pass `node --check` (the async bodies are wrapped);
- `tools/userscript-init-test.js` reaches the boot log, installs the XHR/history
  hooks and native entry points, starts exactly one body `MutationObserver`,
  delivers mutations, and runs its synthetic home `apply()` without an error;
- its SSR, fail-closed, live-favorites, and synthetic Story presentation checks
  pass.

The gate is useful but narrow. `tools/extract-userscript.py` extracts and
unescapes the Swift multiline string. `userscript-init-test.js` then runs it in
jsdom 29 against a synthetic **home** fixture. It does not provide:

- JavaScriptCore/WebKit rather than Node/jsdom;
- Instagram's live React/Relay DOM, detached-node races, or style rewrites;
- real layout (bounding boxes, fixed/sticky positioning, nested scroll height,
  transforms, or safe areas);
- touch routing, `UIScrollView`, media/fullscreen behavior, or native overlays;
- a DM inbox/thread fixture, so `fixDMInboxHeader`, `fixDMThreadHeader`,
  `fixDirectThreadScroll`, and `maybeAnimateReelEntry` are not behavior-tested;
- Instagram's actual CSS/JS transition driver;
- the high mutation rate and multiple frame/page realms of the physical app;
- proof that the bytes installed on the phone match the extracted source.

The harness can therefore rule out a broad initialization error in jsdom, but
not a real-WebKit runtime error or wrong live selector.

### Real-WebKit compatibility and failure isolation

The language/selectors added by the recent changes are not plausible iOS 26
compatibility failures:

- `:scope` in `fixDMThreadHeader()` has been supported by iOS Safari's DOM
  selector APIs since iOS 7 (compatibility reference:
  [Can I Use / `:scope`](https://caniuse.com/mdn-css_selectors_scope)).
- `:has()` in the injected CSS has been supported by Safari since 15.4
  ([WebKit announcement](https://webkit.org/blog/13096/css-has-pseudo-class/)).
- `Set`, `WeakMap`, promises, `dataset`, `closest`, `forEach`, and the other
  syntax used here substantially predate iOS 26. The pinned iOS 17.5 user-agent
  changes what Instagram may serve; it does not downgrade the iOS 26 JS engine.

There is still one pre-boot real-runtime risk. At top level, before `[boot]` and
before the global error listeners are installed, the script executes:

```js
Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'responseText').get
Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'response').get
```

If a real WebKit realm unexpectedly returns no own descriptor, this throws and
there is no `biLog` yet. jsdom proves only jsdom's descriptors. This is not the
leading hypothesis—these XHR properties are expected in WebKit—but the next
run can settle it cheaply: `[BI-DEBUG] [boot] filter running on ...` must appear
for each top-frame document, and native `didFinish` should evaluate a versioned
health probe such as `{version, reapply: typeof window.__biReapply}`. Guarding
those descriptor reads is reasonable hardening in a later implementation.

`apply()` has one `try/catch` around its entire pass. Its exact order is:

1. style injection;
2. `hideSponsoredAndReels`, `hideFeedNoise`;
3. `lockToPrimaryReel`;
4. `updateScrollLock` → `maybeAnimateReelEntry` when locked;
5. plays-inline, app-nag, original-nav and bottom-bar passes;
6. search fix, if applicable;
7. on Direct: inbox cleanup, `fixDMHeader`, `fixDirectThreadScroll`, media
   quality/preview and card-cursor passes;
8. on Home: `fixHomeHeader`, then reserved-nav-space removal;
9. comments, nav/avatar/profile/feed/watchdog/background reporting.

A deterministic exception in an early helper aborts every later helper **for
that pass**. The catch logs `[error] apply failed: ...`; the observer remains
alive and future real mutations schedule another pass. If the same helper
throws every time, later helpers can effectively be starved forever. The new
helpers have no obvious iOS-only throwing operation: the inline style writes in
`maybeAnimateReelEntry` are caught, `:scope` is supported, and the remaining DOM
operations are ordinary Element APIs. Nevertheless, logging only the error text
without the current stage makes a live failure unnecessarily hard to locate.
The next implementation should wrap named stages or maintain `let stage = ...`
and emit `[apply-error] stage=<name> path=<path> ...`.

One ordering flaw is already visible without a device: on the DM inbox,
`fixDMInboxHeader()` runs before `reportProfile()`, but it requires
`window.__biLastProfileHref` populated by `reportProfile()`. It necessarily does
nothing on the first pass and relies on a later mutation/pass. This does not
abort the chain, but it makes the fix timing-dependent.

### Systemic conclusion

There is **no project-membership, injection-reference, or cache defect** that
would make current source silently compile while old code runs. There is strong
artifact evidence that the physical-device product was never rebuilt after the
fixes. Therefore all eight current implementations should be treated as
**not yet tested on the physical device**, not as eight independent confirmed
failures.

There is an important qualification: even when the current binary is installed,
several fixes have deterministic or likely design defects described below. In
particular, the supposed 0.4-second pull-to-refresh delay is not actually
observable with the current native state flow. Thus the stale build explains the
100% report, but a correct reinstall will not automatically make all eight bugs
resolved.

---

## 2. Per-bug root-cause analysis

### 1. Home tab randomly refreshes by itself

**Status:** systemic-blocked and still needs real diagnosis.

**Current best hypothesis:** there are two different phenomena being described
as “refresh”: (a) an actual native `WKWebView` load/reload caused by recovery,
harvest, or process termination; or (b) Instagram React/Relay replacing/remounting
the home feed without a document navigation. The first is especially plausible
on a physical phone because the app keeps four full Instagram webviews plus an
offscreen harvest webview alive.

**Confidence:** medium.

**Evidence:**

- `WebViewStore` has several real reload paths: post-harvest reload in
  `finishHarvest`, watchdog recovery via `handleFeedStuck` →
  `reharvestAndReloadHome`, pull-to-refresh, account switch, navigation failure,
  and `webViewWebContentProcessDidTerminate` → `recoverTab`.
- The harvest webview remains attached offscreen after a successful harvest. It
  is a fifth live Instagram page, in addition to four eagerly preloaded tab
  pages. Memory pressure can terminate a WebContent process; Apple exposes
  [`webViewWebContentProcessDidTerminate`](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webviewwebcontentprocessdidterminate(_:))
  specifically for that event. The current response is a visible reload.
- The existing logs distinguish some causes (`[BI-recovery]`, `[BI-watchdog]`,
  `[BI-harvest]`) but do not assign every home load a reason/id, and no device
  log from the failing interaction was captured.
- Public web research did not find authoritative evidence that the current
  **Instagram web** client always refetches/remounts `/` when a Story or comments
  surface closes. Reports about Instagram's former automatic “rug pull” refresh
  describe first-party app behavior on reopen, not this exact web route
  ([example coverage](https://www.gadgets360.com/apps/news/instagram-automatic-feed-refresh-feature-adam-mosseri-6990551)).
  It proves Instagram has intentionally replaced visible feed content in other
  contexts, but it does not prove this hypothesis.

**Recommended fix approach:**

1. Do not alter reload behavior until one clean current-build run identifies the
   cause. Add a monotonically increasing native navigation id and reason enum in
   `WebViewStore.swift`. Every call to `load`, `reload`,
   `reharvestAndReloadHome`, and `recoverTab` should log reason, active tab,
   current URL, `isLoading`, and scroll offset. Also log
   `didStartProvisionalNavigation`, `didCommit`, `didFinish`, process termination,
   and failures with that id.
2. Add a userscript document id at boot (`performance.timeOrigin` plus a random
   token), route old→new logs, `pageshow/pagehide/visibilitychange`, and home feed
   fetch/XHR logs after a Story/comments close. Existing `[req HOME]` logs are a
   useful start.
3. Interpret one run definitively:
   - a repeated `[boot]` plus native provisional navigation is a document reload;
   - same boot id plus a new home feed request and replaced article ids is an
     Instagram refetch/remount;
   - same boot id and no feed request, but article node replacement, is local
     React remount/virtualization;
   - a process-termination log identifies memory pressure/recovery.
4. If memory/process termination is the cause, destroy and detach
   `favHarvestWebView` after a successful extraction/density pass, recreate it
   only for the next harvest, and re-evaluate preloading all three secondary
   tabs. Preserve persistent visited tabs, but do not keep unnecessary hidden
   Instagram documents alive.
5. If watchdog recovery is the cause, log the exact article/spinner evidence and
   correct the false-positive condition rather than suppressing recovery.
6. If Instagram performs only an SPA refetch/remount, preserve scroll position
   and keep a filtered snapshot/skeleton over the feed until favorite articles
   are ready; do not issue a native reload in response.

### 2. Home header logo jumps left / caret appears

**Status:** systemic-blocked; previous fix is unverified and remains brittle.

**Current best hypothesis:** Instagram remounts or restyles a compact/sticky
header during scroll. The current code identifies the logo correctly but does
not continuously enforce all centering properties, and its broad geometric
caret rule may miss a non-SVG/integrated caret or hide an unrelated centered
icon.

**Confidence:** medium for header remount/restyle; low for the exact current DOM
shape.

**Evidence:**

- `fixHomeHeader()` writes `left/top/transform/zIndex` only when
  `logoBox.style.position !== 'absolute'`. If Instagram changes `left` or
  `transform` on the same element while leaving `position:absolute`, later
  passes do not restore those values.
- The current caret pass hides every SVG narrower than 44 points whose center is
  within 60 points of the header center, excluding only the known logo, article
  SVGs, and the BetterInstagram control. This is a guess, not identity.
- A caret rendered as a path inside the logo SVG cannot be hidden separately. A
  non-SVG caret also escapes the rule.
- `docs/blocking-and-selectors.md` still says to keep the conservative
  exactly-one-SVG guard because an aggressive SVG-hiding rewrite broke
  rendering, while the current code deliberately uses a geometric aggressive
  scan. That documentation/code conflict is a warning that this needs live
  validation rather than more blind broadening.
- No current-build device console shows `[header] control button injected...`,
  and the stale device artifact means this round was not tested.

**Recommended fix approach:**

1. In the next diagnostic build, emit one bounded log on initial header and one
   when its identity/geometry changes. Include the header and logo-box tag,
   role, href, class, inline position/left/transform, bounding rect, and every
   nearby small element's tag, ARIA label, rect, and short DOM ancestry. Log
   scroll position and whether the logo box is the same node.
2. Reassert the full invariant on every applicable pass (or through a dedicated
   injected CSS class with `!important`): position, left, top, transform,
   z-index, and pointer events. Do not gate reassertion on `position` alone.
3. Identify the actual caret from the capture—ARIA label, stable wrapper, path
   signature, or a unique relation within the verified header variant—and hide
   only that element. Keep the logo separate. If two known sticky variants
   exist, encode both explicitly.
4. Add a small jsdom fixture for both observed header variants, but retain a
   physical-device scroll test because jsdom cannot validate geometry.

Cheapest decisive signal: a `[header-scan] variant=<...> logoRect=<...>
nearby=[...]` line before and after the first scroll-induced jump.

### 3. Pull-to-refresh haptic, visible spinner, then splash

**Status:** systemic-blocked **and the current fix has a verified native logic
bug**. It needs a real fix even after installing HEAD.

**Current best hypothesis:** `UIRefreshControl.valueChanged` is probably wired
correctly, but the code starts the page rebuild immediately and `ContentView`
shows a splash immediately through a different state path. The 0.4-second delay
therefore does not delay the splash or navigation. If the haptic still does not
occur in a verified build, the value-changed action is not being reached—likely
because the live Instagram surface uses/consumes an inner scroll gesture or the
pull never crosses the native refresh threshold.

**Confidence:** high for the state-flow defect; medium for refresh-control event
reachability.

**Evidence:**

- Setup is conventional: the control is assigned to
  `webView.scrollView.refreshControl`, `.valueChanged` targets
  `handlePullToRefresh`, and `alwaysBounceVertical = true`. Apple exposes the
  refresh control directly on `UIScrollView`
  ([`UIScrollView.refreshControl`](https://developer.apple.com/documentation/uikit/uiscrollview/refreshcontrol))
  and the underlying scroll view on `WKWebView`
  ([`WKWebView.scrollView`](https://developer.apple.com/documentation/webkit/wkwebview/scrollview)).
- `handlePullToRefresh()` immediately calls `reharvestAndReloadHome()`.
  That function immediately sets `favoritesFeedReady = false` and starts a new
  home `load`.
- `ContentView.activeSplash` checks `refreshingViaPull`, but when it is still
  false during the intended 0.4-second window it falls through to
  `guard !favoritesFeedReady`, then returns `.resave` because the feed has been
  ready before. The splash is therefore inserted immediately anyway.
- The immediate `WKWebView.load` also resets/replaces the page while the native
  refresh control is spinning. Delaying only `refreshingViaPull` cannot preserve
  the old page/spinner.
- `contentInsetAdjustmentBehavior = .never` disables automatic safe-area inset
  adjustment
  ([Apple documentation](https://developer.apple.com/documentation/uikit/uiscrollview/contentinsetadjustmentbehavior-swift.property)).
  The webview extends under native chrome and Instagram has its own fixed header,
  so a native control drawn above the scroll content may be visually obscured
  even while it tracks the pull.
- `.valueChanged` corresponds to committing the refresh, not the beginning of
  every partial pull. The haptic is intentionally at commit. It cannot make
  feedback happen as soon as the finger first moves.

**Recommended fix approach:**

1. Replace the two booleans' implicit interaction with an explicit published
   refresh phase in `WebViewStore`, for example `.idle`, `.pullCommitted`, and
   `.rebuilding`. `ContentView.activeSplash` must return **no splash** during
   `.pullCommitted`; it must not fall through to the generic
   `favoritesFeedReady == false` resave path.
2. On `.valueChanged`, set `.pullCommitted`, fire/prepare the haptic, and leave
   the existing document and refresh spinner alone for approximately 0.4 s.
   Only after that delay set `.rebuilding`, show the intended splash, and call
   `reharvestAndReloadHome()`.
3. Log `[refresh] valueChanged offset=... inset=... isRefreshing=...`, the phase
   changes, and rebuild start. If this line does not appear in a verified build,
   inspect the live scroller. Log the outer `WKWebView.scrollView` pan state and
   content offset while pulling; use Safari Web Inspector to identify whether
   Instagram scrolls an inner `overflow` container.
4. If the outer control is reached but hidden, use a small native spinner/progress
   overlay anchored immediately below the native/status/header boundary instead
   of relying on the refresh control's negative-content-offset position. Keep
   `UIRefreshControl` as the gesture/threshold mechanism.
5. If the outer control is not reached because an inner web scroller owns the
   gesture, add a carefully bounded native pan observation/threshold or arrange
   the home page to use the outer document scroller. Do not replace
   `WKWebView.scrollView.delegate`, which WebKit owns, without validating side
   effects; KVO/gesture observation is safer.
6. Respect Reduce Motion and system haptics settings. A prepared impact generator
   reduces latency but does not replace proof that `.valueChanged` fired.

Cheapest decisive signal: the existing native `[BI] pull-to-refresh...` line
plus the new phase logs. If absent, this is reachability; if present while the
splash appears immediately, it is the confirmed state-flow bug.

### 4. DM thread cannot always scroll to the latest message

**Status:** systemic-blocked; previous fix is an unverified heuristic and likely
needs replacement.

**Current best hypothesis:** the webview/safe-area/tab-bar geometry is wrong on
thread routes, and `fixDirectThreadScroll()` may select the wrong inner scroller
or add insufficient/nonpersistent padding.

**Confidence:** medium.

**Evidence:**

- `ContentView.webContent(for:)` ignores the bottom safe area whenever Reduce
  Transparency is off, regardless of whether the native tab bar is visible.
  DM thread routes intentionally hide that tab bar, but the webview still
  extends under the home-indicator area.
- Every webview always has native `scrollView.contentInset.bottom = 100`, even
  when the native tab bar is hidden. That outer inset does not necessarily add
  usable room to Instagram's fixed-height inner message scroller and can make
  CSS viewport geometry harder to reason about.
- The current JS scans every `div`, chooses the overflowing `auto/scroll`
  container with the largest `scrollHeight - clientHeight`, and adds only 28 px
  of bottom padding. The tallest overflow container may be an inbox, hidden
  virtualized list, dialog, or ancestor rather than the message list.
- Once a connected container is cached, the function returns forever. If React
  removes the inline padding from that same node, or the relevant child scroller
  changes while the ancestor stays connected, the fix is not reasserted.
- Twenty-eight CSS pixels is unrelated to the 100-point native clearance, the
  composer height, or `safe-area-inset-bottom`.
- The live DOM and actual last-message/composer positions were never captured.

**Recommended fix approach:**

1. First correct the native geometry: only ignore the bottom safe area while the
   native tab bar is actually visible. When `bridge.isNavVisible` is false for a
   thread, let SwiftUI respect the bottom safe area. Make the outer bottom inset
   route/tab-bar-aware instead of permanently 100, and update
   `scrollIndicatorInsets` consistently.
2. Add one bounded `[dm-scroll]` capture containing every plausible scrolling
   ancestor's rect, `scrollTop`, `clientHeight`, `scrollHeight`, overflow style,
   max scroll, and ancestry; also log the composer top/bottom and the final
   visible message bottom. Capture before and after attempting to scroll fully.
3. Identify the message list structurally from the composer and message rows,
   not by global maximum overflow. Compute actual occlusion from the visual
   viewport/composer/safe area.
4. Apply `scroll-padding-bottom` and/or bottom padding based on measured
   occlusion plus a small margin. Reassert the values if React rewrites style;
   a connected-node cache alone is insufficient. Avoid inserting a React-owned
   child unless testing proves a sentinel spacer is safe.
5. Test with the keyboard closed/open, a short thread, a long virtualized
   thread, and immediately after a new incoming/outgoing message.

Cheapest decisive signal: `[dm-scroll] chosen=<ancestry> top=<...> max=<...>
lastBottom=<...> composerTop=<...> viewport=<...>`.

### 5. A reel opened from DMs slides from the right instead of popping

**Status:** systemic-blocked; previous fix is plausible but unverified and not
robust against the likely animation mechanism.

**Current best hypothesis:** `maybeAnimateReelEntry()` runs after Instagram has
already mounted/painted or begun animating the surface, and may target a child
while an outer route container is sliding. Instagram may also drive `transform`
from JavaScript each frame, overwriting the injected inline declaration.

**Confidence:** medium-high.

**Evidence:**

- The current entry hook is reached from `updateScrollLock()` only after a
  near-fullscreen video exists. The general observer then schedules that update
  in `requestAnimationFrame` and again after 50 ms. This is late enough for an
  initial slide frame to paint.
- `reelOverlayContainer()` tries dialog, scroll container, then a near-fullscreen
  fixed/absolute ancestor. It does not identify which ancestor actually owns
  the changing transform.
- Inline `!important` wins the CSS cascade, but a script assigning the same
  inline property later can replace it. It also cannot stop a different ancestor
  from translating.
- The code logs `[dm] reel pop applied role=...`, but no current-build device log
  exists.

**Recommended fix approach:**

1. On the trusted DM share-card activation path, set a short-lived
   `__bi_dm_reel_pending` state **before** forwarding the click/navigation.
2. Add a dedicated, narrowly scoped document-start observer for this pending
   state. MutationObserver callbacks run as microtasks; the browser processes
   microtasks before it may update rendering
   ([MDN event-loop guide](https://developer.mozilla.org/en-US/docs/Web/API/HTML_DOM_API/Microtask_guide)).
   As soon as the future overlay/video subtree is mounted, gate it with
   `visibility:hidden !important` before its first visible slide.
3. Walk all near-fullscreen ancestors and log each computed/inline transform,
   transition, animation name, and rect for several frames. Also inspect
   `element.getAnimations({subtree:true})`; the Web Animations API returns active
   animations on the element/descendants
   ([MDN `getAnimations`](https://developer.mozilla.org/en-US/docs/Web/API/Element/getAnimations))
   and they can be cancelled
   ([MDN `Animation.cancel`](https://developer.mozilla.org/en-US/docs/Web/API/Animation/cancel)).
4. Do not fight an unknown per-frame slide while it is visible. Keep the surface
   hidden until the Instagram transform reaches its stable resting state (or
   cancel the verified animation), then reveal it with the app's own short
   scale/opacity transition. This also works when Instagram owns an outer
   transform because the unwanted movement is never shown.
5. `@starting-style` is available in WebKit from Safari 17.5 and is intended for
   transitions when an element is first rendered
   ([WebKit Safari 18 notes](https://webkit.org/blog/15865/webkit-features-in-safari-18-0/),
   [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/@starting-style)).
   It is useful only if the userscript class/selector applies before the first
   style update; it does not by itself override Instagram's separate animation.
6. Safari supports the View Transitions API from Safari 18, but it requires the
   caller to invoke `document.startViewTransition()` around the DOM state change.
   The userscript does not own Instagram React's mount callback, so this is not
   the first-choice fix. The pre-paint visibility gate is more controllable.
7. Disable the custom animation under `prefers-reduced-motion`.

Cheapest decisive signal: whether `[dm] reel pop applied...` fires, followed by
an `[dm-pop] ancestors=[{transform, transition, animations...}]` capture. No log
means detection/timing; a log with another moving ancestor means wrong target;
a log with the same transform changing each frame means JS-driven override.

### 6. Own username in the DM inbox header is not centered

**Status:** systemic-blocked; the follow-up targeted the correct screen but is
still timing- and selector-dependent.

**Current best hypothesis:** `fixDMInboxHeader()` often has no trustworthy
username when it runs, or its exact leaf-text search does not match the current
header markup. If it finds a title, `centerDMHeaderTitle()` can also select the
wrong wide ancestor and then stops enforcing once its dataset flag is set.

**Confidence:** medium-high for the dependency flaw; low for the exact live DOM.

**Evidence:**

- The follow-up correctly distinguishes `/direct/inbox/` from `/direct/t/...`.
- The inbox fix depends on `window.__biLastProfileHref`. Each tab is a separate
  JS realm, so the home tab's value is not available in the Direct webview.
- In `apply()`, `fixDMHeader()` runs before `reportProfile()`. The first pass
  cannot use a username even if the Direct tab's hidden Instagram nav can
  resolve one later in that same pass.
- `findProfileAnchor()` returns the first nav-row href that is not in a small
  reserved set; it does not prove the href is the signed-in user's one-segment
  profile path.
- Candidate matching requires a leaf `span/div/button/a` whose trimmed text is
  exactly the username. An account-switcher control can include nested text,
  a chevron, or accessibility-only copy.
- Once `data-bi-dm-centered=1` is set, centering is never reasserted on the same
  node if Instagram rewrites its inline style.

**Recommended fix approach:**

1. Reorder identity reporting so the Direct realm resolves/logs the own-profile
   href before trying a username-dependent header fix, or pass the verified own
   profile href from native into every webview preamble/live realm.
2. On the next run, log `[dm-header] profileHref=<...> route=<...>` and bounded
   top-of-page candidates with text, ARIA label, role, rect, and ancestry. Also
   log the selected header/title rect before and after centering.
3. Prefer structural identification of the top fixed/sticky inbox header and
   its account-switcher title control, using the verified capture. Treat the
   username as corroboration rather than the only anchor.
4. Reassert the complete centering invariant or apply a dedicated CSS class;
   do not return solely because a dataset marker exists.
5. Test account-switcher open/close and scroll/sticky variants.

Cheapest decisive signal: if `[header] dm inbox title centered` is absent, log
whether `profileHref` was empty versus candidates did not match. If present,
compare title/header centers numerically.

### 7. General app slowness

**Status:** needs real profiling and likely a real performance pass; not solved by
prior commits.

**Current best hypothesis:** broad high-frequency DOM observation/work across
four preloaded Instagram pages, subframes, and a fifth attached harvest page is
consuming web-process CPU/memory. This can also cause the process termination and
home reload in bug 1.

**Confidence:** high that these are material risks; medium that they explain all
perceived slowness.

**Evidence:**

- The observer watches `document.body`, all descendants, child changes, and
  every `class`/`style` attribute change. This is particularly busy in Direct.
- Every scheduled pass still performs many document-wide scans. Always-on work
  includes article/reel scans, app-nag scans, nav discovery, video scans, and
  nine-point background compositing with repeated layout/style reads. Direct
  adds a bottom-bar scan over every div/nav/footer, image/share-card scans, and
  potentially global header/scroller scans. Home's `hideFeedNoise()` scans a
  very broad `span,h2,h3,div` set.
- `forMainFrameOnly:false` installs most of the script and a body observer in
  every subframe.
- All four tab webviews are loaded at launch. The harvest webview is attached to
  the key window offscreen and retained after harvest.
- Many passes mix DOM writes with `getBoundingClientRect`/`getComputedStyle`,
  increasing forced-layout risk.
- The 300 ms throttle caps pass frequency but does not make each pass cheap, and
  hidden webviews still consume memory even if WebKit throttles some execution.

**Recommended fix approach:**

1. Profile the verified current build before changing preload semantics. Use
   Instruments (Time Profiler, Allocations/VM, hangs) while reproducing home
   scroll, tab switching, and a busy DM thread. Use Safari's remote Web Inspector
   timeline for the actual WKWebView; Apple documents physical-iOS inspection at
   [Inspecting iOS](https://developer.apple.com/documentation/safari-developer-tools/inspecting-ios).
2. Add `performance.mark/measure` around each named `apply()` stage and emit a
   sampled summary (count, total, max) rather than logging every pass. Add native
   signposts around tab creation, harvest, reload, and process termination.
3. Destroy/detach the harvest webview after each successful harvest/density
   result. This is the cheapest obvious memory reduction.
4. Log top-frame/subframe URLs. If Instagram surfaces used by this app do not
   rely on subframes, change the user scripts to `forMainFrameOnly:true`.
5. Split the single global observer by route and root. Observe `main` or the
   relevant feed/thread container; remove `style` observation unless a measured
   feature requires it. Process added nodes directly and reserve full rescans for
   route/container changes.
6. Replace repeated global scans with captured, validated roots and targeted
   selectors. Avoid alternating style writes and geometry reads in the same
   loop; batch reads before writes.
7. Re-evaluate eager creation of all secondary tabs using measurements. A
   staged preload after home is ready may preserve fast switching without
   peaking CPU/memory during launch. Keep persistent already-visited tabs.
8. Correlate any `[BI-recovery] ... content process terminated` with memory.
   Reducing memory is more valuable than making recovery reload prettier.

### 8. Leaving a Story or comments causes the home feed to refresh/flash

**Status:** systemic-blocked; the current mitigation is logically incomplete and
needs a real fix after one diagnostic capture.

**Current best hypothesis:** there are at least two likely paths. Instagram may
refetch/remount home articles when returning from a viewer, or React may reuse
an article and replace its class list, removing BetterInstagram's hide marker.
The current immediate route `apply()` does not reliably cover either timing.

**Confidence:** high that the current mitigation is insufficient; medium on the
live root cause.

**Evidence:**

- `onRouteChange()` schedules one `requestAnimationFrame(apply)` immediately
  when the path becomes `/`. React may mount replacement articles **after** that
  frame, so the pass can run too early.
- A comments dialog can close without any route change. That path receives only
  the normal mutation throttle, up to approximately 300 ms.
- Added article nodes are filtered synchronously in the main MutationObserver,
  which is good. But same-node class replacement has a specific bug:
  `selfClassChurn()` treats any class change whose non-`__bi_` tokens are equal
  as self-inflicted. It therefore ignores not only BetterInstagram adding
  `__bi_hidden`, but also Instagram/React **removing** `__bi_hidden` from the
  same node. A hidden algorithmic article can become visible and fail to
  schedule a reapply until some unrelated real mutation occurs.
- A true document reload would emit a new userscript `[boot]`; an SPA remount
  would not. No correlated live logs were captured.
- Web research found no authoritative public description of Instagram Web's
  current Story/comments return behavior. The hypothesis must remain unverified
  until a live capture; secondary reports about the native app's former
  automatic refresh are not sufficient evidence.

**Recommended fix approach:**

1. Add the diagnostic matrix described in bug 1: native navigation lifecycle,
   document boot id, route transitions, home feed network requests, article
   media ids/node identity, and counts of added/removed/reused articles around
   close.
2. Fix self-mutation suppression so only the app's **expected marker additions**
   are suppressed. Marker removal must be treated as a real change and refiltered
   synchronously. A `WeakMap`/expected-transition record is safer than comparing
   token sets without direction.
3. Handle comments-close independently of URL changes. When
   `visibleCommentSheet()` transitions from open to closed, keep the existing
   filtered state and run targeted feed reconciliation after the confirmed
   close, not merely general nav reporting.
4. For route return, observe the actual feed container/article mutations over
   the remount window instead of firing one early full pass. Filter each added
   article before paint; MutationObserver microtask timing makes this preferable
   to a delayed whole-document scan.
5. Move any stable hide rule earlier—document-start CSS or the data layer—where
   possible. Class-based post-render hiding is vulnerable to React replacing
   `className`.
6. If logs prove a real Instagram feed refetch, ensure the response splice/filter
   is already armed, preserve scroll, and cover only the short Relay remount with
   a native/web snapshot or skeleton. Do not reload the WKWebView.
7. If logs prove a native reload, fix the exact reload reason (watchdog/process/
   navigation) rather than adding another visual delay.

Cheapest decisive signal: a single close sequence containing `[BI-BUILD]`,
`[boot id=...]`, native `didStart/didCommit/didFinish`, `[route] old→new`,
`[req HOME]`, and `[feed-remount] added/removed/reused/markerRemoved`.

---

## 3. Prioritized action list for the next implementation pass

1. **Prove and fix deployment first.** Select the physical-device destination,
   delete the installed app, clean this project's DerivedData, rebuild
   `Debug-iphoneos`, and verify a visible + console build fingerprint. Do not
   spend another device round on cosmetics until this passes.
2. **Add one-run observability before selector changes.** Add native navigation
   reason/ids and process-termination logs; userscript version/health, named
   `apply` stage errors/timings, route/feed-remount logs, and bounded header/
   scroll/animation captures. One physical run should classify all eight issues.
3. **Fix pull-to-refresh's deterministic state machine bug.** Delay the actual
   reharvest/load and explicitly suppress all splash paths during the 0.4 s
   native-spinner phase. Verify `.valueChanged` and haptic in logs.
4. **Reduce the obvious fifth-webview cost.** Destroy the hidden harvest webview
   after successful extraction/density. Profile memory/process terminations and
   then decide whether secondary-tab preload should be staged.
5. **Fix feed marker-removal handling.** `selfClassChurn()` must not ignore React
   removing `__bi_*` hide markers. Add targeted Story/comments return tests and
   diagnose true refetch versus remount versus reload.
6. **Correct native DM geometry before more DOM padding.** Respect the bottom
   safe area when the tab bar is hidden and make native bottom clearance
   visibility-aware. Then capture and target the real message scroller.
7. **Use the live capture to make header fixes identity-based.** Reassert complete
   style invariants and replace broad geometric guesses for the home caret and
   inbox title with selectors/structure proven by the captured DOM.
8. **Replace the DM reel race with a pre-paint gate.** Mark a pending DM-reel
   activation before the click, hide the mounted viewer before first paint,
   identify/cancel or wait out Instagram's real slide driver, then reveal with
   the custom centered pop. Respect Reduce Motion.
9. **Perform the measured userscript performance pass.** Route/root-scoped
   observers, top-frame-only injection if validated, batched reads/writes, and
   removal of broad scans should follow profiler evidence.
10. **Only then re-run the eight-item acceptance pass** on the same physical
    device with the build fingerprint captured in the test notes.

## Summary status table

| # | Issue | Status after this research |
| --- | --- | --- |
| 1 | Random home refresh | Systemic-blocked; needs navigation/process/refetch diagnosis |
| 2 | Logo/caret instability | Systemic-blocked; current geometric fix unverified and brittle |
| 3 | Pull refresh feedback/transition | Systemic-blocked; current 0.4 s implementation is definitely ineffective and needs a real state-machine fix |
| 4 | DM cannot reach latest message | Systemic-blocked; current max-overflow/28 px heuristic likely needs replacement plus native safe-area correction |
| 5 | DM reel slides from right | Systemic-blocked; current override is late/target-guessing; pre-paint gate recommended |
| 6 | DM inbox username not centered | Systemic-blocked; correct route now targeted, but username dependency/order is flawed |
| 7 | App feels slow | Needs profiling/real fix; five live web pages and broad observers are high-confidence risks |
| 8 | Home flashes after Story/comments | Systemic-blocked; current one-rAF mitigation is incomplete and marker-removal suppression is a concrete bug |
