# Daily Quota Usage Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 SessionNest 菜单栏弹框中展示本次每周额度周期内最近七个本地自然日的额度消耗百分比，并同时给出当天本地 Token 消耗作为参考。

**Architecture:** 继续复用现有十分钟 Codex App Server 额度刷新，将成功返回的每周 `usedPercent` 以十分钟桶写入 SessionNest 自有 SQLite；纯函数只对同一额度周期的相邻有效样本计算正向增量，再按本地自然日聚合。弹框用独立 Swift Charts 组件显示七日柱状图，不改主统计页，也不新增网络请求或定时器。

**Tech Stack:** Swift 6.2, SwiftUI, Swift Charts, SQLite3, Swift Testing

## Global Constraints

- Codex 数据始终只读；新增数据只写 SessionNest 自有 SQLite。
- 只记录 App Server 成功返回且含每周重置时间的真实额度快照，不用本地 Token 反推额度比例。
- 复用现有 10 分钟刷新定时器，不新增轮询、唤醒或网络请求。
- 同一十分钟桶只保留最新样本；SQLite 写入失败不得覆盖已成功刷新的额度，也不得把整个刷新标为失败。
- 只计算当前 `cycleResetsAt` 周期、截至 `now` 的样本；窗口最多覆盖最近 7 个本地自然日。
- 第一条样本仅建立基线；相邻样本正增量归到后一条样本的本地日期；比例回落视为新基线；间隔大于 30 分钟不归因；结果限制为 0...100。
- 不回填历史数据。无足够样本时显示“从现在开始记录每日额度变化”，不得把未知值显示成 0%。
- 弹框新增“本周期每日消耗”区块，位于每周额度条与重置卡片之间；主统计页默认 30 天保持不变。
- 图表固定展示当前周期内最近 7 个本地日期，今天高亮、其他日期弱化；支持悬停预览和点击固定选择；选择详情显示额度增量和该日本地 Token（若可用）。
- 保持弹框 420×620 和现有滚动行为；新增控件提供可读的 accessibility label。

---

### Task 1: Implement quota sample-to-daily aggregation

**Files:**
- Create: `Sources/SessionNest/QuotaUsageHistory.swift`
- Create: `Tests/SessionNestTests/QuotaUsageHistoryTests.swift`

- [ ] **Step 1: Write failing aggregation tests**

Add Swift Testing cases for: first sample as baseline, same-day positive deltas, midnight attribution to the later sample, percentage decrease as a new baseline, gaps over 1,800 seconds, filtering another cycle/future samples, 0...100 clamping, and retaining at most seven local dates.

Use a deterministic Gregorian calendar with a fixed time zone. The production interface must be:

```swift
struct QuotaUsageSample: Equatable, Sendable {
    let cycleResetsAt: Int64
    let capturedAt: Int64
    let usedPercent: Double
}

struct QuotaDailyUsagePoint: Equatable, Identifiable, Sendable {
    let dayStart: Int64
    let usedPercent: Double
    var id: Int64 { dayStart }
}

enum QuotaDailyUsage {
    static let maximumGap: Int64 = 30 * 60

    static func build(
        samples: [QuotaUsageSample],
        cycleResetsAt: Int64,
        now: Int64,
        calendar: Calendar
    ) -> [QuotaDailyUsagePoint]
}
```

