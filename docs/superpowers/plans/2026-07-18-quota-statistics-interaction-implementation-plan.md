# Quota Statistics and Detail Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Precisely reset local quota-cycle Token statistics at server-provided second-level boundaries, add selectable Token trend details, and display reset-credit counts and expirations.

**Architecture:** Keep the v0.1.2 daily cache intact while adding a timestamped Token-delta table for exact cycle queries. Publish a single account-usage snapshot containing rate limits and reset credits, and share chart selection/detail behavior between the dashboard and status popover.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Charts, AppKit, SQLite3, Swift Testing, macOS 14+

## Global Constraints

- Work on the existing `suqing/codex-scratch-project-classification` branch.
- Preserve every v0.1.2 SQLite table, column, primary key, and write path.
- Add schema only with `CREATE TABLE IF NOT EXISTS`; do not require deleting `manager.sqlite`.
- Continue populating `thread_token_daily` so v0.1.2 can ignore the new table and operate normally.
- Store and display all times in Unix seconds internally and the current local timezone in UI copy.
- Do not add reset-credit consumption actions.
- Keep SessionNest local-first and telemetry-free.

---

### Task 1: Timestamped Token deltas and additive SQLite migration

**Files:**
- Modify: `Sources/SessionNest/ThreadTokenUsage.swift`
- Modify: `Sources/SessionNest/MetadataStore.swift`
- Modify: `Sources/SessionNest/SessionListModel.swift`
- Test: `Tests/SessionNestTests/ThreadTokenUsageTests.swift`
- Test: `Tests/SessionNestTests/MetadataStoreTests.swift`

**Interfaces:**
- Produces: `ThreadTokenTimedUsage`, `TokenScanState.timedUsage`, and `MetadataStore.loadThreadTokenTimedUsage(startingAt:endingAt:)`.
- Preserves: `TokenScanState.dailyUsage`, `thread_token_daily`, and existing v0.1.2 cache behavior.

- [ ] **Step 1: Write scanner tests for second-level positive deltas**

Add a fixture with positive `token_count` changes before and after a midday boundary, including two changes in the same second. Assert `timedUsage` preserves timestamps, aggregates duplicate seconds, and still produces the unchanged daily total.

- [ ] **Step 2: Run the focused scanner test and verify it fails**

Run: `xcrun swift test --filter ThreadTokenUsageTests`

Expected: failure because `TokenScanState` has no timestamped usage.

- [ ] **Step 3: Add timestamped scan output**

Add `timedUsage: [Int64: TokenUsageBreakdown]` to `TokenScanState`. When `positiveDelta` is nonzero, accumulate it under the event's Unix second as well as the local natural day. Keep append baselines empty for both incremental collections so only newly scanned bytes are persisted.

- [ ] **Step 4: Add migration and persistence tests**

Create a database with the existing schema path, save a scan containing daily and timestamped usage, then assert:

- old tables and columns still exist;
- `thread_token_daily` still contains the expected row;
- the new time-bounded loader includes only rows at or after the exact boundary;
- rebuilding one thread replaces both its daily and timed rows without affecting another thread.

- [ ] **Step 5: Run the focused store tests and verify they fail**

Run: `xcrun swift test --filter MetadataStoreTests`

Expected: failure because `thread_token_timed` and its loader do not exist.

- [ ] **Step 6: Implement the additive table and loader**

Create `thread_token_timed` with columns matching the existing Token breakdown and primary key `(thread_id, event_at)`, plus an `event_at` index. On rebuild, delete that thread's old timed rows in the same transaction used for daily rows. On append, upsert by adding each component. Do not alter existing table definitions.

- [ ] **Step 7: Bump the Token parser version and run focused tests**

Increase `SessionListModel.tokenParserVersion` so existing v0.1.2 caches rebuild and populate the new table.

Run: `xcrun swift test --filter ThreadTokenUsageTests && xcrun swift test --filter MetadataStoreTests`

Expected: both suites pass.

### Task 2: Exact quota-cycle snapshot publication

**Files:**
- Modify: `Sources/SessionNest/ThreadTokenUsage.swift`
- Modify: `Sources/SessionNest/SessionStatistics.swift`
- Modify: `Sources/SessionNest/SessionListModel.swift`
- Modify: `Sources/SessionNest/SessionNestStatusItemController.swift`
- Test: `Tests/SessionNestTests/ThreadTokenUsageTests.swift`
- Test: `Tests/SessionNestTests/SessionStatisticsTests.swift`
- Test: `Tests/SessionNestTests/SessionListModelTests.swift`

**Interfaces:**
- Consumes: `MetadataStore.loadThreadTokenTimedUsage(startingAt:endingAt:)`.
- Produces: exact `QuotaCycleWindow.startTimestamp`, published `quotaCycleStatisticsSnapshot`, and `quotaCycleTokenUsage`.

- [ ] **Step 1: Write exact-boundary and offline-rebuild tests**

Assert a cycle starting at 11:24:52 excludes an 11:24:51 delta and includes 11:24:52 plus later deltas. Add a model test where timed rows already exist before rate limits load, then assert refreshing rate limits publishes the correct snapshot without changing `timeFilter`.

- [ ] **Step 2: Run focused model tests and verify they fail**

Run: `xcrun swift test --filter quotaCycle`

Expected: existing day-level implementation includes pre-reset usage or lacks the published snapshot.

- [ ] **Step 3: Implement exact cycle aggregation**

Replace `startDay` as the filtering boundary with `startTimestamp`. Convert already-filtered timed rows into the existing statistics inputs by grouping them into local days and threads. Publish cycle statistics after rate-limit refresh and after Token scan publication; clear it only when window metadata is incomplete.

- [ ] **Step 4: Keep status UI on a stable published snapshot**

