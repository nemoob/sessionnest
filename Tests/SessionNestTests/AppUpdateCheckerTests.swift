import Foundation
import Testing

@testable import SessionNest

@Test func appVersionUsesNumericSemanticOrdering() {
    #expect(AppVersion(tag: "v0.2.10")! > AppVersion(tag: "0.2.9")!)
    #expect(AppVersion(tag: "1.0.0") == AppVersion(tag: "v1.0.0"))
    #expect(AppVersion(tag: "1.2") == nil)
    #expect(AppVersion(tag: "1.2.beta") == nil)
}

@Test func currentAppVersionFallsBackSafelyWhenBundleVersionIsMissing() {
    #expect(AppVersion.current(bundleVersion: "0.2.3") == AppVersion(tag: "0.2.3"))
    #expect(AppVersion.current(bundleVersion: nil) == AppVersion(tag: "0.0.0"))
    #expect(AppVersion.current(bundleVersion: "invalid") == AppVersion(tag: "0.0.0"))
}

@Test func automaticUpdateScheduleUsesRollingTwentyFourHours() {
    let lastAttempt = Date(timeIntervalSince1970: 1_000)

    #expect(
        !AppUpdateSchedule.isDue(
            lastAttempt: lastAttempt,
            now: lastAttempt.addingTimeInterval(86_399)
        )
    )
    #expect(
        AppUpdateSchedule.isDue(
            lastAttempt: lastAttempt,
            now: lastAttempt.addingTimeInterval(86_400)
        )
    )
}

@Test func automaticUpdateScheduleReturnsExactNextDueDate() {
    let now = Date(timeIntervalSince1970: 100_000)
    let recentAttempt = now.addingTimeInterval(-3_600)

    #expect(AppUpdateSchedule.nextCheckDate(lastAttempt: nil, now: now) == now)
    #expect(
        AppUpdateSchedule.nextCheckDate(lastAttempt: recentAttempt, now: now)
            == recentAttempt.addingTimeInterval(AppUpdateSchedule.interval)
    )
    #expect(
        AppUpdateSchedule.nextCheckDate(
            lastAttempt: now.addingTimeInterval(-AppUpdateSchedule.interval - 1),
            now: now
        ) == now
    )
    #expect(AppUpdateSchedule.timerTolerance == 5 * 60)
}

@Test func githubReleaseDecodesPublicReleaseFields() throws {
    let data = Data(
        #"{"tag_name":"v0.2.4","html_url":"https://github.com/nemoob/sessionnest/releases/tag/v0.2.4","name":"SessionNest v0.2.4","body":"Daily update checking"}"#
            .utf8
    )

    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

    #expect(release.tagName == "v0.2.4")
    #expect(release.htmlURL.absoluteString.hasSuffix("/v0.2.4"))
    #expect(release.name == "SessionNest v0.2.4")
    #expect(release.body == "Daily update checking")
}

@Test func updatePreferencesDefaultToEnabledAndPersistValues() {
    let defaults = makeUpdateDefaults()
    let preferences = AppUpdatePreferences(defaults: defaults)
    let attemptedAt = Date(timeIntervalSince1970: 12_345)

    #expect(preferences.automaticallyChecksForUpdates)
    preferences.automaticallyChecksForUpdates = false
    preferences.lastAutomaticCheckAt = attemptedAt
    preferences.ignoredVersion = "v0.2.4"

    let reloaded = AppUpdatePreferences(defaults: defaults)
    #expect(!reloaded.automaticallyChecksForUpdates)
    #expect(reloaded.lastAutomaticCheckAt == attemptedAt)
    #expect(reloaded.ignoredVersion == "v0.2.4")
}

@MainActor
@Test func automaticChecksThrottleRequestsAndManualChecksBypassThrottle() async {
    let defaults = makeUpdateDefaults()
    var requestCount = 0
    let checker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.3")!,
        preferences: AppUpdatePreferences(defaults: defaults),
        now: { Date(timeIntervalSince1970: 1_000) },
        fetch: { _ in
            requestCount += 1
            return githubRelease(tag: "v0.2.3")
        }
    )

    await checker.check(.automatic)
    await checker.check(.automatic)
    #expect(requestCount == 1)

    await checker.check(.manual)
    #expect(requestCount == 2)
}

