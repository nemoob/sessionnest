# Daily Quota Usage Chart Design

## Goal

Show how much of the weekly Codex quota changed on each recent day, directly below the weekly quota progress bar in the menu bar popover. Keep the existing total remaining percentage and reset time unchanged.

## Chosen Approach

Persist successful weekly `usedPercent` readings from Codex App Server and derive daily positive changes from consecutive readings in the same quota cycle. This is the only approach that measures quota percentage directly without pretending that local Token counts can be converted into server quota.

Two alternatives were rejected:

- Dividing local daily Tokens by cycle Tokens is available immediately, but it shows Token share rather than quota percentage and would be misleading.
- Keeping only a day-start value in `UserDefaults` is smaller, but it loses data across resets, cannot represent seven days, and is harder to validate or migrate.

## Storage and Refresh Flow

Add a SQLite table with `cycle_resets_at`, a ten-minute `captured_bucket`, the actual `captured_at`, and `used_percent`. The cycle reset timestamp identifies one weekly allowance period. Upserting within the same ten-minute bucket bounds normal growth while allowing a manual refresh to replace the bucket with the latest value.

Every successful usage refresh records the weekly window when both its seven-day duration and reset timestamp are available. The existing ten-minute timer remains unchanged, so there is no additional network request or wake-up. Snapshot persistence failure must not discard the successfully refreshed quota value.

Existing installations receive the table through the current additive `CREATE TABLE IF NOT EXISTS` schema path. No Codex-owned file is modified.

## Daily Calculation

Use only snapshots from the current `resetsAt` cycle and show up to seven local calendar days intersecting that cycle.

- The first stored reading establishes a baseline and contributes no historical usage.
- Each later non-negative `usedPercent` difference is assigned to the local day of the later reading.
- A decrease establishes a new baseline, covering a server reset or reset-card event without producing negative usage.
- A gap longer than 30 minutes is not attributed because the exact day of consumption is unknown.
- Values are clamped to the valid 0...100 range.

Because SessionNest cannot reconstruct readings from before this feature was enabled or while it was not running, the UI says that percentages cover the locally observed period. A day with only a baseline displays no fabricated percentage.

## Popover UI

Insert a compact `本周期每日消耗` section between the weekly quota row and reset-card details. Use a seven-bar Swift Charts view about 120 points high:

- local weekday labels on the x-axis;
- percentage labels above non-zero bars;
- today highlighted with the current quota color and earlier days shown with a quieter tint;
- hover previews and click-to-pin selection, following the existing Token trend interaction;
- a selected-day detail showing the observed quota change and that day's local Token usage when available;
- accessibility labels containing the full date and observed percentage;
- an empty state reading `从现在开始记录每日额度变化` until a positive delta exists;
- a caption explaining that the chart is based on locally observed server quota snapshots.

The popover remains 420 by 620 and continues scrolling; no window-size change is needed. The main quota page is outside this change so the first iteration stays focused on the screenshot area requested by the user.

## Verification

- Snapshot upsert keeps one row per cycle and ten-minute bucket.
- Loading filters and orders one quota cycle correctly.
- Daily calculation covers normal growth, midnight boundaries, percentage decreases, long gaps, missing history, and 0...100 clamping.
- The popover model exposes seven ordered bars, today highlighting, percentage labels, and the initial empty message.
- Existing ten-minute refresh scheduling and quota display tests remain unchanged.
- Run the complete repository check, package the App, verify its signature, and update the local installation after implementation.