- [ ] **Step 2: Run the focused test and capture RED evidence**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter QuotaUsageHistoryTests
```

Expected: compilation or test failure because the production types/logic do not exist yet.

- [ ] **Step 3: Implement the smallest pure aggregation function**

Sort qualifying samples by `capturedAt`; scan adjacent pairs. Skip non-finite values, future samples, nonmatching cycles, nonpositive deltas, and intervals outside `1...maximumGap`. Attribute a valid positive delta to the local start-of-day containing the later sample. Limit eligible dates to the intersection of the current cycle and the last seven local days. Clamp each daily total to 100.

- [ ] **Step 4: Run focused and full tests**

Run the focused command above, then:

```bash
bash Scripts/check.sh
```

Expected: all tests pass with clean output.

- [ ] **Step 5: Commit**

```bash
git add Sources/SessionNest/QuotaUsageHistory.swift Tests/SessionNestTests/QuotaUsageHistoryTests.swift
git commit -m "Add daily quota usage aggregation"
```

---

### Task 2: Persist weekly quota snapshots in MetadataStore

**Files:**
- Modify: `Sources/SessionNest/MetadataStore.swift`
- Modify: `Tests/SessionNestTests/MetadataStoreTests.swift`

- [ ] **Step 1: Write failing persistence tests**

Add tests proving that two samples in the same ten-minute bucket upsert to the latest `capturedAt` and value, different buckets remain ordered, different reset cycles are filtered, non-finite values are rejected, and opening an existing database adds the schema without losing existing metadata.

Required actor methods:

```swift
func saveQuotaUsageSample(_ sample: QuotaUsageSample) throws
func loadQuotaUsageSamples(cycleResetsAt: Int64) throws -> [QuotaUsageSample]
```

- [ ] **Step 2: Run focused test and capture RED evidence**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter MetadataStoreTests
```

Expected: compilation failure because the methods/schema are missing.

- [ ] **Step 3: Add additive schema and prepared statements**

Add to `createSchema`:

```sql
CREATE TABLE IF NOT EXISTS quota_usage_samples (
    cycle_resets_at INTEGER NOT NULL,
    captured_bucket INTEGER NOT NULL,
    captured_at INTEGER NOT NULL,
    used_percent REAL NOT NULL,
    PRIMARY KEY (cycle_resets_at, captured_bucket)
);
CREATE INDEX IF NOT EXISTS quota_usage_samples_cycle_time
ON quota_usage_samples(cycle_resets_at, captured_at);
```

Compute `captured_bucket` as `(capturedAt / 600) * 600`. Use `INSERT ... ON CONFLICT ... DO UPDATE`; load only the requested cycle ordered by `captured_at ASC`. Reject invalid timestamps or non-finite percentages, and clamp persisted percentages to 0...100.

- [ ] **Step 4: Run focused and full tests, then commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter MetadataStoreTests
bash Scripts/check.sh
git add Sources/SessionNest/MetadataStore.swift Tests/SessionNestTests/MetadataStoreTests.swift
git commit -m "Persist weekly quota snapshots"
```

---

### Task 3: Record samples through the existing refresh path

**Files:**
- Modify: `Sources/SessionNest/SessionListModel.swift`
- Modify: `Tests/SessionNestTests/SessionListModelTests.swift`

- [ ] **Step 1: Write failing model tests**

Add tests proving that two successful weekly snapshots ten minutes apart are persisted and publish a positive daily point, a snapshot without `resetsAt` is skipped, a failed App Server refresh records nothing, and the existing timer interval remains unchanged. Extend the existing weekly snapshot test helper with an optional reset timestamp rather than adding a parallel test fixture.

- [ ] **Step 2: Run focused test and capture RED evidence**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter SessionListModelTests
```

Expected: failure because the model does not expose or record daily quota points.

- [ ] **Step 3: Integrate persistence without changing refresh semantics**

Add:

```swift
@Published private(set) var quotaDailyUsagePoints: [QuotaDailyUsagePoint] = []
```

After a successful rate-limit read in both `refreshRateLimits(now:)` and the full reload flow, call one private async helper. The helper must guard a weekly window with a valid positive `resetsAt`, save the sample, reload the current cycle, and assign `QuotaDailyUsage.build(...)` on the main actor. Catch storage failures locally so current quota/account publication and `lastSuccessfulUsageRefreshAt` remain successful.

Use the current `now` supplied to manual refresh tests; do not call a second server API and do not create another timer.