@MainActor
@Test func disabledAutomaticChecksDoNotBlockManualChecks() async {
    let defaults = makeUpdateDefaults()
    let preferences = AppUpdatePreferences(defaults: defaults)
    preferences.automaticallyChecksForUpdates = false
    var requestCount = 0
    let checker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.3")!,
        preferences: preferences,
        fetch: { _ in
            requestCount += 1
            return githubRelease(tag: "v0.2.3")
        }
    )

    await checker.check(.automatic)
    #expect(requestCount == 0)

    await checker.check(.manual)
    #expect(requestCount == 1)
}

@MainActor
@Test func automaticCheckerExposesNextDueDateForPersistentScheduling() async {
    let now = Date(timeIntervalSince1970: 100_000)
    let defaults = makeUpdateDefaults()
    let preferences = AppUpdatePreferences(defaults: defaults)
    let checker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.45")!,
        preferences: preferences,
        now: { now },
        fetch: { _ in githubRelease(tag: "v0.2.45") }
    )

    #expect(checker.nextAutomaticCheckAt == now)
    await checker.check(.automatic)
    #expect(
        checker.nextAutomaticCheckAt
            == now.addingTimeInterval(AppUpdateSchedule.interval)
    )

    checker.setAutomaticChecksEnabled(false)
    #expect(checker.nextAutomaticCheckAt == nil)
}

@MainActor
@Test func inFlightManualCheckSatisfiesDueAutomaticScheduleWithoutDuplicateRequest() async {
    let now = Date(timeIntervalSince1970: 100_000)
    let gate = UpdateTestGate()
    var requestCount = 0
    let checker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.45")!,
        preferences: AppUpdatePreferences(defaults: makeUpdateDefaults()),
        now: { now },
        fetch: { _ in
            requestCount += 1
            await gate.wait()
            return githubRelease(tag: "v0.2.45")
        }
    )

    let manualCheck = Task { @MainActor in
        await checker.check(.manual)
    }
    while requestCount == 0 {
        await Task.yield()
    }

    await checker.check(.automatic)
    #expect(requestCount == 1)
    #expect(
        checker.nextAutomaticCheckAt
            == now.addingTimeInterval(AppUpdateSchedule.interval)
    )

    await gate.open()
    await manualCheck.value
}

@Test func githubReleaseAPIUsesExpectedEndpointAndHeaders() {
    let request = GitHubReleaseAPI.makeRequest(currentVersion: "0.2.3")

    #expect(
        request.url?.absoluteString
            == "https://api.github.com/repos/nemoob/sessionnest/releases/latest"
    )
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "SessionNest/0.2.3")
}

@Test func githubReleaseAPIRequiresSuccessfulHTTPResponse() throws {
    let data = Data(#"{"tag_name":"v0.2.4"}"#.utf8)
    let response = HTTPURLResponse(
        url: URL(string: "https://api.github.com/repos/nemoob/sessionnest/releases/latest")!,
        statusCode: 503,
        httpVersion: nil,
        headerFields: nil
    )!

    #expect(throws: GitHubReleaseAPIError.invalidResponse) {
        try GitHubReleaseAPI.decode(data: data, response: response)
    }
}

@MainActor
@Test func failedAutomaticCheckStillWaitsTwentyFourHours() async {
    var requestCount = 0
    let checker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.3")!,
        preferences: AppUpdatePreferences(defaults: makeUpdateDefaults()),
        now: { Date(timeIntervalSince1970: 1_000) },
        fetch: { _ in
            requestCount += 1
            throw UpdateTestError.unavailable
        }
    )

    await checker.check(.automatic)
    await checker.check(.automatic)

    #expect(requestCount == 1)
}

@MainActor
@Test func updateCheckerPersistsAutomaticCheckPreference() {
    let defaults = makeUpdateDefaults()
    let checker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.3")!,
        preferences: AppUpdatePreferences(defaults: defaults),
        fetch: { _ in githubRelease(tag: "v0.2.3") }
    )

    checker.setAutomaticChecksEnabled(false)

    #expect(!checker.automaticallyChecksForUpdates)
    #expect(!AppUpdatePreferences(defaults: defaults).automaticallyChecksForUpdates)
}

