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
    let resetAtText: String
    let color: MenuBarQuotaColor

    init(
        window: CodexRateLimitWindow?,
        now: Int64,
        calendar: Calendar = .current
    ) {
        guard let window else {
            remainingText = "-- 剩余"
            fraction = 0
            resetText = "重置时间 --"
            resetAtText = "重置时间 --"
            color = .gray
            return
        }

        let remaining = window.remainingPercent
        remainingText = "\(remaining)% 剩余"
        fraction = Double(remaining) / 100
        resetText = Self.resetText(resetsAt: window.resetsAt, now: now)
        resetAtText = Self.resetAtText(resetsAt: window.resetsAt, calendar: calendar)
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

    private static func resetAtText(resetsAt: Int64?, calendar: Calendar) -> String {
        guard let resetsAt else { return "重置时间 --" }
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: Date(timeIntervalSince1970: TimeInterval(resetsAt))
        )
        return "\(components.year ?? 0)年\(components.month ?? 0)月\(components.day ?? 0)日 "
            + String(format: "%02d:%02d 重置", components.hour ?? 0, components.minute ?? 0)
    }
}

struct MenuBarResetCreditsStatus {
    let summaryText: String
    let expirationText: String
    let availableCredits: [CodexRateLimitResetCredit]
    let isKnown: Bool
    private let calendar: Calendar

    init(
        summary: CodexRateLimitResetCreditsSummary?,
        now: Int64 = Int64(Date().timeIntervalSince1970),
        calendar: Calendar = .current
    ) {
        self.calendar = calendar
        guard let summary else {
            summaryText = "重置卡信息暂不可用"
            expirationText = "Codex 当前未提供重置卡信息"
            availableCredits = []
            isKnown = false
            return
        }

        isKnown = true
        availableCredits = summary.credits
            .filter { $0.status == "available" && $0.expiresAt > now }
            .sorted {
                if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
                if $0.grantedAt != $1.grantedAt { return $0.grantedAt < $1.grantedAt }
                return $0.id < $1.id
            }
        let availableCount = max(0, summary.availableCount)
        guard availableCount > 0 else {
            summaryText = "暂无可用重置卡"
            expirationText = "当前账户没有可用次数"
            return
        }

        summaryText = "重置卡 可用 \(availableCount) 次"
        expirationText =
            availableCredits.first.map {
                "最近于 \(Self.shortDate($0.expiresAt, calendar: calendar)) 到期"
            } ?? "到期时间暂不可用"
    }

    func fullExpirationText(for credit: CodexRateLimitResetCredit) -> String {
        Self.fullDate(credit.expiresAt, calendar: calendar)
    }

    private static func shortDate(_ timestamp: Int64, calendar: Calendar) -> String {
        let components = dateComponents(timestamp, calendar: calendar)
        return "\(components.month ?? 0)月\(components.day ?? 0)日 "
            + String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private static func fullDate(_ timestamp: Int64, calendar: Calendar) -> String {
        let components = dateComponents(timestamp, calendar: calendar)
        return "\(components.year ?? 0)年\(components.month ?? 0)月\(components.day ?? 0)日 "
            + String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private static func dateComponents(_ timestamp: Int64, calendar: Calendar) -> DateComponents {
        calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: Date(timeIntervalSince1970: TimeInterval(timestamp))
        )
    }
}

struct TokenScanHealthStatus: Equatable {
    let text: String
    let isWarning: Bool

    init(health: TokenScanHealth, isScanning: Bool) {
        if isScanning {
            text =
                health.totalCount == 0
                ? "正在发现 Token 日志…"
                : "正在追平 Token 日志 · \(health.freshCount) / \(health.totalCount) 当前可用"
            isWarning = false
        } else if health.failedCount > 0, health.staleCount > 0 {
            text =
                "\(health.staleCount) 个日志待更新，\(health.failedCount) 个扫描失败；当前统计可能偏低"
            isWarning = true
        } else if health.failedCount > 0 {
            text = "\(health.failedCount) 个日志扫描失败；旧缓存未计入当前统计"
            isWarning = true
        } else if health.staleCount > 0 {
            text = "\(health.staleCount) 个日志待更新；当前统计可能偏低"
            isWarning = true
        } else if health.totalCount > 0 {
            text = "Token 日志已追平 \(health.freshCount) / \(health.totalCount)（含子代理）"
            isWarning = false
        } else {
            text = "尚未发现可统计的 Token 日志"
            isWarning = false
        }
    }
}

struct TokenCoverageStatus: Equatable {
    let metricDetailText: String
    let noticeText: String
    let isWarning: Bool

