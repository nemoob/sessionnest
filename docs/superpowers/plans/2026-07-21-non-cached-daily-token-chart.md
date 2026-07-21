# Non-Cached Daily Token Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the status popover's daily chart default to non-cached Token while preserving total and cached breakdowns in the selected-day detail.

**Architecture:** Keep the scanner, SQLite schema, and `StatisticsDailyPoint` unchanged. Add pure presentation helpers in `DailyTokenUsagePresentation`, then route bar labels, bar heights, accessibility copy, and selected-day detail through those helpers; keep the weekly quota row server-authoritative.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, AppKit packaging scripts.

## Global Constraints

- `nonCachedTokens = max(0, totalTokens - cachedInputTokens)`.
- Cache percentage is clamped to `0...100%` and is `0%` when total Token is zero.
- The current title is “本周期每日非缓存 Token”; fallback title is “最近 7 天每日非缓存 Token”.
- Do not modify token scanning, SQLite persistence, polling, refresh cadence, or main-window total Token statistics.
- The weekly quota percentage and reset time continue to use Codex server data.
- Add no dependencies, storage migrations, background work, or new files outside this plan and its approved design.

---

### Task 1: Add non-cached presentation metrics

**Files:**
- Modify: `Sources/SessionNest/DailyTokenUsageChart.swift:3-95`
- Test: `Tests/SessionNestTests/MenuBarStatusTests.swift:472-480`

**Interfaces:**
- Consumes: `TokenUsageBreakdown.totalTokens` and `TokenUsageBreakdown.cachedInputTokens`.
- Produces: `DailyTokenUsagePresentation.nonCachedTokens(_:) -> Int64` and `DailyTokenUsagePresentation.cachePercentageText(_:) -> String`.

- [ ] **Step 1: Write the failing presentation test**

Add this test to `Tests/SessionNestTests/MenuBarStatusTests.swift`:

```swift
@Test func dailyTokenUsagePresentationDerivesNonCachedUsageAndCacheShare() {
    let usage = TokenUsageBreakdown(
        inputTokens: 10_400_000_000,
        cachedInputTokens: 9_900_000_000,
        outputTokens: 100_000_000,
        reasoningOutputTokens: 20_000_000,
        totalTokens: 10_500_000_000
    )
    let invalid = TokenUsageBreakdown(
        inputTokens: 50,
        cachedInputTokens: 120,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 100
    )

    #expect(DailyTokenUsagePresentation.nonCachedTokens(usage) == 600_000_000)
    #expect(DailyTokenUsagePresentation.cachePercentageText(usage) == "94%")
    #expect(DailyTokenUsagePresentation.nonCachedTokens(invalid) == 0)
    #expect(DailyTokenUsagePresentation.cachePercentageText(invalid) == "100%")
    #expect(DailyTokenUsagePresentation.cachePercentageText(.zero) == "0%")
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter dailyTokenUsagePresentationDerivesNonCachedUsageAndCacheShare
```

Expected: compilation fails because `nonCachedTokens` and `cachePercentageText` do not exist.

- [ ] **Step 3: Implement the pure presentation helpers**

Add these methods to `DailyTokenUsagePresentation`:

```swift
static func nonCachedTokens(_ usage: TokenUsageBreakdown) -> Int64 {
    max(0, usage.totalTokens - usage.cachedInputTokens)
}

static func cachePercentageText(_ usage: TokenUsageBreakdown) -> String {
    guard usage.totalTokens > 0 else { return "0%" }
    let fraction = min(
        max(Double(usage.cachedInputTokens) / Double(usage.totalTokens), 0),
        1
    )
    return "\(Int((fraction * 100).rounded()))%"
}
```

- [ ] **Step 4: Run the test and verify GREEN**

Run the Step 2 command again.

Expected: the selected test passes with zero issues.

- [ ] **Step 5: Commit the metric helpers**

```bash
git add Sources/SessionNest/DailyTokenUsageChart.swift Tests/SessionNestTests/MenuBarStatusTests.swift
git commit -m "Derive non-cached daily Token metrics"
```

### Task 2: Use non-cached values throughout the compact chart

**Files:**
- Modify: `Sources/SessionNest/DailyTokenUsageChart.swift:97-268`
- Modify: `Sources/SessionNest/SessionNestStatusItemController.swift:57-82`
- Test: `Tests/SessionNestTests/MenuBarStatusTests.swift:472-525`
- Test: `Tests/SessionNestTests/SessionNestStatusItemControllerTests.swift:180-192`

**Interfaces:**
- Consumes: `DailyTokenUsagePresentation.nonCachedTokens(_:)` and `cachePercentageText(_:)` from Task 1.
- Produces: non-cached bar labels/heights, selected-day total/cache breakdown, and explicit non-cached titles and accessibility text.

- [ ] **Step 1: Update tests to describe the approved UI copy**

Update the existing expectations to require:

```swift
#expect(DailyTokenUsagePresentation.emptyText == "暂无每日非缓存 Token 记录")
#expect(
    DailyTokenUsagePresentation.observationCaption
        == "按本机日志估算非缓存 Token，不代表服务端额度消耗"
)
```

Update the two accessibility expectations to:

```swift
"今天，2026年7月21日，非缓存 12,345 Token"
"2026年7月19日，非缓存 8,765 Token"
```

Update the status scope expectations to:

```swift
#expect(current.dailyTokenTitle == "本周期每日非缓存 Token")
#expect(missing.dailyTokenTitle == "最近 7 天每日非缓存 Token")
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter dailyTokenUsage
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter statusPopoverStatisticsScopePrefersQuotaCycleAndLabelsFallback
```

Expected: the old total-Token copy causes expectation failures.

- [ ] **Step 3: Route chart labels and heights through non-cached values**

In `DailyTokenUsageChart`:

```swift
private var maximumObservedTokens: Int64 {
    usablePoints.map { DailyTokenUsagePresentation.nonCachedTokens($0.usage) }.max() ?? 0
}
```

Use `nonCachedTokens(point.usage)` for the compact label, `barHeight(tokens:maximum:)`, and accessibility label. Change the chart container accessibility label to `每日非缓存 Token` and the empty-day accessibility suffix to `无本地非缓存 Token 记录`.

- [ ] **Step 4: Render the selected-day breakdown**

Replace the selected detail with:

```swift
VStack(alignment: .leading, spacing: 4) {
    HStack(spacing: 8) {
        Text(
            DailyTokenUsagePresentation.dayLabel(
                selectedPoint.dayStart,
                now: now,
                calendar: calendar
            )
        )
        .fontWeight(.semibold)
        Spacer()
        Text(
            "非缓存 \(DailyTokenUsagePresentation.exactTokenText(
                DailyTokenUsagePresentation.nonCachedTokens(selectedPoint.usage)
            ))"
        )
        .monospacedDigit()
    }
    HStack(spacing: 8) {
        Text("总计 \(DailyTokenUsagePresentation.exactTokenText(selectedPoint.usage.totalTokens))")
        Spacer()
        Text(
            "缓存 \(DailyTokenUsagePresentation.exactTokenText(
                selectedPoint.usage.cachedInputTokens
            )) · \(DailyTokenUsagePresentation.cachePercentageText(selectedPoint.usage))"
        )
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
}
.font(.caption)
```

Change the idle detail text to `单击柱条查看非缓存、总计和缓存占比`.

- [ ] **Step 5: Update titles and explanatory copy**

In `StatusPopoverStatisticsScope.resolve`, replace the two daily titles with the exact strings in Global Constraints. In `DailyTokenUsagePresentation`, update `emptyText`, `observationCaption`, and `accessibilityLabel` so it prefixes the value with `非缓存`.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run both commands from Step 2.

Expected: all selected tests pass with zero issues.

- [ ] **Step 7: Commit the chart UI**

```bash
git add Sources/SessionNest/DailyTokenUsageChart.swift Sources/SessionNest/SessionNestStatusItemController.swift Tests/SessionNestTests/MenuBarStatusTests.swift Tests/SessionNestTests/SessionNestStatusItemControllerTests.swift
git commit -m "Show non-cached Token in daily chart"
```

### Task 3: Verify, package, and update the local app

**Files:**
- Verify: all tracked source and test changes from Tasks 1-2
- Build output: `dist/SessionNest.app` (ignored artifact)
- Install output: `/Applications/SessionNest.app`

**Interfaces:**
- Consumes: the completed chart UI from Task 2.
- Produces: a signed release build installed and running locally.

- [ ] **Step 1: Run full checks**

```bash
bash Scripts/check.sh
```

Expected: formatting succeeds and all Swift tests pass.

- [ ] **Step 2: Build and sign the app**

```bash
Scripts/package-app.sh
```

Expected: release build succeeds and `codesign --verify --deep --strict` passes inside the script.

- [ ] **Step 3: Replace and restart the local app safely**

Quit the running process, move the current app to a unique `/private/tmp/SessionNest-before-non-cached-chart.app` backup, copy `dist/SessionNest.app` to `/Applications/SessionNest.app`, and launch it. Do not delete the backup.

- [ ] **Step 4: Verify the installed artifact**

```bash
codesign --verify --deep --strict /Applications/SessionNest.app
shasum -a 256 dist/SessionNest.app/Contents/MacOS/SessionNest /Applications/SessionNest.app/Contents/MacOS/SessionNest
pgrep -fl SessionNest
```

Expected: signature verification exits 0, both SHA-256 values match, and the running process path is `/Applications/SessionNest.app/Contents/MacOS/SessionNest`.

- [ ] **Step 5: Confirm the worktree is clean**

```bash
git status --short
```

Expected: no output.
