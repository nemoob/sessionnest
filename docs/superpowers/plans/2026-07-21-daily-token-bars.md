# Daily Token Bars Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the misleading daily quota-percentage display with seven daily bars based on locally measured Token usage, while leaving the server-authoritative weekly quota unchanged.

**Architecture:** Reuse `StatusPopoverStatisticsScope.snapshot.dailyPoints` as the only data source for the compact bars. Keep the view as plain SwiftUI buttons to avoid the previous Swift Charts popover crash, and remove the unmerged quota-snapshot persistence pipeline without dropping an existing local table.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, SQLite3, macOS 14+

## Global Constraints

- Weekly remaining percentage and reset time continue to come only from Codex App Server.
- Daily bars use `StatisticsDailyPoint.usage.totalTokens`; no Token-to-quota conversion is allowed.
- Current quota-cycle statistics are preferred, with the existing recent-seven-days snapshot as fallback.
- Add no polling, network request, log scan, dependency, or database table.
- Do not execute `DROP TABLE`; an existing `quota_usage_samples` table must remain untouched.
- Keep the usage-refresh generation guard.

---

### Task 1: Specify the daily Token presentation

**Files:**
- Modify: `Tests/SessionNestTests/MenuBarStatusTests.swift`
- Modify: `Tests/SessionNestTests/SessionNestStatusItemControllerTests.swift`
- Create: `Sources/SessionNest/DailyTokenUsageChart.swift`
- Delete: `Sources/SessionNest/QuotaDailyUsageChart.swift`

**Interfaces:**
- Consumes: `StatisticsDailyPoint`, `TokenUsageBreakdown`, `StatusPopoverStatisticsScope`
- Produces: `DailyTokenUsagePresentation`, `DailyTokenUsageSelection`, `DailyTokenUsageChart`, and `StatusPopoverStatisticsScope.dailyTokenTitle`

- [x] **Step 1: Replace percentage expectations with failing Token expectations**

Add tests that require:

```swift
#expect(DailyTokenUsagePresentation.compactTokenText(10_000) == "1万")
#expect(DailyTokenUsagePresentation.exactTokenText(12_345) == "12,345 Token")
#expect(DailyTokenUsagePresentation.emptyText == "暂无每日 Token 记录")
#expect(
    DailyTokenUsagePresentation.observationCaption
        == "按本机可读取的 Codex 会话记录统计，不代表服务端额度消耗"
)
#expect(DailyTokenUsagePresentation.barHeight(tokens: 2, maximum: 10) == 12.4)
#expect(
    DailyTokenUsagePresentation.accessibilityLabel(
        dayStart: today,
        tokens: 12_345,
        now: now,
        calendar: calendar
    ) == "今天，2026年7月21日，12,345 Token"
)
```

Update selection tests to use `[StatisticsDailyPoint]`, and extend the scope test with:

```swift
#expect(current.dailyTokenTitle == "本周期每日 Token")
#expect(missing.dailyTokenTitle == "最近 7 天每日 Token")
```

- [x] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'quotaDailyUsage|statusPopoverStatisticsScope'`

Expected: compilation fails because `DailyTokenUsagePresentation` and `dailyTokenTitle` do not exist.

- [x] **Step 3: Implement the minimal Token presentation and chart**

Create `DailyTokenUsageChart.swift` by adapting the existing plain SwiftUI seven-day bar view so it:

```swift
struct DailyTokenUsageChart: View {
    let points: [StatisticsDailyPoint]
    let now: Int64
    let calendar: Calendar
}
```

Filters the fixed seven-day domain, ignores non-positive values, scales bars by the largest visible `totalTokens`, uses `Color.accentColor` for today and reduced opacity for earlier days, lets a button select or clear a day, and shows the exact Token total below the bars. Implement the tested formatter, accessibility, domain, and selection helpers under `DailyTokenUsagePresentation` and `DailyTokenUsageSelection`.

Add `dailyTokenTitle` to both branches of `StatusPopoverStatisticsScope.resolve`.

- [x] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter 'quotaDailyUsage|statusPopoverStatisticsScope'`

Expected: all selected tests pass.

### Task 2: Wire the popover to local daily Token data

