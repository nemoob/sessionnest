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
quit SessionNest and remove `/Applications/SessionNest.app`. Its local metadata remains at
`~/Library/Application Support/SessionNest/manager.sqlite` unless you remove that file separately;
Codex conversations are never stored there and are not deleted.

## Features

- Search, sort, and time-filter active and archived sessions
- Organize sessions by inferred project directories, no-project sessions, favorites, collections,
  and colored tags
- Archive, unarchive, and reopen sessions in Codex
- View local Token usage by day, project, and session
- See account details, weekly remaining quota, exact current-cycle local Token usage, and reset-card
  expirations from a dedicated main-window dashboard or the menu bar
- Hover over or select a day in the Token trend chart to inspect its complete Token breakdown
- Monitor session count and Token-statistics coverage from the menu bar
- Reuse a persistent rollout discovery index and report cache, read, and failure diagnostics
- Keep fine-grained Token events for 30 days while retaining complete daily totals for long-term
  trends
- Check GitHub Releases at most once every 24 hours and open the trusted release page when an
  update is available
- Reduce background quota requests while macOS Low Power Mode is enabled
- Choose whether SessionNest launches in the menu bar only or opens its main window
- Follow the system appearance or choose a light or dark theme

## Build and test

Building from source requires Xcode with Swift 6.2 or later.

```bash
xcrun swift build
bash Scripts/check.sh
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

Quota-cycle Token usage remains a local statistic rather than a server billing measurement. It uses
the Codex App Server's exact quota-cycle boundary to exclude local Token events that happened before
a natural weekly reset or a reset-card use on the same day.

The background quota timer still wakes every 10 minutes. It requests a new quota snapshot only when
the previous result is stale; macOS Low Power Mode extends that threshold to 30 minutes. Full
reloads and manual refreshes continue to update data without starting a duplicate background
request. Low Power Mode also limits automatic full session scans to at most once per hour, while a
manual refresh remains immediate.

Project inference distinguishes Git projects, ordinary working directories, and Codex scratch
workspaces shaped like `Codex/YYYY-MM-DD/<session>`. A scratch workspace is assigned to a Git
project only when local session evidence identifies one reliably; otherwise it appears under
**无项目** and stays out of the project directory tree.

Linked Git worktrees are grouped under their main working tree by resolving Git's shared common
directory. If a Codex-managed worktree has already been removed, SessionNest uses its recorded Git
origin only when that origin maps to exactly one live local repository; ambiguous clones remain
separate instead of being merged by directory name.

## Local data and migration

SessionNest stores favorites, collections, tags, inferred project caches, and Token statistics in:

```text
~/Library/Application Support/SessionNest/manager.sqlite
```

Appearance is stored in the app's local user defaults. Removing the database resets only
SessionNest metadata; it does not delete Codex conversations.

Project-classification and rollout-discovery cache changes use additive SQLite migrations. Existing
project cache rows are reanalyzed in the background after an inference-version change; favorites,
collections, tags, and Token caches remain intact.

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
