import Foundation

private let chineseCompactNumberFormat = IntegerFormatStyle<Int64>.number
    .notation(.compactName)
    .locale(Locale(identifier: "zh-Hans-CN"))

struct MenuBarAccountStatus {
    let planText: String
    let emailText: String

    init(account: CodexAccountSnapshot?, entitlementPlanType: String? = nil) {
        guard let account, account.type == "chatgpt" else {
            planText = "--"
            emailText = "--"
            return
        }

        emailText = account.email.flatMap { $0.isEmpty ? nil : $0 } ?? "--"
        let planType = entitlementPlanType.flatMap { $0.isEmpty ? nil : $0 } ?? account.planType
        planText =
            switch planType {
            case "free": "Free"
            case "go": "Go"
            case "plus": "Plus"
            case "pro": "Pro"
            case "prolite": "Pro Lite"
            case "team": "Team"
            case "self_serve_business_usage_based", "business": "Business"
            case "enterprise_cbp_usage_based", "enterprise": "Enterprise"
            case "edu": "Edu"
            default: "--"
            }
    }
}

enum MenuBarQuotaColor: Equatable {
    case gray
    case green
    case yellow
    case red

    init(remainingPercent: Int?) {
        guard let remainingPercent else {
            self = .gray
            return
        }

        self =
            switch remainingPercent {
            case ..<20: .red
            case ...50: .yellow
            default: .green
            }
    }
}

struct MenuBarQuotaStatus {
    let remainingText: String
    let fraction: Double
    let resetText: String
    let color: MenuBarQuotaColor

    init(window: CodexRateLimitWindow?, now: Int64) {
        guard let window else {
            remainingText = "-- 剩余"
            fraction = 0
            resetText = "重置时间 --"
            color = .gray
            return
        }

        let remaining = window.remainingPercent
        remainingText = "\(remaining)% 剩余"
        fraction = Double(remaining) / 100
        resetText = Self.resetText(resetsAt: window.resetsAt, now: now)
        color = MenuBarQuotaColor(remainingPercent: remaining)
    }

    private static func resetText(resetsAt: Int64?, now: Int64) -> String {
        guard let resetsAt else { return "重置时间 --" }
        let seconds = resetsAt - now
        guard seconds > 0 else { return "即将重置" }
        let totalHours = max(1, Int(ceil(Double(seconds) / 3_600)))
        let days = totalHours / 24
        let hours = totalHours % 24
        if days == 0 { return "\(hours) 小时后重置" }
        if hours == 0 { return "\(days) 天后重置" }
        return "\(days) 天 \(hours) 小时后重置"
    }
}

struct MenuBarStatisticsStatus {
    let sessionValueText: String
    let sessionDetailText: String
    let totalTokenValueText: String
    let totalTokenDetailText: String
    let averageValueText: String
    let averageDetailText: String
    let cachedInputValueText: String
    let cachedInputDetailText: String
    let dailyPoints: [StatisticsDailyPoint]
    let topProjects: [StatisticsProjectRow]
    let showsTokenScanProgress: Bool
    let tokenTrendEmptyText: String
    let projectTokenEmptyText: String
    private let maximumProjectTokens: Int64

    var showsSingleDayTrendMarker: Bool { dailyPoints.count == 1 }

