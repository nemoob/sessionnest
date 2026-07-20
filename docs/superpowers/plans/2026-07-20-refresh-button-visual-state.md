# Refresh Button Visual State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the popover refresh button visually consistent with the other header buttons and rotate its symbol while refresh work is active.

**Architecture:** Add a small value type that resolves the button's presentation from the existing refresh state, plus a focused SwiftUI symbol view that owns only the rotation animation. Keep the shared header button container unchanged and rely on the controller's current duplicate-request guard.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing, macOS 14+

## Global Constraints

- Keep the same foreground color, 30-point circular hit area, hover background, pressed background, tooltip, and accessibility label as the other header buttons.
- Do not dim the refresh button while a refresh is running.
- Rotate the existing refresh symbol while work is in progress, then return it to its resting orientation.
- Continue using the controller's existing guard to ignore duplicate refresh requests.
- Do not change header spacing, the divider, menu bar status width, or other buttons.
- Add no dependencies and preserve macOS 14 compatibility.

---

### Task 1: Refresh Button Activity Presentation

**Files:**
- Modify: `Sources/SessionNest/SessionNestStatusPopover.swift`
- Test: `Tests/SessionNestTests/SessionNestStatusItemControllerTests.swift`

**Interfaces:**
- Consumes: `Bool` from `MenuBarStatus.showsProgress`
- Produces: `RefreshButtonVisualState(isRefreshing:)` with `isVisuallyEnabled: Bool` and `isAnimating: Bool`; `RefreshHeaderSymbol(isAnimating:)`

- [ ] **Step 1: Write the failing state test**

```swift
@Test func refreshButtonStaysVisuallyEnabledWhileAnimating() {
    let idle = RefreshButtonVisualState(isRefreshing: false)
    let refreshing = RefreshButtonVisualState(isRefreshing: true)

    #expect(idle.isVisuallyEnabled)
    #expect(!idle.isAnimating)
    #expect(refreshing.isVisuallyEnabled)
    #expect(refreshing.isAnimating)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcrun swift test --no-parallel --filter refreshButtonStaysVisuallyEnabledWhileAnimating
```

Expected: compilation fails because `RefreshButtonVisualState` does not exist.

- [ ] **Step 3: Add the minimal presentation state and rotating symbol**

Add the state resolver:

```swift
struct RefreshButtonVisualState: Equatable {
    let isVisuallyEnabled = true
    let isAnimating: Bool

    init(isRefreshing: Bool) {
        isAnimating = isRefreshing
    }
}
```

Add a private symbol view that renders `arrow.triangle.2.circlepath`, starts a linear repeating 0.8-second rotation while `isAnimating` is true, and resets to zero degrees when it becomes false. In the overview header, build the visual state from `status.showsProgress`, stop passing `isEnabled: !status.showsProgress`, and pass `visualState.isAnimating` to the symbol view. Leave the controller refresh guard unchanged.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
xcrun swift test --no-parallel --filter refreshButtonStaysVisuallyEnabledWhileAnimating
```

Expected: one test passes with zero failures.

- [ ] **Step 5: Run formatting and the complete repository check**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift-format format --in-place --configuration .swift-format \
  Sources/SessionNest/SessionNestStatusPopover.swift \
  Tests/SessionNestTests/SessionNestStatusItemControllerTests.swift
bash Scripts/check.sh
```

Expected: formatting succeeds and all tests pass with zero failures.

- [ ] **Step 6: Package and verify the local app**

Run:

```bash
bash Scripts/package-app.sh
codesign --verify --deep --strict --verbose=2 dist/SessionNest.app
```

Expected: the release build succeeds and `dist/SessionNest.app` has a valid ad-hoc signature.

- [ ] **Step 7: Commit the implementation**

```bash
git add Sources/SessionNest/SessionNestStatusPopover.swift \
  Tests/SessionNestTests/SessionNestStatusItemControllerTests.swift
git commit -m "Polish refresh button activity state"
```