**Files:**
- Modify: `Sources/SessionNest/SessionNestStatusPopover.swift`

**Interfaces:**
- Consumes: `statisticsScope.dailyTokenTitle`, `statistics.dailyPoints`, `DailyTokenUsageChart`
- Produces: a compact daily Token section immediately below the weekly quota row

- [x] **Step 1: Update the popover call site**

Replace the quota-history section with:

```swift
Text(statisticsScope.dailyTokenTitle)
    .font(.subheadline.weight(.semibold))
DailyTokenUsageChart(
    points: statistics.dailyPoints,
    now: now,
    calendar: calendar
)
```

Keep `quotaRow`, reset credits, statistics cards, and the lower `TokenTrendChart` unchanged.

- [x] **Step 2: Run the focused UI-model tests**

Run: `swift test --filter 'MenuBarStatusTests|SessionNestStatusItemControllerTests'`

Expected: all selected tests pass.

### Task 3: Retire the quota-snapshot pipeline

**Files:**
- Delete: `Sources/SessionNest/QuotaUsageHistory.swift`
- Delete: `Tests/SessionNestTests/QuotaUsageHistoryTests.swift`
- Modify: `Sources/SessionNest/MetadataStore.swift`
- Modify: `Sources/SessionNest/SessionListModel.swift`
- Modify: `Tests/SessionNestTests/MetadataStoreTests.swift`
- Modify: `Tests/SessionNestTests/SessionListModelTests.swift`

**Interfaces:**
- Preserves: `beginUsageRefresh()`, `acceptsUsageRefresh(_:)`, `refreshQuotaCycleStatistics(acceptingUsageGeneration:)`
- Removes: `QuotaUsageSample`, `QuotaDailyUsagePoint`, quota sample store methods/schema, `quotaDailyUsagePoints`, `quotaDailyUsageCycleResetsAt`, and `recordQuotaUsage`

- [x] **Step 1: Remove obsolete test expectations**

Delete tests dedicated only to quota snapshot aggregation, persistence, schema creation, and model publication. Preserve all tests that verify refresh de-duplication, generation ordering, server quota publication, error state, and quota-cycle Token statistics.

- [x] **Step 2: Remove obsolete production code**

Remove quota-history types, store methods, `invalidQuotaUsageSample`, new-database schema statements, model state, record calls, and the private recorder. Do not add a migration or `DROP TABLE` statement, so an existing table remains physically untouched.

- [x] **Step 3: Prove no rejected pipeline remains**

Run:

```bash
rg -n "QuotaUsageSample|QuotaDailyUsage|quotaDailyUsage|quota_usage_samples|invalidQuotaUsageSample" Sources Tests
```

Expected: no matches.

- [x] **Step 4: Run model and store tests**

Run: `swift test --filter 'SessionListModelTests|MetadataStoreTests'`

Expected: all selected tests pass, including refresh-generation coverage.

### Task 4: Verify, package, and install

**Files:**
- Modify: `docs/superpowers/plans/2026-07-21-daily-token-bars.md` only to check completed steps
- Generated: `dist/SessionNest.app`

**Interfaces:**
- Produces: a formatted, tested, signed local application

- [x] **Step 1: Run the full quality gate**

Run: `bash Scripts/check.sh`

Expected: strict Swift formatting lint passes and the full serialized test suite passes.

- [x] **Step 2: Package and verify signing**

Run:

```bash
bash Scripts/package-app.sh
codesign --verify --deep --strict dist/SessionNest.app
```

Expected: packaging succeeds and `codesign` exits 0.

- [x] **Step 3: Update the local installed client**

Quit the running SessionNest process, replace `/Applications/SessionNest.app` with the packaged app, launch it, and verify the running executable resolves inside `/Applications/SessionNest.app`.

- [x] **Step 4: Verify status-item stability**

Open and close the status popover repeatedly, confirm the daily Token bars and exact detail appear, and confirm no new SessionNest crash report was created.

- [x] **Step 5: Commit the implementation**

Run:

```bash
git add Sources Tests docs/superpowers/plans/2026-07-21-daily-token-bars.md
git commit -m "Show daily Token usage in status popover"
```

Expected: commit succeeds with only the designed replacement and cleanup.