    init(snapshot: StatisticsSnapshot, isScanningTokenUsage: Bool = false) {
        sessionValueText = snapshot.totalSessionCount.formatted()
        sessionDetailText =
            "已统计 \(snapshot.measuredSessionCount) / \(snapshot.totalSessionCount)"
        totalTokenValueText = snapshot.totalUsage.totalTokens.formatted(
            chineseCompactNumberFormat
        )
        totalTokenDetailText = "\(snapshot.totalUsage.totalTokens.formatted()) Token"
        averageValueText = snapshot.averageTokensPerMeasuredSession.formatted(
            chineseCompactNumberFormat
        )
        averageDetailText =
            snapshot.measuredSessionCount == 0
            ? "暂无已统计会话"
            : "按已统计会话计算"
        cachedInputValueText = snapshot.totalUsage.cachedInputTokens.formatted(
            chineseCompactNumberFormat
        )
        cachedInputDetailText =
            "\(snapshot.totalUsage.cachedInputTokens.formatted()) Token"
        dailyPoints = snapshot.dailyPoints
        topProjects = Array(snapshot.projectRows.prefix(5))
        showsTokenScanProgress = isScanningTokenUsage
        tokenTrendEmptyText =
            isScanningTokenUsage ? "正在统计 Token…" : "暂无 Token 趋势"
        projectTokenEmptyText =
            isScanningTokenUsage ? "正在统计 Token…" : "暂无项目统计"
        maximumProjectTokens = topProjects.first?.usage.totalTokens ?? 0
    }

    func projectFraction(_ project: StatisticsProjectRow) -> Double {
        guard maximumProjectTokens > 0 else { return 0 }
        return min(
            1,
            max(0, Double(project.usage.totalTokens) / Double(maximumProjectTokens))
        )
    }

    func compact(_ value: Int64) -> String {
        value.formatted(chineseCompactNumberFormat)
    }
}

struct MenuBarStatus {
    let compactQuotaText: String
    let compactTokenText: String
    let quotaFraction: Double
    let sessionTotalText: String
    let quotaDetailText: String
    let showsProgress: Bool
    let account: MenuBarAccountStatus
    let weeklyQuota: MenuBarQuotaStatus
    let tokenCoverageText: String
    let tokenCoveragePercentText: String
    let tokenCoverageFraction: Double

    var quotaColor: MenuBarQuotaColor {
        weeklyQuota.color
    }

    init(
        snapshot: StatisticsSnapshot,
        quotaCycleTokens: Int64? = nil,
        rateLimits: CodexRateLimitSnapshot?,
        account: CodexAccountSnapshot?,
        isLoading: Bool,
        isRefreshing: Bool,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.init(
            totalSessions: snapshot.totalSessionCount,
            measuredSessions: snapshot.measuredSessionCount,
            quotaCycleTokens: quotaCycleTokens,
            rateLimits: rateLimits,
            account: account,
            isLoading: isLoading,
            isRefreshing: isRefreshing,
            now: now
        )
    }

    init(
        totalSessions: Int,
        measuredSessions: Int,
        quotaCycleTokens: Int64? = nil,
        rateLimits: CodexRateLimitSnapshot?,
        account: CodexAccountSnapshot?,
        isLoading: Bool,
        isRefreshing: Bool,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        let totalSessions = max(0, totalSessions)
        let measuredSessions = min(totalSessions, max(0, measuredSessions))
        let isInitialLoading = isLoading && totalSessions == 0
        let weeklyRemaining = rateLimits?.weeklyWindow?.remainingPercent
        let quotaText = weeklyRemaining.map { "\($0)%" } ?? "--"
        let coveragePercent =
            totalSessions == 0
            ? 0
            : Int((Double(measuredSessions) / Double(totalSessions) * 100).rounded())

        compactQuotaText = "周剩 \(quotaText)"
        compactTokenText =
            quotaCycleTokens.map {
                "已用 \($0.formatted(chineseCompactNumberFormat))"
            } ?? "已用 --"
        quotaFraction = Double(weeklyRemaining ?? 0) / 100
        sessionTotalText = isInitialLoading ? "会话 …" : "会话总数 \(totalSessions)"
        quotaDetailText = "Codex 周配额剩余 \(quotaText)"
        showsProgress = isLoading || isRefreshing
        self.account = MenuBarAccountStatus(
            account: account,
            entitlementPlanType: rateLimits?.planType
        )
        weeklyQuota = MenuBarQuotaStatus(window: rateLimits?.weeklyWindow, now: now)
        tokenCoverageText = "Token 覆盖 \(measuredSessions) / \(totalSessions)"
        tokenCoveragePercentText = "\(coveragePercent)%"
        tokenCoverageFraction = Double(coveragePercent) / 100
    }
}
