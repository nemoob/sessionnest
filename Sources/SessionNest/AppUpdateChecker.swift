import Combine
import Foundation

struct AppVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(tag: String) {
        let normalized = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard
            components.count == 3,
            let major = Int(components[0]),
            let minor = Int(components[1]),
            let patch = Int(components[2]),
            major >= 0,
            minor >= 0,
            patch >= 0
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    static func current(bundleVersion: String?) -> Self {
        AppVersion(tag: bundleVersion ?? "") ?? AppVersion(tag: "0.0.0")!
    }
}

enum AppUpdateSchedule {
    static let interval: TimeInterval = 24 * 60 * 60
    static let timerTolerance: TimeInterval = 5 * 60

    static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= interval
    }

    static func nextCheckDate(lastAttempt: Date?, now: Date) -> Date {
        guard let lastAttempt else { return now }
        return max(now, lastAttempt.addingTimeInterval(interval))
    }
}

struct GitHubRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let htmlURL: URL
    let name: String?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name
        case body
    }
}

enum GitHubReleaseAPIError: Error, Equatable {
    case invalidResponse
}

enum GitHubReleaseAPI {
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/nemoob/sessionnest/releases/latest"
    )!

    static func makeRequest(currentVersion: String) -> URLRequest {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SessionNest/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func decode(data: Data, response: URLResponse) throws -> GitHubRelease {
        guard
            let response = response as? HTTPURLResponse,
            (200...299).contains(response.statusCode)
        else {
            throw GitHubReleaseAPIError.invalidResponse
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

struct AppUpdate: Equatable, Sendable {
    let version: AppVersion
    let tagName: String
    let releaseURL: URL
    let summary: String?
}

enum AppUpdateCheckState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(AppUpdate)
    case failed(String)

    var isChecking: Bool {
        self == .checking
    }
}

enum AppUpdateCheckTrigger: Sendable {
    case automatic
    case manual
}

struct AppUpdatePreferences {
    private enum Key {
        static let automaticallyChecks = "sessionnest.update.automaticallyChecks"
        static let lastAutomaticCheckAt = "sessionnest.update.lastAutomaticCheckAt"
        static let ignoredVersion = "sessionnest.update.ignoredVersion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            guard defaults.object(forKey: Key.automaticallyChecks) != nil else { return true }
            return defaults.bool(forKey: Key.automaticallyChecks)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Key.automaticallyChecks)
        }
    }

    var lastAutomaticCheckAt: Date? {
        get { defaults.object(forKey: Key.lastAutomaticCheckAt) as? Date }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastAutomaticCheckAt)
            } else {
                defaults.removeObject(forKey: Key.lastAutomaticCheckAt)
            }
        }
    }

    var ignoredVersion: String? {
        get { defaults.string(forKey: Key.ignoredVersion) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Key.ignoredVersion)
            } else {
                defaults.removeObject(forKey: Key.ignoredVersion)
            }
        }
    }
}

private enum AppUpdateError: Error {
    case invalidVersion
    case invalidReleaseURL
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    typealias Fetch = (URLRequest) async throws -> GitHubRelease

    @Published private(set) var state: AppUpdateCheckState = .idle
    @Published private(set) var automaticallyChecksForUpdates: Bool

    private let currentVersion: AppVersion
    private var preferences: AppUpdatePreferences
    private let now: () -> Date
    private let fetch: Fetch
    private var requestInFlight = false

    init(
        currentVersion: AppVersion,
        preferences: AppUpdatePreferences = AppUpdatePreferences(),
        now: @escaping () -> Date = Date.init,
        fetch: @escaping Fetch
    ) {
        self.currentVersion = currentVersion
        self.preferences = preferences
        self.now = now
        self.fetch = fetch
        automaticallyChecksForUpdates = preferences.automaticallyChecksForUpdates
    }

    var nextAutomaticCheckAt: Date? {
        guard automaticallyChecksForUpdates else { return nil }
        return AppUpdateSchedule.nextCheckDate(
            lastAttempt: preferences.lastAutomaticCheckAt,
            now: now()
        )
    }

    static func live(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) -> AppUpdateChecker {
        let bundleVersion =
            bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
        return AppUpdateChecker(
            currentVersion: AppVersion.current(bundleVersion: bundleVersion),
            preferences: AppUpdatePreferences(defaults: defaults),
            fetch: { request in
                let (data, response) = try await session.data(for: request)
                return try GitHubReleaseAPI.decode(data: data, response: response)
            }
        )
    }

    func check(_ trigger: AppUpdateCheckTrigger) async {
        let attemptDate = now()
        if trigger == .automatic {
            guard
                automaticallyChecksForUpdates,
                AppUpdateSchedule.isDue(
                    lastAttempt: preferences.lastAutomaticCheckAt,
                    now: attemptDate
                )
            else { return }
            preferences.lastAutomaticCheckAt = attemptDate
        }
        guard !requestInFlight else { return }

        requestInFlight = true
        let previousState = state
        state = .checking
        defer { requestInFlight = false }

        do {
            let release = try await fetch(makeRequest())
            state = try resolvedState(for: release)
        } catch {
            if case .available = previousState {
                state = previousState
            } else {
                state =
                    trigger == .manual
                    ? .failed("无法检查更新，请稍后重试。")
                    : .idle
            }
        }
    }

    func setAutomaticChecksEnabled(_ isEnabled: Bool) {
        automaticallyChecksForUpdates = isEnabled
        preferences.automaticallyChecksForUpdates = isEnabled
    }

    func ignoreAvailableVersion() {
        guard case .available(let update) = state else { return }
        preferences.ignoredVersion = update.tagName
        state = .upToDate
    }

    private func makeRequest() -> URLRequest {
        GitHubReleaseAPI.makeRequest(
            currentVersion:
                "\(currentVersion.major).\(currentVersion.minor).\(currentVersion.patch)"
        )
    }

    private func resolvedState(for release: GitHubRelease) throws -> AppUpdateCheckState {
        guard let releaseVersion = AppVersion(tag: release.tagName) else {
            throw AppUpdateError.invalidVersion
        }
        guard
            release.htmlURL.scheme?.lowercased() == "https",
            release.htmlURL.host?.lowercased() == "github.com"
        else {
            throw AppUpdateError.invalidReleaseURL
        }
        guard
            releaseVersion > currentVersion,
            preferences.ignoredVersion != release.tagName
        else {
            return .upToDate
        }

        let summary = release.body?
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return .available(
            AppUpdate(
                version: releaseVersion,
                tagName: release.tagName,
                releaseURL: release.htmlURL,
                summary: summary
            )
        )
    }
}