@MainActor
@Test func newerReleaseAppearsUnlessThatExactVersionIsIgnored() async {
    let defaults = makeUpdateDefaults()
    var nextTag = "v0.2.4"
    let checker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.3")!,
        preferences: AppUpdatePreferences(defaults: defaults),
        fetch: { _ in githubRelease(tag: nextTag, body: "Daily update checking") }
    )

    await checker.check(.manual)
    guard case .available(let firstUpdate) = checker.state else {
        Issue.record("Expected an available update")
        return
    }
    #expect(firstUpdate.tagName == "v0.2.4")
    #expect(firstUpdate.summary == "Daily update checking")

    checker.ignoreAvailableVersion()
    #expect(checker.state == .upToDate)

    await checker.check(.manual)
    #expect(checker.state == .upToDate)

    nextTag = "v0.2.5"
    await checker.check(.manual)
    guard case .available(let laterUpdate) = checker.state else {
        Issue.record("Expected a later update")
        return
    }
    #expect(laterUpdate.tagName == "v0.2.5")
}

@MainActor
@Test func currentAndOlderReleasesAreUpToDate() async {
    var nextTag = "v0.2.3"
    let checker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.3")!,
        preferences: AppUpdatePreferences(defaults: makeUpdateDefaults()),
        fetch: { _ in githubRelease(tag: nextTag) }
    )

    await checker.check(.manual)
    #expect(checker.state == .upToDate)

    nextTag = "v0.2.2"
    await checker.check(.manual)
    #expect(checker.state == .upToDate)
}

@MainActor
@Test func updateCheckerRejectsNonGitHubReleasePages() async {
    let checker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.3")!,
        preferences: AppUpdatePreferences(defaults: makeUpdateDefaults()),
        fetch: { _ in
            githubRelease(tag: "v0.2.4", url: "https://example.com/sessionnest/v0.2.4")
        }
    )

    await checker.check(.manual)

    guard case .failed = checker.state else {
        Issue.record("Expected a visible manual failure")
        return
    }
}

@MainActor
@Test func automaticFailuresStaySilentAndManualFailuresAreVisible() async {
    let automaticChecker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.3")!,
        preferences: AppUpdatePreferences(defaults: makeUpdateDefaults()),
        fetch: { _ in throw UpdateTestError.unavailable }
    )

    await automaticChecker.check(.automatic)
    #expect(automaticChecker.state == .idle)

    let manualChecker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.3")!,
        preferences: AppUpdatePreferences(defaults: makeUpdateDefaults()),
        fetch: { _ in throw UpdateTestError.unavailable }
    )
    await manualChecker.check(.manual)
    guard case .failed = manualChecker.state else {
        Issue.record("Expected a visible manual failure")
        return
    }
}

@MainActor
@Test func updateCheckerCoalescesConcurrentRequestsAndPreservesAvailableUpdate() async {
    let gate = UpdateTestGate()
    var requestCount = 0
    var shouldFail = false
    let checker = AppUpdateChecker(
        currentVersion: AppVersion(tag: "0.2.3")!,
        preferences: AppUpdatePreferences(defaults: makeUpdateDefaults()),
        fetch: { _ in
            requestCount += 1
            if shouldFail { throw UpdateTestError.unavailable }
            await gate.wait()
            return githubRelease(tag: "v0.2.4")
        }
    )

    let firstCheck = Task { @MainActor in
        await checker.check(.manual)
    }
    while requestCount == 0 {
        await Task.yield()
    }
    await checker.check(.manual)
    #expect(requestCount == 1)
    await gate.open()
    await firstCheck.value

    guard case .available = checker.state else {
        Issue.record("Expected the available update")
        return
    }

    shouldFail = true
    await checker.check(.manual)
    guard case .available = checker.state else {
        Issue.record("Expected the available update to survive a later failure")
        return
    }
}

private enum UpdateTestError: Error {
    case unavailable
}

private actor UpdateTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private func makeUpdateDefaults() -> UserDefaults {
    UserDefaults(suiteName: "SessionNestTests.\(UUID().uuidString)")!
}

private func githubRelease(
    tag: String,
    url: String? = nil,
    body: String? = nil
) -> GitHubRelease {
    GitHubRelease(
        tagName: tag,
        htmlURL: URL(
            string: url
                ?? "https://github.com/nemoob/sessionnest/releases/tag/\(tag)"
        )!,
        name: "SessionNest \(tag)",
        body: body
    )
}