Change menu status builders to consume the published cycle snapshot and total instead of recalculating from all daily rows during every SwiftUI body evaluation. Preserve the existing seven-day fallback.

- [ ] **Step 5: Run quota and statistics suites**

Run: `xcrun swift test --filter quotaCycle && xcrun swift test --filter SessionStatisticsTests && xcrun swift test --filter SessionNestStatusItemControllerTests`

Expected: all selected tests pass.

### Task 3: Decode and present reset-credit availability

**Files:**
- Modify: `Sources/SessionNest/CodexClient.swift`
- Modify: `Sources/SessionNest/SessionListModel.swift`
- Modify: `Sources/SessionNest/MenuBarStatus.swift`
- Modify: `Sources/SessionNest/SessionNestStatusPopover.swift`
- Test: `Tests/SessionNestTests/CodexClientTests.swift`
- Test: `Tests/SessionNestTests/MenuBarStatusTests.swift`

**Interfaces:**
- Produces: `CodexUsageSnapshot`, `RateLimitResetCreditsSummary`, `RateLimitResetCredit`, and UI-ready reset-credit status.
- Preserves: `CodexRateLimitSnapshot.weeklyWindow` and existing rate-limit formatting.

- [ ] **Step 1: Write response decoding tests**

Extend the fake App Server response with `rateLimitResetCredits`, including available, consumed, expired, missing, and unsorted examples. Assert all fields decode and missing summaries remain `nil` rather than becoming zero.

- [ ] **Step 2: Run focused client tests and verify they fail**

Run: `xcrun swift test --filter CodexClientTests`

Expected: failure because `readRateLimits()` discards reset-credit data.

- [ ] **Step 3: Publish a unified account-usage snapshot**

Return rate limits and optional reset credits from the same request. Update full reload and the coalesced lightweight refresh atomically. Keep the previous successful snapshot on errors. Trigger the lightweight refresh whenever the status popover opens, in addition to the existing timer.

- [ ] **Step 4: Write reset-credit formatting tests**

Assert available count, nearest expiration, local-time formatting, zero state, missing state, and stable sorting. Verify internal IDs never enter user-facing strings.

- [ ] **Step 5: Implement summary and detail page**

Add a clickable summary below the weekly quota progress row and a `resetCredits` popover page with a back button and cards ordered by expiration. Display only information returned by the server and do not add a consume button.

- [ ] **Step 6: Run client and status tests**

Run: `xcrun swift test --filter CodexClientTests && xcrun swift test --filter MenuBarStatusTests && xcrun swift test --filter SessionNestStatusItemControllerTests`

Expected: all selected tests pass.

### Task 4: Selectable Token trend details

**Files:**
- Create: `Sources/SessionNest/TokenTrendSelection.swift`
- Create: `Sources/SessionNest/TokenTrendChart.swift`
- Modify: `Sources/SessionNest/StatisticsDashboardView.swift`
- Modify: `Sources/SessionNest/SessionNestStatusPopover.swift`
- Test: `Tests/SessionNestTests/TokenTrendSelectionTests.swift`

**Interfaces:**
- Produces: pure nearest-point and selection-reconciliation helpers plus shared chart rendering.
- Consumes: `[StatisticsDailyPoint]` and a compact/full presentation style.

- [ ] **Step 1: Write pure selection tests**

Assert nearest-date resolution before, between, and after points; empty data; a single point; tie-breaking; and clearing a fixed selection after its date disappears.

- [ ] **Step 2: Run the selection tests and verify they fail**

Run: `xcrun swift test --filter TokenTrendSelectionTests`

Expected: failure because the selection helper does not exist.

- [ ] **Step 3: Implement selection state and chart overlay**

Use `ChartProxy` in `chartOverlay` to map pointer X coordinates to dates. Maintain hover and fixed selections, render a `RuleMark` and two `PointMark`s for the effective date, and expose accessibility actions for previous, next, and clear.

- [ ] **Step 4: Add complete and compact detail presentations**

Show date, total, input, cached input, output, and reasoning output. Use a full grid under the dashboard chart and a compact two-row layout under the popover chart. Keep single-day charts selectable.

- [ ] **Step 5: Run selection and existing UI-model tests**

Run: `xcrun swift test --filter TokenTrendSelectionTests && xcrun swift test --filter MenuBarStatusTests && xcrun swift test --filter SessionNestStatusItemControllerTests`

Expected: all selected tests pass.

### Task 5: Documentation, compatibility verification, and full validation

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: files from Tasks 1-4 only if validation finds defects

**Interfaces:**
- Consumes: all prior tasks.
- Produces: user-facing documentation and release-ready verification evidence.

- [ ] **Step 1: Update documentation**

Document exact quota-cycle local Token statistics, selectable daily details, and read-only reset-credit visibility. Add feature, optimization, and bug-fix entries under the existing unreleased section.

- [ ] **Step 2: Run formatting and full test checks**

Run: `bash Scripts/check.sh`

Expected: formatting validation, build, and the complete Swift test suite pass.

- [ ] **Step 3: Package and launch-check the app**

Run: `bash Scripts/package-app.sh`

Expected: an ad-hoc signed `dist/SessionNest.app` is produced successfully. Packaging overwrites only the generated `dist/SessionNest.app` artifact.

- [ ] **Step 4: Inspect final schema and Git diff**

Verify the schema contains every v0.1.2 table unchanged plus only the new timed table/index. Review `git diff --check`, `git diff --stat`, and `git status --short` for unintended files.

- [ ] **Step 5: Commit the completed feature**

Stage only the implementation, tests, README, CHANGELOG, and approved spec/plan files, then commit with a concise English message describing quota-cycle accuracy and interactive details.
