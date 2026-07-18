# SessionNest

A local-first session manager for Codex.

SessionNest is a native macOS app for finding, organizing, and understanding local Codex
sessions. It keeps its own metadata beside Codex without replacing or uploading your session
history. Visit the [project website](https://www.nemoob.cn/) or browse the
[source repository](https://github.com/nemoob/sessionnest).

SessionNest is an independent open-source project and is not affiliated with or endorsed by OpenAI.

## Requirements

- macOS 14 or later
- Xcode with Swift 6.2 or later
- A bundled Codex CLI from `/Applications/Codex.app`, `~/Applications/Codex.app`, or
  `/Applications/ChatGPT.app`

## Features

- Search, sort, and time-filter active and archived sessions
- Organize sessions by inferred project directories, no-project sessions, favorites, collections,
  and colored tags
- Archive, unarchive, and reopen sessions in Codex
- View local Token usage by day, project, and session
- See weekly remaining quota, exact current-cycle local Token usage, and reset-card expirations from
  the menu bar
- Hover over or select a day in the Token trend chart to inspect its complete Token breakdown
- Monitor session count and Token-statistics coverage from the menu bar
- Follow the system appearance or choose a light or dark theme

## Build and test

```bash
xcrun swift build
bash Scripts/check.sh
```

Package and open the app:

```bash
bash Scripts/package-app.sh
open "dist/SessionNest.app"
```

The packaging script builds a release executable, creates the macOS icon set, assembles the app
bundle, and applies an ad-hoc signature.

This repository is source-only: it does not include a notarized or Developer ID-signed binary.
Locally packaged apps use ad-hoc signing and may require the usual macOS confirmation before first
launch.

## Architecture

SessionNest uses SwiftUI for the interface and AppKit for macOS menu bar, window, and system
integration. It reads session metadata through the local Codex App Server, scans rollout files
read-only for Token usage, and stores only SessionNest-managed metadata and derived statistics in
SQLite.

Quota-cycle Token usage remains a local statistic rather than a server billing measurement. It uses
the Codex App Server's exact quota-cycle boundary to exclude local Token events that happened before
a natural weekly reset or a reset-card use on the same day.

Project inference distinguishes Git projects, ordinary working directories, and Codex scratch
workspaces shaped like `Codex/YYYY-MM-DD/<session>`. A scratch workspace is assigned to a Git
project only when local session evidence identifies one reliably; otherwise it appears under
**无项目** and stays out of the project directory tree.

## Local data and migration

SessionNest stores favorites, collections, tags, inferred project caches, and Token statistics in:

```text
~/Library/Application Support/SessionNest/manager.sqlite
```

Appearance is stored in the app's local user defaults. Removing the database resets only
SessionNest metadata; it does not delete Codex conversations.

Project-classification cache changes use additive SQLite migrations. Existing cache rows are
reanalyzed in the background after an inference-version change; favorites, collections, tags, and
Token caches remain intact.

Timestamped Token deltas are stored in an additive table while the original daily Token table stays
unchanged and continues to be populated. Databases created by v0.1.2 can be upgraded in place, and
v0.1.2 can ignore the additional table if the app is temporarily downgraded.

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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). SessionNest is available under the [MIT License](LICENSE).
