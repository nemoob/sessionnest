# Daily Update Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an energy-efficient daily GitHub Release check that shows new-version notices in the SessionNest menu bar popover without downloading or installing executable code.

**Architecture:** A focused `AppUpdateChecker` parses semantic versions, persists lightweight scheduling preferences in `UserDefaults`, and fetches GitHub's latest stable Release through an injected async request closure. The app delegate owns one checker, automatic triggers share a rolling 24-hour throttle, and the existing status popover observes the checker for its notice and settings controls.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Foundation `URLSession`, Swift Testing, `UserDefaults`; no new package dependency.

## Global Constraints

- Support macOS 14 or later.
- Check `https://api.github.com/repos/nemoob/sessionnest/releases/latest` only.
- Perform at most one automatic request per rolling 24-hour period.
- Do not download, replace, relaunch, or silently install the application.
- Do not add Sparkle, an appcast, a website feed, telemetry, or any package dependency.
- Accept only HTTPS release-page URLs hosted by `github.com`.
- Keep automatic failures silent; expose manual-check results in settings.
- Preserve the existing menu bar label width.

---

### Task 1: Version, Release, and Scheduling Model

**Files:**
- Create: `Sources/SessionNest/AppUpdateChecker.swift`
- Create: `Tests/SessionNestTests/AppUpdateCheckerTests.swift`

**Interfaces:**
- Produces: `AppVersion.init?(tag:)`, `AppVersion.current`, `GitHubRelease`, `AppUpdate`, `AppUpdateCheckState`, `AppUpdateCheckTrigger`, and `AppUpdatePreferences`.
- Consumes: Foundation `Bundle`, `URL`, `UserDefaults`, and `Date`.

- [ ] **Step 1: Write failing version and schedule tests**

```swift
import Foundation
import Testing

@testable import SessionNest

@Test func appVersionUsesNumericSemanticOrdering() {
    #expect(AppVersion(tag: "v0.2.10")! > AppVersion(tag: "0.2.9")!)
    #expect(AppVersion(tag: "1.0.0") == AppVersion(tag: "v1.0.0"))
    #expect(AppVersion(tag: "1.2") == nil)
    #expect(AppVersion(tag: "1.2.beta") == nil)
}

@Test func automaticUpdateScheduleUsesRollingTwentyFourHours() {
    let lastAttempt = Date(timeIntervalSince1970: 1_000)
    #expect(!AppUpdateSchedule.isDue(lastAttempt: lastAttempt, now: lastAttempt.addingTimeInterval(86_399)))
    #expect(AppUpdateSchedule.isDue(lastAttempt: lastAttempt, now: lastAttempt.addingTimeInterval(86_400)))
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter 'appVersion|automaticUpdateSchedule'
```

Expected: compilation fails because `AppVersion` and `AppUpdateSchedule` do not exist.

- [ ] **Step 3: Implement the minimal value types and preferences**

```swift
import Foundation

struct AppVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(tag: String) {
        let normalized = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0, minor >= 0, patch >= 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

enum AppUpdateSchedule {
    static let interval: TimeInterval = 24 * 60 * 60

    static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= interval
    }
}
```

Add `GitHubRelease` with coding keys for `tag_name`, `html_url`, `name`, and `body`; add `AppUpdate`; add the observable presentation state; and store `automaticallyChecksForUpdates`, `lastAutomaticCheckAt`, and `ignoredVersion` under `sessionnest.update.*` keys. A missing automatic-check preference returns `true`.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the Step 2 command. Expected: both tests pass.

- [ ] **Step 5: Commit the model**

```bash
git add Sources/SessionNest/AppUpdateChecker.swift Tests/SessionNestTests/AppUpdateCheckerTests.swift
git commit -m "Add app update model"
```

---

### Task 2: GitHub Release Checker

**Files:**
- Modify: `Sources/SessionNest/AppUpdateChecker.swift`
- Modify: `Tests/SessionNestTests/AppUpdateCheckerTests.swift`

