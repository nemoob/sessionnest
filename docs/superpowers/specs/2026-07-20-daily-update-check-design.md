# Daily Update Check Design

## Goal

Let SessionNest discover new stable GitHub Releases without running a persistent polling timer or
installing executable code automatically.

The first release of this feature checks at most once per rolling 24-hour period, presents an
in-app notice when a newer version exists, and sends the user to the trusted GitHub Release page to
download it. It does not require the SessionNest website.

## Scope

### Included

- Check the latest published, non-draft, non-prerelease release of `nemoob/sessionnest`.
- Run the automatic check after launch and when the menu bar popover opens, subject to one shared
  24-hour throttle.
- Add an enabled-by-default `每天自动检查更新` setting and an `立即检查` action inside the existing
  popover settings page.
- Show a compact update notice near the top of the popover overview when a newer version exists.
- Let the user open the release page or ignore that specific version.
- Persist the last automatic check attempt time, the automatic-check preference, and the ignored
  version in `UserDefaults`.
- Keep automatic network failures silent while showing the result of an explicit manual check.

### Excluded

- Downloading, replacing, relaunching, or silently installing the application.
- Sparkle, an appcast, a website-hosted feed, or any new package dependency.
- Prerelease channels, downgrade notices, delta updates, and update analytics.

## User Experience

The settings page adds an `更新` section below the theme controls:

- `每天自动检查更新`: on by default.
- `立即检查`: bypasses the 24-hour throttle and displays `正在检查…`, `已是最新版本`, an available
  update, or a compact error message.

When a newer version is available, the overview displays one compact banner below the account and
action header:

- Title: `发现新版本 vX.Y.Z`.
- Optional one-line release summary when GitHub provides usable text.
- Primary action: `查看更新`, opening the release's HTTPS GitHub URL.
- Secondary action: `忽略此版本`, hiding only that version. A later version can appear normally.

The menu bar label itself does not change, so update state cannot consume additional menu bar width.

## Architecture

Add one focused update-checking source file with small value types and an injectable checker:

- `AppVersion` parses release tags with an optional leading `v` and compares numeric major, minor,
  and patch components. Invalid or unsupported tags are ignored safely.
- `GitHubRelease` decodes `tag_name`, `html_url`, `name`, and `body` from GitHub's latest-release
  response.
- `AppUpdateChecker` owns the request and observable presentation state. Production uses
  `URLSession`; tests inject a request closure, clock, current version, and preferences.
- `AppUpdatePreferences` stores the three update-related values in `UserDefaults` without adding a
  database migration.

The checker requests:

`https://api.github.com/repos/nemoob/sessionnest/releases/latest`

It sends GitHub's JSON accept header and a SessionNest user-agent, requires an HTTP 2xx response,
accepts only HTTPS release-page URLs on `github.com`, and never uses an asset URL to install code.

`SessionNestAppDelegate` creates one checker and passes it to the status-item controller. Launch
requests an automatic check. Popover presentation requests another automatic check, which becomes
a no-op when the last automatic check attempt is less than 24 hours old. Manual checks always
bypass the throttle.

## State and Scheduling

The presentation state is one of:

- idle
- checking
- up to date
- update available
- failed

Starting an automatic request advances the persisted automatic-check timestamp, guaranteeing at
most one automatic network request per rolling 24-hour period even when GitHub is unavailable. An
in-memory guard coalesces concurrent automatic or manual requests.

Disabling automatic checks prevents launch and popover-triggered requests but does not disable
`立即检查`. Re-enabling the setting may check immediately if no automatic attempt occurred in the
last 24 hours.

## Error Handling and Privacy

- Automatic failures do not display banners or notifications.
- Manual failures remain visible in settings until the next manual attempt or success.
- Existing available-update state remains available after a later network failure.
- The request contains no account, session, Token, project, or device data beyond standard HTTPS
  request metadata and the SessionNest user-agent.
- No telemetry or update-check history is uploaded.

## Testing

Unit tests cover:

- semantic numeric ordering, equality, optional `v`, and invalid tags;
- latest-release decoding and HTTP/error handling;
- the exact rolling 24-hour throttle boundary;
- automatic-check preference behavior and manual bypass;
- request coalescing;
- ignored-version behavior and visibility of later releases;
- silent automatic failures and visible manual failures;
- HTTPS GitHub release URL validation.

Existing status-popover tests continue to cover layout dimensions and navigation. A focused view
state test verifies that the banner appears only for a newer, non-ignored version.

Release verification remains the existing full test, package, code-signature, GitHub Release asset,
and local-install integrity chain.
