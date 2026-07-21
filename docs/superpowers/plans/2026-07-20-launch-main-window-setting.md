# Launch Main Window Setting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a locally persisted setting that optionally opens the SessionNest main window at application launch while remaining disabled by default.

**Architecture:** Define one testable UserDefaults-backed launch preference beside the existing application lifecycle, expose it through `AppStorage` in the popover settings page, and reuse the current `openMainWindow()` path after the menu bar controller is installed. No database migration or new dependency is required.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Swift Testing, UserDefaults, macOS 14+

## Global Constraints

- The setting label is `启动时默认打开主窗口`.
- The default value is `false` for new and existing users without a saved preference.
- The setting applies on the next application launch and does not open or close the current window.
- Enabled launch shows the main window and Dock icon through the existing window lifecycle.
- Closing the main window keeps SessionNest running in menu-bar accessory mode.
- Store only a Boolean in UserDefaults; do not add a database field, dependency, or migration.

---

### Task 1: Persist and Apply the Launch Preference

**Files:**
- Modify: `Sources/SessionNest/SessionNestApp.swift`
- Modify: `Sources/SessionNest/SessionNestStatusPopover.swift`
- Test: `Tests/SessionNestTests/SessionNestAppTests.swift`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: `SessionNestLaunchPreference.opensMainWindowKey: String`
- Produces: `SessionNestLaunchPreference.shouldOpenMainWindow(defaults: UserDefaults) -> Bool`
- Consumes: the existing `SessionNestAppDelegate.openMainWindow()` lifecycle and `SessionNestPresentationTransition`

- [ ] **Step 1: Write the failing launch preference test**

```swift
@Test func launchMainWindowPreferenceDefaultsOffAndPersistsLocally() {
    let suiteName = "SessionNestLaunchPreferenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(SessionNestLaunchPreference.opensMainWindowKey == "sessionnest.launch.opensMainWindow")
    #expect(!SessionNestLaunchPreference.shouldOpenMainWindow(defaults: defaults))

    defaults.set(true, forKey: SessionNestLaunchPreference.opensMainWindowKey)
    #expect(SessionNestLaunchPreference.shouldOpenMainWindow(defaults: defaults))

    defaults.set(false, forKey: SessionNestLaunchPreference.opensMainWindowKey)
    #expect(!SessionNestLaunchPreference.shouldOpenMainWindow(defaults: defaults))
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --no-parallel --filter launchMainWindowPreferenceDefaultsOffAndPersistsLocally
```

Expected: compilation fails because `SessionNestLaunchPreference` does not exist.

- [ ] **Step 3: Implement the minimal preference and startup behavior**

Add beside the existing presentation transition:

```swift
enum SessionNestLaunchPreference {
    static let opensMainWindowKey = "sessionnest.launch.opensMainWindow"

    static func shouldOpenMainWindow(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: opensMainWindowKey)
    }
}
```

In `applicationDidFinishLaunching`, read the preference once, keep the initial accessory transition, install the status item, and call the existing `openMainWindow()` only after installation when the value is true:

```swift
let shouldOpenMainWindow = SessionNestLaunchPreference.shouldOpenMainWindow()
apply(.launch)
// existing setup and controller installation
if shouldOpenMainWindow {
    openMainWindow()
}
```

- [ ] **Step 4: Add the settings control**

Add this stored property to `SessionNestStatusPopover`:

```swift
@AppStorage(SessionNestLaunchPreference.opensMainWindowKey)
private var opensMainWindowOnLaunch = false
```

Between the theme and update sections, add a **启动** heading, explanatory text, and:

```swift
Toggle("启动时默认打开主窗口", isOn: $opensMainWindowOnLaunch)
Text("下次启动时生效")
    .font(.caption)
    .foregroundStyle(.secondary)
```

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --no-parallel --filter launchMainWindowPreferenceDefaultsOffAndPersistsLocally
```

Expected: one test passes with zero failures.

- [ ] **Step 6: Document the behavior**

Add a README feature bullet explaining that users can choose menu-bar-only or main-window launch. Add an `Unreleased` changelog feature entry for the new local startup preference.

- [ ] **Step 7: Format and run the complete repository check**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift-format format --in-place --configuration .swift-format \
  Sources/SessionNest/SessionNestApp.swift \
  Sources/SessionNest/SessionNestStatusPopover.swift \
  Tests/SessionNestTests/SessionNestAppTests.swift
bash Scripts/check.sh
```

Expected: formatting succeeds and all tests pass with zero failures.

- [ ] **Step 8: Package, sign, and launch the local app**

Run:

```bash
bash Scripts/package-app.sh
codesign --verify --deep --strict --verbose=2 dist/SessionNest.app
pkill -x SessionNest || true
open dist/SessionNest.app
```

Expected: the release build succeeds, the ad-hoc signature is valid, and SessionNest runs from the new local bundle.

- [ ] **Step 9: Commit the implementation**

```bash
git add Sources/SessionNest/SessionNestApp.swift \
  Sources/SessionNest/SessionNestStatusPopover.swift \
  Tests/SessionNestTests/SessionNestAppTests.swift \
  README.md CHANGELOG.md
git commit -m "Add launch main window setting"
```
