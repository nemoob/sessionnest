# SessionNest

A local-first session manager for Codex.

SessionNest is a native macOS app for finding, organizing, and understanding local Codex
sessions. It keeps its own metadata beside Codex without replacing or uploading your session
history. Visit the [project website](https://www.nemoob.cn/) or browse the
[source repository](https://github.com/nemoob/sessionnest).

SessionNest is an independent open-source project and is not affiliated with or endorsed by OpenAI.

## Requirements

- macOS 14 or later
- Apple silicon for the downloadable build
- A bundled Codex CLI from `/Applications/Codex.app`, `~/Applications/Codex.app`, or
  `/Applications/ChatGPT.app`

## Install

1. Download the latest `SessionNest-*-macos-arm64.zip` from
   [GitHub Releases](https://github.com/nemoob/sessionnest/releases/latest).
2. Extract the archive and move `SessionNest.app` to `/Applications`.
3. On first launch, Control-click the app and choose **Open**. If macOS still blocks it, allow it
   from **System Settings → Privacy & Security**.

The downloadable build currently supports Apple silicon Macs. Intel users can build from source.
Release archives are ad-hoc signed, not Developer ID signed or Apple notarized.

To update, quit SessionNest and replace the existing app with the newer release. To uninstall,
quit SessionNest and remove `/Applications/SessionNest.app`. Its local metadata database and
migration backup remain under `~/Library/Application Support/SessionNest/` unless you remove that
directory separately; Codex conversations are never stored there and are not deleted.

## Features

- Search active and archived sessions with multiple keywords and highlighted matches, then sort or
  time-filter the results
- Organize sessions with smart folders generated for projects sharing the same real parent
  directory, plus no-project sessions, favorites, collections, and colored tags
- Save the current session scope, search text, time range, and sort order as a reusable sidebar view
- Restore the last sidebar scope, search text, time range, sort order, and expanded project folders
  after relaunching the app
- Select multiple sessions to favorite, unfavorite, archive, or unarchive them in one batch
- Archive, unarchive, and reopen individual sessions in Codex
- Focus session search with Command-F, clear it with Escape, and use complete VoiceOver row
  summaries with open and favorite actions
- View local Token usage by day, project, and session
- Switch statistics among 7-day, 30-day, 90-day, all-time, and custom inclusive local-date ranges
- Select a top project in the Token ranking to drill down to its exact session-level usage
- See account details, weekly remaining quota, exact current-cycle local Token usage, and reset-card
  expirations from a dedicated main-window dashboard or the menu bar
- Read weekly quota first and current-cycle local Token second in the menu-bar item, with complete
  values available from its context menu and accessibility label
- Use a wider, explicitly scrollable menu-bar popover and show the latest available daily Token
  detail by default without overriding later user selection
- Keep the popover's daily Token bars on the exact weekly-quota cycle, including the first partial
  local day when the server cycle starts between midnights
- Hover over or select a day in the Token trend chart to inspect its complete Token breakdown
- Monitor session count, Token-statistics coverage, and per-session exclusion reasons from the
  menu bar
- Warn when the same scan scope's all-time Token total suddenly reaches zero or materially doubles
- Recalculate a selected local-date range from raw JSONL while preserving derived statistics
  outside the selected range
- Reuse a persistent rollout discovery index and report cache, read, and failure diagnostics
- Observe local Codex session changes and skip age-based full reloads while the files stay unchanged
- Coalesce Token scan requests arriving within 150 milliseconds and run only the latest request
- Aggregate quota-cycle Token events by session and local day inside indexed SQLite queries
- Copy a redacted diagnostics report containing only app/system context, aggregate coverage reasons,
  anomaly state, and scan counters
- Preserve the existing clipboard if writing a safe or full status screenshot fails
- Keep repeated cumulative Token checkpoints idempotent and report how many each scan skipped
- Keep fine-grained Token events for 30 days while retaining complete daily totals for long-term
  trends
- Guard Token-scanner performance with a public synthetic 20,000-checkpoint regression benchmark
- Check GitHub Releases at most once every 24 hours, including while SessionNest remains running in
  the menu bar, and open the trusted release page when an update is available
- Reduce background quota requests while macOS Low Power Mode is enabled
- Choose whether SessionNest launches in the menu bar only or opens its main window
- Follow the system appearance or choose a light or dark theme

## Build and test

Building from source requires Xcode with Swift 6.2 or later.

```bash
xcrun swift build
bash Scripts/check.sh
```

The full check includes a synthetic Token-scanner performance benchmark and never reads local Codex
logs. To run that benchmark alone:

```bash
xcrun swift test --filter SessionPerformanceBenchmarkTests
```

Package and open the app:

```bash
bash Scripts/package-app.sh
open "dist/SessionNest.app"
```

The packaging script builds for the current host architecture, creates the macOS icon set,
assembles the app bundle, and applies an ad-hoc signature. Locally packaged apps are not notarized
or Developer ID signed.

## Architecture

SessionNest uses SwiftUI for the interface and AppKit for macOS menu bar, window, and system
integration. It reads session metadata through the local Codex App Server, scans rollout files
read-only for Token usage, and stores only SessionNest-managed metadata and derived statistics in
SQLite.

Rollout discovery stores each file's path, size, modification time, and discovered parent-child
session relationship in the local database. Unchanged files reuse that index instead of rereading
their prefixes. Scan diagnostics report enumerated files, cache hits, metadata reads, bytes read,
and failures.

The settings popover can copy these diagnostics as stable plain text for issue reports. The copied
report includes app/build and macOS versions, the local time-zone identifier, aggregate Token
coverage reasons, anomaly state, and scan counters. It excludes account details, session titles and
IDs, directory paths, and log content by construction.

To detect silent drift in derived Token statistics, each scan fully rebuilds at most one unchanged
rollout whose database result has not been reconciled in the last 24 hours. A successful rebuild
records its reconciliation time, so verification converges across sessions without rereading every
rollout at once.

Repeated `token_count` checkpoints whose five cumulative Token fields exactly match the current
maximum are skipped before daily and second-level aggregation. The latest scan reports the number
of skipped checkpoints without persisting raw event content or maintaining a growing fingerprint
set.

Append-only rollout growth resumes after the last complete JSONL line. If a rollout is truncated or
replaced at the same path, SessionNest rebuilds that file's derived Token rows instead of merging
them with stale totals. Read failures preserve the last successful cache for retry but exclude it
from statistics coverage until a complete scan succeeds.

The local time-zone identifier is part of the Token parser cache version. Changing the Mac time
zone rebuilds unchanged rollouts on the next scan so daily totals and cached statistics use the new
local-day boundary.

Coverage diagnostics classify each unmeasured session as missing a discovered log, containing no
Token event, waiting for a log update, or having a scan failure. Child-agent logs are attributed to
their visible parent before counting, so one session contributes to exactly one reason.

Completed scans with the same target set are compared in memory. SessionNest warns when a nonzero
all-time Token total drops to zero, or when it at least doubles with an increase of 100,000 Tokens
or more. First scans, changed target sets, and smaller early-session growth do not trigger a warning,
and detection never rewrites or hides the underlying local statistics.

The statistics toolbar can recalculate an inclusive local-date range from raw JSONL even when the
source files have not changed. SessionNest atomically replaces only the selected days for unchanged
logs; a log that changed is fully synchronized so new events outside the range cannot be skipped.
The Codex logs remain read-only.

The statistics range menu provides 7-day, 30-day, 90-day, all-time, and custom local-date views.
Custom dates form an inclusive local-day interval and only filter existing derived statistics; they
do not trigger a raw-log scan. A session with Token usage inside a historical custom interval stays
in that result even when the session was updated again after the selected end date. The most recent
custom result is cached in memory and invalidates with the same data, day, and time-zone inputs as
the fixed ranges.

Selecting a bar in the top-project ranking filters the session-usage table by the project's exact
path, so projects with the same directory name remain distinct. The current project and session
count stay visible above the table, and the filter can be cleared without changing the date range.

Quota-cycle Token usage remains a local statistic rather than a server billing measurement. It uses
the Codex App Server's exact quota-cycle boundary to exclude local Token events that happened before
a natural weekly reset or a reset-card use on the same day. Its SQLite range query uses the
second-level timestamp index and returns one aggregate row per session and local day instead of
moving every matching event into Swift.

The seven-day, thirty-day, and all-time statistics snapshots are persisted in SessionNest's own
SQLite database. A snapshot is reused only when a SHA-256 key over the app version, local day, time
zone, sessions, effective project assignments, coverage and child-agent attribution, and daily
Token rows matches exactly. Changed inputs, future-dated sessions, unknown scopes, and damaged
payloads fall back to the existing live aggregation path.

Token totals use each local rollout checkpoint's `total_tokens`, which already includes cached
input. Non-cached Token is therefore `max(total_tokens - cached_input_tokens, 0)`. Quota
consumption remains the percentage reported by the Codex App Server and is never derived from local
Token counts.

The quota timer adapts to interface visibility, app activity, and macOS Low Power Mode. It wakes
every 10 minutes while the main window is active or the menu bar popover is visible, every 30
minutes while in the background or visible in Low Power Mode, and every 60 minutes while both in
the background and in Low Power Mode. Matching timer tolerance lets macOS coalesce background
wakeups. State changes preserve the deadline derived from the latest success or attempt instead of
starting a fresh interval, and sleep/wake is handled by the same scheduler. Returning to the
foreground refreshes only an expired quota snapshot, while manual refresh remains immediate.

SessionNest uses native FSEvents to observe session, archived-session, and Codex state-database
changes. File events only mark the local data revision; opening the window, quota page, or menu bar
popover runs a full reload when that revision changed, instead of polling unchanged data by age. If
file monitoring cannot start, the existing 15-minute policy remains as a fallback and Low Power
Mode extends it to one hour. Token scan requests share a 150-millisecond trailing-edge window, so
simultaneous view updates perform only the latest discovery and scan; requests arriving after a scan
starts retain the existing generation-based replacement behavior.

Project inference distinguishes Git projects, ordinary working directories, and Codex scratch
workspaces shaped like `Codex/YYYY-MM-DD/<session>`. A scratch workspace is assigned to a Git
project only when local session evidence identifies one reliably; otherwise it appears under
**无项目** and stays out of the project directory tree.

When at least two inferred projects share an immediate parent directory, the sidebar creates one
selectable smart folder for that real path and aggregates the subtree's session count. A lone
project remains top-level, and SessionNest does not crawl the filesystem or build a chain back to
the disk root.

Linked Git worktrees are grouped under their main working tree by resolving Git's shared common
directory. If a Codex-managed worktree has already been removed, SessionNest uses its recorded Git
origin only when that origin maps to exactly one live local repository; ambiguous clones remain
separate instead of being merged by directory name.

Session search splits whitespace-delimited keywords and requires every keyword to match at least one
existing title, preview, project path, working directory, branch, or tag field. Matching is
case-insensitive and diacritic-insensitive, and visible matches in each result row are emphasized
without reading additional rollout content or maintaining a separate search index.

Command-F focuses session search from the list, and Escape clears a nonempty query before releasing
the search field on a second press. VoiceOver treats each result as one row, announces its title,
project, branch, tags, relative activity, and favorite state, and exposes open and favorite actions.

The session list uses native macOS multiple selection. Its batch menu updates favorites
transactionally in SessionNest's database and sends archive or unarchive requests through the Codex
App Server. If only some archive requests succeed, successful sessions move immediately while
failed sessions stay selected for retry.

## Local data and migration

SessionNest stores favorites, collections, tags, saved views, inferred project caches, and Token
statistics in:

```text
~/Library/Application Support/SessionNest/manager.sqlite
```

Appearance and the last non-text browsing state are stored in the app's local user defaults.
Ordinary search text is not persisted there; a query is stored only when the user explicitly saves
it as a named view in SessionNest's database. Removing the database resets only SessionNest
metadata; it does not delete Codex conversations.

Project-classification and rollout-discovery cache changes use additive SQLite migrations. Existing
project cache rows are reanalyzed in the background after an inference-version change; favorites,
collections, tags, saved views, and Token caches remain intact.

Before an existing database first enters the versioned schema migration, SessionNest atomically
creates `manager.sqlite.pre-v1.backup` with SQLite's backup API. Schema changes run in one
transaction, so a failure rolls the original database back and preserves the first backup for
recovery instead of overwriting it on retry. A newly created database records schema version 1
without creating a redundant backup.

Timestamped Token deltas are stored in an additive table while the original daily Token table stays
unchanged and continues to be populated. Fine-grained deltas are retained for the latest 30 days;
complete daily totals remain available for long-term trends. Pruning old detail does not modify
Codex rollout files. Databases created by v0.1.2 can be upgraded in place, and v0.1.2 can ignore the
additional tables if the app is temporarily downgraded.

On first launch, if the SessionNest database does not exist but the former database at
`~/Library/Application Support/Codex Sessions/manager.sqlite` does, SessionNest copies it with
SQLite's backup API. It never overwrites an existing SessionNest database, leaves the former
database untouched, and reports a startup error if migration fails.

## Privacy and Codex data

SessionNest reads session metadata through the local Codex App Server and reads local rollout files
to calculate Token statistics. It does not edit or delete Codex conversation content. Archive and
unarchive happen only after an explicit user action and use the supported Codex App Server API.

No-project sessions remain part of total, daily, and per-session Token statistics. They are excluded
only from the project Token ranking so temporary scratch directories are not presented as projects.

SessionNest has no telemetry, accounts, cloud synchronization, or analytics service. SessionNest
metadata and calculated statistics remain on this Mac.

When automatic update checks are enabled, SessionNest contacts GitHub's public Releases API at most
once every 24 hours. The request includes only the app version in its user agent and does not upload
session, account, Token, or project data. The preference, last-attempt time, and ignored release are
stored in local user defaults. SessionNest only opens the selected GitHub release page; it does not
download or install updates automatically.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). SessionNest is available under the [MIT License](LICENSE).