**Interfaces:**
- Consumes: Task 1's value types and preferences.
- Produces: `@MainActor final class AppUpdateChecker: ObservableObject`, `check(_:)`, `setAutomaticChecksEnabled(_:)`, and `ignoreAvailableVersion()`.

- [ ] **Step 1: Write failing checker behavior tests**

Add tests using an ephemeral `UserDefaults` suite and an injected request closure:

```swift
@MainActor
@Test func automaticChecksThrottleRequestsAndManualChecksBypassThrottle() async throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    var requestCount = 0
    let checker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.3")!,
        preferences: AppUpdatePreferences(defaults: defaults),
        now: { Date(timeIntervalSince1970: 1_000) },
        fetch: { _ in
            requestCount += 1
            return GitHubRelease.test(tag: "v0.2.3")
        }
    )

    await checker.check(.automatic)
    await checker.check(.automatic)
    #expect(requestCount == 1)
    await checker.check(.manual)
    #expect(requestCount == 2)
}
```

Also test: newer release becomes available, current/older release becomes up to date, ignored version stays hidden, a later version reappears, concurrent checks coalesce, invalid GitHub URL fails, automatic failure is silent, and manual failure is visible.

- [ ] **Step 2: Run checker tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter AppUpdateCheckerTests
```

Expected: compilation fails because `AppUpdateChecker` behavior is not implemented.

- [ ] **Step 3: Implement the checker**

Use this public surface:

```swift
@MainActor
final class AppUpdateChecker: ObservableObject {
    typealias Fetch = @Sendable (URLRequest) async throws -> GitHubRelease

    @Published private(set) var state: AppUpdateCheckState = .idle
    @Published private(set) var automaticallyChecksForUpdates: Bool

    func check(_ trigger: AppUpdateCheckTrigger) async
    func setAutomaticChecksEnabled(_ isEnabled: Bool)
    func ignoreAvailableVersion()
}
```

For automatic checks: guard that the setting is enabled, the schedule is due, and no request is in flight; persist the attempt time immediately before starting the network request. For manual checks: bypass scheduling but still coalesce with an active request. Preserve an existing available update when a later request fails. Validate that the release URL uses HTTPS and that its lowercase host is exactly `github.com`.

Production fetching builds one `URLRequest` with `Accept: application/vnd.github+json` and `User-Agent: SessionNest/<current version>`, calls `URLSession.shared.data(for:)`, requires status `200...299`, and decodes `GitHubRelease` with `JSONDecoder`.

- [ ] **Step 4: Run checker tests and verify GREEN**

Run the Step 2 command. Expected: all `AppUpdateCheckerTests` pass.

- [ ] **Step 5: Commit the checker**

```bash
git add Sources/SessionNest/AppUpdateChecker.swift Tests/SessionNestTests/AppUpdateCheckerTests.swift
git commit -m "Check GitHub releases daily"
```

---

### Task 3: App Lifecycle and Popover Integration

**Files:**
- Modify: `Sources/SessionNest/SessionNestApp.swift`
- Modify: `Sources/SessionNest/SessionNestStatusItemController.swift`
- Modify: `Sources/SessionNest/SessionNestStatusPopover.swift`
- Modify: `Tests/SessionNestTests/SessionNestStatusItemControllerTests.swift`

**Interfaces:**
- Consumes: one shared `AppUpdateChecker` created by `SessionNestAppDelegate`.
- Produces: launch and popover automatic triggers, an update banner, and settings controls.

- [ ] **Step 1: Write failing popover view-state tests**

Add a small pure formatter/state projection and tests:

```swift
@Test func updateNoticeAppearsOnlyForAvailableRelease() {
    let update = AppUpdate(
        version: AppVersion(tag: "0.2.4")!,
        tagName: "v0.2.4",
        releaseURL: URL(string: "https://github.com/nemoob/sessionnest/releases/tag/v0.2.4")!,
        summary: "Daily update checking"
    )
    #expect(AppUpdateNotice.resolve(.available(update))?.title == "发现新版本 v0.2.4")
    #expect(AppUpdateNotice.resolve(.upToDate) == nil)
    #expect(AppUpdateNotice.resolve(.idle) == nil)
}
```

- [ ] **Step 2: Run the focused UI-state test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter updateNoticeAppearsOnlyForAvailableRelease
```