- [ ] **Step 4: Run focused, schedule, and full tests, then commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter SessionListModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter SessionNestQuotaRefreshScheduleTests
bash Scripts/check.sh
git add Sources/SessionNest/SessionListModel.swift Tests/SessionNestTests/SessionListModelTests.swift
git commit -m "Record quota history during refresh"
```

---

### Task 4: Add the seven-day quota chart to the menu-bar popover

**Files:**
- Create: `Sources/SessionNest/QuotaDailyUsageChart.swift`
- Modify: `Sources/SessionNest/SessionNestStatusPopover.swift`
- Modify: `Sources/SessionNest/MenuBarStatus.swift`
- Modify: `Tests/SessionNestTests/MenuBarStatusTests.swift`

- [ ] **Step 1: Write failing presentation and selection tests**

Cover: ordered seven-day domain, today/yesterday Chinese labels, compact percentage formatting, unknown/empty text, nearest-point selection with outside-range clamping and earlier tie-breaking, selected point reconciliation, and the fixed compact chart height.

Keep pure behavior in small internal helpers (`QuotaDailyUsageChartSelection`, `QuotaDailyUsagePresentation`, or equivalent) so it is testable without SwiftUI snapshots. Do not make `TokenTrendChart` generic.

- [ ] **Step 2: Run focused test and capture RED evidence**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter MenuBarStatusTests
```

Expected: failure because the presentation/selection helpers do not exist.

- [ ] **Step 3: Build the focused chart component**

Implement a compact `BarMark` chart around 110 points high with a seven-day x-domain, weekday axis labels, nonzero percentage annotations, and accessibility labels such as “今天，消耗 3.2%”。Use the current quota semantic color for today and a quieter color for previous days.

Reuse the Token trend interaction pattern: hover previews the nearest point, click pins/unpins it, moving out clears only transient hover. Below the chart show the selected day’s quota delta and, when a matching `StatisticsDailyPoint` exists, the local Token count. Never substitute zero for missing quota or Token data.

For no usable deltas, show:

```text
从现在开始记录每日额度变化
```

Include a compact caption explaining that values come from locally observed Codex quota snapshots and cannot reconstruct earlier usage.

- [ ] **Step 4: Insert it in the popover**

In `SessionNestStatusPopover`, place “本周期每日消耗” immediately after the weekly `quotaRow` and before reset-credit details. Pass `model.quotaDailyUsagePoints`, existing daily statistics, the current time/calendar, and the weekly quota color. Preserve the existing 420×620 frame and ScrollView.

- [ ] **Step 5: Run focused and full tests, then commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter MenuBarStatusTests
bash Scripts/check.sh
git add Sources/SessionNest/QuotaDailyUsageChart.swift Sources/SessionNest/SessionNestStatusPopover.swift Sources/SessionNest/MenuBarStatus.swift Tests/SessionNestTests/MenuBarStatusTests.swift
git commit -m "Show daily quota usage in menu popover"
```

---

### Task 5: Verify packaging and update the local app

**Files:**
- Verify only unless packaging exposes a defect.

- [ ] **Step 1: Run complete verification**

```bash
bash Scripts/check.sh
bash Scripts/package-app.sh
codesign --verify --deep --strict dist/SessionNest.app
```

Expected: all tests pass, packaging succeeds, and the app verifies.

- [ ] **Step 2: Install and smoke-check locally**

Quit the running SessionNest, replace `/Applications/SessionNest.app` with the packaged app using the repository’s existing install workflow, launch it normally, and verify the menu-bar popover opens. Trigger one existing refresh and confirm the self-owned SQLite contains one current-cycle sample; the chart may legitimately show the empty-state until a later valid sample arrives.

- [ ] **Step 3: Final branch review**

Review the full branch diff against the approved design, rerun any focused test needed by concrete findings, and leave the branch ready for the user to decide whether to merge/publish. Do not push or create a GitHub release in this task.
