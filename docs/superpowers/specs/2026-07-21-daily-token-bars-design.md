# SessionNest Daily Token Bars Design

## Status

This design supersedes the daily quota-percentage chart in
`2026-07-21-daily-quota-usage-chart-design.md` before that feature is merged or released.

## Goal

Keep the weekly quota row authoritative and easy to understand while replacing the inaccurate
daily quota-percentage chart with a compact seven-day view of locally measured Token usage.

## Considered Approaches

1. **Use existing daily Token statistics — recommended.** Reuse the same current-cycle
   `StatisticsSnapshot.dailyPoints` already shown in the popover. This is locally measurable,
   supports historical days, adds no network request or scan, and does not pretend Token maps
   linearly to server quota.
2. **Continue using server quota snapshot deltas.** This is accurate only while the app samples
   continuously and cannot reconstruct usage before installation or across gaps. It produced the
   misleading 1% result and is rejected.
3. **Estimate daily quota percentage from Token proportions.** Server quota weighting is not a
   fixed public Token bucket, so the result would look precise without being authoritative. This
   is rejected.

## Data and Scope

- The weekly remaining percentage and reset time continue to come only from Codex App Server.
- The daily bars consume the existing statistics scope selected by
  `StatusPopoverStatisticsScope`:
  - current quota-cycle statistics when the reset boundary is available;
  - the existing recent-seven-days fallback when it is not.
- Each bar uses `StatisticsDailyPoint.usage.totalTokens` for its local day.
- Unknown days remain empty; they are not displayed as zero usage.
- No Token-to-quota conversion, new polling, network request, log scan, or database table is added.

## Popover UI

- Replace “本周期每日消耗” with a scope-aware title:
  - “本周期每日 Token” for a known quota cycle;
  - “最近 7 天每日 Token” for fallback data.
- Render seven plain SwiftUI bars, not a second Swift Charts graph. This preserves the crash fix
  for the macOS status popover.
- Use compact Chinese Token labels above nonempty bars, weekday labels below, and accent-color
  emphasis for today.
- Clicking a bar selects or clears it and shows the exact local Token count for that date.
- Empty text: “暂无每日 Token 记录”.
- Caption: “按本机可读取的 Codex 会话记录统计，不代表服务端额度消耗”.
- Keep the existing weekly quota row, reset-card section, statistics cards, and lower Token trend.

## Retiring the Rejected Quota History

Because this branch has not been merged or released, stop recording daily quota snapshots and
remove the unused aggregation/store/model/UI code introduced solely for that rejected display.
Remove its schema creation statement for new databases, but do not execute `DROP TABLE` or delete
an already-created local `quota_usage_samples` table. Older local data is left physically
untouched but is no longer read or written.

Keep the shared usage-refresh generation guard because it independently prevents stale App Server
responses from overwriting newer quota state.

## Testing and Verification

- Pure tests cover seven-day ordering, compact and exact Token formatting, unknown values, bar
  scaling, selection reconciliation, scope-aware titles, and full-date accessibility labels.
- Model/store tests are updated to remove expectations for the retired quota snapshot pipeline
  while preserving refresh-generation coverage.
- `Scripts/check.sh`, release packaging, and code-sign verification must pass.
- Install locally and confirm repeated status-item clicks open the popover without adding a new
  crash report.