    init(
        breakdown: TokenCoverageBreakdown,
        health: TokenScanHealth,
        isScanning: Bool
    ) {
        let coveragePercent =
            breakdown.totalSessionCount == 0
            ? 0
            : Int(
                (Double(breakdown.measuredSessionCount)
                    / Double(breakdown.totalSessionCount) * 100).rounded()
            )
        metricDetailText =
            "已统计 \(breakdown.measuredSessionCount) / \(breakdown.totalSessionCount)"
            + "（\(coveragePercent)%）"

        if isScanning {
            noticeText = TokenScanHealthStatus(health: health, isScanning: true).text
            isWarning = false
            return
        }
        guard breakdown.totalSessionCount > 0 else {
            noticeText = "当前范围内没有会话"
            isWarning = false
            return
        }
        guard breakdown.unmeasuredSessionCount > 0 else {
            let scanStatus = TokenScanHealthStatus(health: health, isScanning: false)
            noticeText =
                scanStatus.isWarning
                ? scanStatus.text
                : "全部会话均有可用 Token 统计"
            isWarning = scanStatus.isWarning
            return
        }

        let reasons = [
            Self.reason("未发现日志", count: breakdown.missingLogSessionCount),
            Self.reason("无 Token 事件", count: breakdown.emptyLogSessionCount),
            Self.reason("日志待更新", count: breakdown.staleLogSessionCount),
            Self.reason("扫描失败", count: breakdown.failedLogSessionCount),
        ].compactMap { $0 }
        noticeText =
            "未统计 \(breakdown.unmeasuredSessionCount) 个会话："
            + reasons.joined(separator: "、")
        isWarning = breakdown.staleLogSessionCount > 0 || breakdown.failedLogSessionCount > 0
    }

    private static func reason(_ title: String, count: Int) -> String? {
        count > 0 ? "\(title) \(count)" : nil
    }
}

struct MenuBarStatisticsStatus {
    let sessionValueText: String
    let sessionDetailText: String
    let totalTokenValueText: String
    let totalTokenDetailText: String
    let averageValueText: String
    let averageDetailText: String
    let nonCachedTokenValueText: String
    let nonCachedTokenDetailText: String
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
        nonCachedTokenValueText = snapshot.totalUsage.nonCachedTokens.formatted(
            chineseCompactNumberFormat
        )
        nonCachedTokenDetailText =
            "\(snapshot.totalUsage.nonCachedTokens.formatted()) Token"
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

    func tokenAxisLabel(_ value: Int64) -> String {
        compact(value)
    }
}

struct MenuBarStatus {
    let compactQuotaText: String
    let compactTokenText: String
    let quotaFraction: Double
    let sessionTotalText: String
    let quotaDetailText: String
    let quotaCycleTokenDetailText: String
    let showsProgress: Bool
    let account: MenuBarAccountStatus
    let weeklyQuota: MenuBarQuotaStatus
    let tokenCoverageText: String
    let tokenCoveragePercentText: String
    let tokenCoverageFraction: Double

    var quotaColor: MenuBarQuotaColor {
        weeklyQuota.color
    }

    var coreDetailTexts: [String] {
        [quotaDetailText, quotaCycleTokenDetailText, sessionTotalText]
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
                "本期 \($0.formatted(chineseCompactNumberFormat))"
            } ?? "本期 --"
        quotaFraction = Double(weeklyRemaining ?? 0) / 100
        sessionTotalText = isInitialLoading ? "会话 …" : "会话总数 \(totalSessions)"
        quotaDetailText = "Codex 周配额剩余 \(quotaText)"
        quotaCycleTokenDetailText =
            quotaCycleTokens.map {
                "本额度周期本地 Token \($0.formatted())"
            } ?? "本额度周期本地 Token --"
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