Expected: compilation fails because `AppUpdateNotice` does not exist.

- [ ] **Step 3: Wire the shared checker through the app**

Create the checker in `SessionNestAppDelegate.applicationDidFinishLaunching`, retain it, pass it into `SessionNestStatusItemController(model:updateChecker:)`, and start one `Task` calling `check(.automatic)` after the status item is installed.

When the popover opens, call `check(.automatic)` alongside the existing lightweight quota and stale-session refreshes. Pass the checker into `SessionNestStatusPopover` so its state survives popover recreation.

- [ ] **Step 4: Add the banner and settings**

Below the overview header, render a compact rounded banner only when `AppUpdateNotice.resolve(updateChecker.state)` is non-nil. `查看更新` calls `openURL(update.releaseURL)` and `忽略此版本` calls `ignoreAvailableVersion()`.

Below the theme picker, add an `更新` section containing:

```swift
Toggle(
    "每天自动检查更新",
    isOn: Binding(
        get: { updateChecker.automaticallyChecksForUpdates },
        set: { updateChecker.setAutomaticChecksEnabled($0) }
    )
)

Button("立即检查") {
    Task { await updateChecker.check(.manual) }
}
.disabled(updateChecker.state.isChecking)
```

Render `正在检查…`, `已是最新版本`, available-version text, or the manual failure text directly below the button. Do not alter `SessionNestStatusLabelLayout.statusItemLength`.

- [ ] **Step 5: Run focused and full tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter updateNoticeAppearsOnlyForAvailableRelease
bash Scripts/check.sh
```

Expected: the focused test passes and the complete suite has zero failures.

- [ ] **Step 6: Commit the UI integration**

```bash
git add Sources/SessionNest/SessionNestApp.swift Sources/SessionNest/SessionNestStatusItemController.swift Sources/SessionNest/SessionNestStatusPopover.swift Tests/SessionNestTests/SessionNestStatusItemControllerTests.swift
git commit -m "Show available SessionNest updates"
```

---

### Task 4: Documentation, Packaging, and Local Verification

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify only when publishing is explicitly authorized: `Resources/Info.plist`

**Interfaces:**
- Consumes: completed feature and existing package scripts.
- Produces: verified local app bundle; publishing remains a separate explicit action.

- [ ] **Step 1: Document the feature and privacy boundary**

Add to README features that SessionNest checks the latest stable GitHub Release at most once per 24 hours and never uploads local session data. Add an unreleased changelog entry describing the update notice and manual check.

- [ ] **Step 2: Run final source verification**

Run:

```bash
git diff --check
bash Scripts/check.sh
```

Expected: clean diff check and zero test failures.

- [ ] **Step 3: Build and verify the app bundle**

Run:

```bash
bash Scripts/package-app.sh
codesign --verify --deep --strict --verbose=2 dist/SessionNest.app
/usr/libexec/PlistBuddy -c 'Print :LSUIElement' dist/SessionNest.app/Contents/Info.plist
```

Expected: production build succeeds, signature is valid, and `LSUIElement` is `true`.

- [ ] **Step 4: Verify energy and interaction behavior**

Launch the packaged app, confirm no main window or Dock icon at startup, open the menu bar popover, confirm the update controls appear in settings, and close the popover. Use an injected test response rather than publishing a fake GitHub Release to validate the new-version banner.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md CHANGELOG.md
git commit -m "Document update checking"
```

- [ ] **Step 6: Report the publishing boundary**

Report the local commit, test count, app bundle path, and that no GitHub push, tag, Release, or remote client update occurred unless the user separately authorized publishing.
