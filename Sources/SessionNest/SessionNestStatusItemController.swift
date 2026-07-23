import AppKit
import Combine
import SwiftUI

enum StatusItemClickAction: Equatable {
    case togglePopover
    case showMenu

    static func resolve(eventType: NSEvent.EventType?) -> Self {
        eventType == .rightMouseUp ? .showMenu : .togglePopover
    }
}

enum StatusPopoverClickPolicy {
    static func shouldClose(
        eventWindowNumber: Int?,
        popoverWindowNumber: Int?,
        statusItemWindowNumber: Int?
    ) -> Bool {
        guard let eventWindowNumber else { return true }
        return eventWindowNumber != popoverWindowNumber
            && eventWindowNumber != statusItemWindowNumber
    }
}

enum SessionNestStatusLabelLayout {
    static let statusItemLength: CGFloat = 72
    static let horizontalInset: CGFloat = 3
    static let ringDiameter: CGFloat = 14
    static let ringLineWidth: CGFloat = 4
    static let ringLineCap: CGLineCap = .butt
    static let spacing: CGFloat = 4
    static let fontSize: CGFloat = 9
    static let tokenFontSize: CGFloat = 7
    static let verticalSpacing: CGFloat = -1
    static let hostedHeight: CGFloat = 20
    static let selectedBackgroundWhiteLevel = 0.23
    static let selectedBackgroundCornerRadius: CGFloat = 6

    static var contentWidth: CGFloat {
        statusItemLength - horizontalInset * 2
    }
}

enum SessionNestStatusPopoverLayout {
    static let width: CGFloat = 440
    static let height: CGFloat = 620
    static let scrollContentTrailingGutter: CGFloat = 8
    static let scrollViewTrailingExtension: CGFloat = 8
}

enum SessionNestQuotaRefreshSchedule {
    static let foregroundInterval: TimeInterval = 10 * 60
    static let lowPowerForegroundInterval: TimeInterval = 30 * 60
    static let backgroundInterval: TimeInterval = 30 * 60
    static let lowPowerBackgroundInterval: TimeInterval = 60 * 60

    static func isForeground(
        isApplicationActive: Bool,
        isMainWindowVisible: Bool,
        isPopoverVisible: Bool
    ) -> Bool {
        isPopoverVisible || (isApplicationActive && isMainWindowVisible)
    }

    static func interval(
        isForeground: Bool,
        isLowPowerModeEnabled: Bool
    ) -> TimeInterval {
        switch (isForeground, isLowPowerModeEnabled) {
        case (true, false):
            foregroundInterval
        case (true, true):
            lowPowerForegroundInterval
        case (false, false):
            backgroundInterval
        case (false, true):
            lowPowerBackgroundInterval
        }
    }

    static func tolerance(for interval: TimeInterval) -> TimeInterval {
        interval / 10
    }

    static func nextFireDate(
        now: Date,
        freshnessReference: Date?,
        interval: TimeInterval
    ) -> Date {
        guard let freshnessReference, freshnessReference <= now else {
            return now.addingTimeInterval(interval)
        }
        return max(now, freshnessReference.addingTimeInterval(interval))
    }
}

enum SessionNestAutomaticQuotaRefreshPolicy {
    // 低电量模式减少后台额度请求，把有效期从十分钟放宽到三十分钟。
    static let lowPowerMaximumAge = SessionNestQuotaRefreshSchedule.lowPowerForegroundInterval

    static func maximumAge(
        requestedMaximumAge: TimeInterval = SessionNestQuotaRefreshSchedule.foregroundInterval,
        isLowPowerModeEnabled: Bool
    ) -> TimeInterval {
        // 正常模式完全沿用调用方阈值，便于测试和特定自动入口明确控制。
        guard isLowPowerModeEnabled else { return requestedMaximumAge }
        // 低电量只延长较短阈值，不能反向加快调用方原本更慢的周期。
        return max(requestedMaximumAge, lowPowerMaximumAge)
    }

    static func shouldRefresh(isLoading: Bool) -> Bool {
        // 完整加载已经会取得额度，加载期间跳过定时请求避免重复工作。
        !isLoading
    }
}

struct StatusPopoverStatisticsScope {
    let snapshot: StatisticsSnapshot
    let title: String
    let dailyTokenTitle: String

    static func resolve(
        cycleSnapshot: StatisticsSnapshot?,
        fallbackSnapshot: @autoclosure () -> StatisticsSnapshot
    ) -> Self {
        if let cycleSnapshot {
            return Self(
                snapshot: cycleSnapshot,
                title: "统计概览 · 本额度周期",
                dailyTokenTitle: "本周期每日 Token"
            )
        }
        return Self(
            snapshot: fallbackSnapshot(),
            title: "统计概览 · 最近 7 天",
            dailyTokenTitle: "最近 7 天每日 Token"
        )
    }
}

@MainActor
final class SessionNestStatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let model: SessionListModel?
    private let updateChecker: AppUpdateChecker
    private let refreshState = StatusItemRefreshState()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let popover = NSPopover()
    private var modelObservation: AnyCancellable?
    private var openMainWindowAction: (() -> Void)?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var quotaRefreshTimer: Timer?
    private var refreshEnvironmentObservation: AnyCancellable?
    private var updateCheckTimer: Timer?
    private var updateCheckPreferenceObservation: AnyCancellable?
    private var isMainWindowVisible = false

    init(model: SessionListModel?, updateChecker: AppUpdateChecker) {
        self.model = model
        self.updateChecker = updateChecker
        super.init()
        popover.behavior = .transient
        popover.delegate = self

        modelObservation = model?.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateAccessibilityLabel()
            }
        }
    }

    func install() {
        guard statusItem == nil else { return }

        let statusItem = NSStatusBar.system.statusItem(
            withLength: model == nil ? 28 : SessionNestStatusLabelLayout.statusItemLength
        )
        self.statusItem = statusItem
        configureLabel(for: statusItem)
        menu.delegate = self
        menu.autoenablesItems = false
        updateAccessibilityLabel()
        startQuotaRefreshScheduling()
        startUpdateCheckScheduling()
    }

    func setOpenMainWindowAction(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    func setMainWindowVisible(_ isVisible: Bool) {
        guard isMainWindowVisible != isVisible else { return }
        isMainWindowVisible = isVisible
        refreshEnvironmentDidChange()
    }

    private func startQuotaRefreshScheduling() {
        guard model != nil, refreshEnvironmentObservation == nil else { return }
        refreshEnvironmentObservation = Publishers.MergeMany([
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            ),
            NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification
            ),
            NotificationCenter.default.publisher(
                for: Notification.Name.NSProcessInfoPowerStateDidChange
            ),
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didWakeNotification
            ),
        ])
        .sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshEnvironmentDidChange()
            }
        }
        rescheduleQuotaRefreshTimer()
    }

    private func refreshEnvironmentDidChange() {
        quotaRefreshTimer?.invalidate()
        quotaRefreshTimer = nil
        guard isForeground, let model else {
            rescheduleQuotaRefreshTimer()
            return
        }
        Task {
            // 与界面入口保持同一顺序，完整加载已读取额度时不再并发重复请求。
            await model.reloadIfStale()
            // 回到前台、退出低电量或系统唤醒后，仅补齐已经过期的额度。
            await model.refreshRateLimitsIfStale()
            rescheduleQuotaRefreshTimer()
        }
    }

    private func rescheduleQuotaRefreshTimer() {
        quotaRefreshTimer?.invalidate()
        quotaRefreshTimer = nil
        guard model != nil else { return }

        let interval = SessionNestQuotaRefreshSchedule.interval(
            isForeground: isForeground,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        let freshnessReference = [
            model?.lastSuccessfulUsageRefreshAt,
            model?.lastUsageRefreshAttemptAt,
        ]
        .compactMap { $0 }
        .max()
        let now = Date()
        let timer = Timer(
            fire: SessionNestQuotaRefreshSchedule.nextFireDate(
                now: now,
                freshnessReference: freshnessReference,
                interval: interval
            ),
            interval: 0,
            repeats: false
        ) { [weak self] _ in
            // 定时器只负责唤醒，额度状态仍统一在主线程模型中更新。
            Task { @MainActor [weak self] in
                // 控制器或模型已经释放时不再启动后台工作。
                guard let self, let model = self.model else { return }
                // 加载期间完整刷新已经包含额度读取，避免并发发起重复请求。
                guard
                    SessionNestAutomaticQuotaRefreshPolicy.shouldRefresh(
                        isLoading: model.isLoading
                    )
                else {
                    self.rescheduleQuotaRefreshTimer()
                    return
                }
                // 模型统一读取电源状态和失败退避，避免不同自动入口采用不同阈值。
                await model.refreshRateLimitsIfStale()
                // 单次 Timer 按最新成功或尝试时间排下次，手动刷新不会推迟实际期限。
                self.rescheduleQuotaRefreshTimer()
            }
        }
        timer.tolerance = SessionNestQuotaRefreshSchedule.tolerance(for: interval)
        RunLoop.main.add(timer, forMode: .common)
        quotaRefreshTimer = timer
    }

    private var isForeground: Bool {
        SessionNestQuotaRefreshSchedule.isForeground(
            isApplicationActive: NSApp.isActive,
            isMainWindowVisible: isMainWindowVisible,
            isPopoverVisible: refreshState.isPopoverShown
        )
    }

    private func startUpdateCheckScheduling() {
        guard updateCheckPreferenceObservation == nil else { return }
        updateCheckPreferenceObservation = updateChecker.$automaticallyChecksForUpdates
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.performAutomaticUpdateCheckAndReschedule()
                }
            }
        performAutomaticUpdateCheckAndReschedule()
    }

    private func performAutomaticUpdateCheckAndReschedule() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        Task { [weak self] in
            guard let self else { return }
            await updateChecker.check(.automatic)
            scheduleAutomaticUpdateCheck()
        }
    }

    private func scheduleAutomaticUpdateCheck() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        guard let fireDate = updateChecker.nextAutomaticCheckAt else { return }

        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performAutomaticUpdateCheckAndReschedule()
            }
        }
        timer.tolerance = AppUpdateSchedule.timerTolerance
        RunLoop.main.add(timer, forMode: .common)
        updateCheckTimer = timer
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func configureLabel(for statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }

        let rootView: AnyView
        if let model {
            rootView = AnyView(
                SessionNestStatusLabel(
                    model: model,
                    refreshState: refreshState
                )
            )
        } else {
            rootView = AnyView(
                Image(systemName: "exclamationmark.triangle.fill")
                    .frame(width: 18, height: 18)
                    .allowsHitTesting(false)
            )
        }

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        button.image = nil
        button.title = ""
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(
                equalTo: button.leadingAnchor,
                constant: SessionNestStatusLabelLayout.horizontalInset
            ),
            hostingView.trailingAnchor.constraint(
                equalTo: button.trailingAnchor,
                constant: -SessionNestStatusLabelLayout.horizontalInset
            ),
            hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            hostingView.heightAnchor.constraint(
                equalToConstant: SessionNestStatusLabelLayout.hostedHeight
            ),
        ])
    }

    private func updateAccessibilityLabel() {
        guard let button = statusItem?.button else { return }
        guard let model else {
            button.setAccessibilityLabel("SessionNest 启动失败")
            return
        }

        let status = status(for: model)
        button.setAccessibilityLabel(status.coreDetailTexts.joined(separator: "，"))
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let model else {
            addInfoItem("SessionNest 启动失败", to: menu)
            menu.addItem(.separator())
            addActionItem("Open SessionNest", action: #selector(openSessionNest), to: menu)
            addActionItem(
                "Quit SessionNest",
                action: #selector(quitSessionNest),
                keyEquivalent: "q",
                to: menu
            )
            return
        }

        let status = status(for: model)
        for detailText in status.coreDetailTexts {
            addInfoItem(detailText, to: menu)
        }
        if status.showsProgress {
            addInfoItem("正在更新…", systemImage: "arrow.triangle.2.circlepath", to: menu)
        }

        menu.addItem(.separator())
        let refreshItem = addActionItem("Refresh", action: #selector(refresh), to: menu)
        refreshItem.isEnabled = !status.showsProgress
        addActionItem("Open SessionNest", action: #selector(openSessionNest), to: menu)
        menu.addItem(.separator())
        addActionItem(
            "Quit SessionNest",
            action: #selector(quitSessionNest),
            keyEquivalent: "q",
            to: menu
        )
    }

    private func addInfoItem(
        _ title: String,
        systemImage: String? = nil,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let systemImage {
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
        menu.addItem(item)
    }

    @discardableResult
    private func addActionItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        to menu: NSMenu
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func status(for model: SessionListModel) -> MenuBarStatus {
        let statistics = model.statisticsSnapshot
        return MenuBarStatus(
            totalSessions: model.totalSessionCount,
            measuredSessions: statistics.measuredSessionCount,
            quotaCycleTokens: model.quotaCycleTokenUsage,
            rateLimits: model.rateLimitSnapshot,
            account: model.accountSnapshot,
            isLoading: model.isLoading,
            isRefreshing: refreshState.isRefreshing || model.isRefreshingUsage
                || model.isScanningTokenUsage
        )
    }

    @objc private func refresh() {
        guard
            let model,
            !refreshState.isRefreshing,
            !model.isRefreshingUsage,
            !model.isLoading,
            !model.isScanningTokenUsage
        else { return }
        refreshState.isRefreshing = true
        rebuildMenu(menu)

        Task {
            await model.reload()
            refreshState.isRefreshing = false
            updateAccessibilityLabel()
            rebuildMenu(menu)
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        switch StatusItemClickAction.resolve(eventType: NSApp.currentEvent?.type) {
        case .showMenu:
            if popover.isShown {
                popover.performClose(nil)
            }
            rebuildMenu(menu)
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.minY - 4),
                in: sender
            )
        case .togglePopover:
            if popover.isShown {
                popover.performClose(nil)
                return
            }
            guard let model else {
                openSessionNest()
                return
            }
            refreshState.prepareForPopoverPresentation()
            popover.contentViewController = NSHostingController(
                rootView: SessionNestStatusPopover(
                    model: model,
                    refreshState: refreshState,
                    updateChecker: updateChecker,
                    refresh: { [weak self] in self?.refresh() },
                    openMainWindow: { [weak self] in self?.openSessionNest() },
                    quit: { [weak self] in self?.quitSessionNest() }
                )
            )
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            startOutsideClickMonitoring()
            Task {
                // 先刷新过期会话；完整 reload 已包含额度读取，避免随后重复请求。
                await model.reloadIfStale()
                // 模型统一判断快照或最近尝试是否过期，完整 reload 失败也不会立即重试。
                await model.refreshRateLimitsIfStale()
            }
        }
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()

        let mouseDownEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: mouseDownEvents
        ) { [weak self] event in
            self?.closePopoverIfNeeded(eventWindowNumber: event.windowNumber)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: mouseDownEvents
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopoverIfNeeded(eventWindowNumber: nil)
            }
        }
    }

    private func closePopoverIfNeeded(eventWindowNumber: Int?) {
        guard
            popover.isShown,
            StatusPopoverClickPolicy.shouldClose(
                eventWindowNumber: eventWindowNumber,
                popoverWindowNumber: popover.contentViewController?.view.window?.windowNumber,
                statusItemWindowNumber: statusItem?.button?.window?.windowNumber
            )
        else { return }

        popover.performClose(nil)
    }

    private func stopOutsideClickMonitoring() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    @objc private func openSessionNest() {
        popover.performClose(nil)
        model?.selection = .statistics
        openMainWindowAction?()
    }

    @objc private func quitSessionNest() {
        NSApp.terminate(nil)
    }

    func popoverWillShow(_ notification: Notification) {
        refreshState.prepareForPopoverPresentation()
        statusItem?.button?.highlight(true)
        refreshEnvironmentDidChange()
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitoring()
        refreshState.isPopoverShown = false
        statusItem?.button?.highlight(false)
        refreshEnvironmentDidChange()
    }
}

@MainActor
final class StatusItemRefreshState: ObservableObject {
    @Published var isRefreshing = false
    @Published var isPopoverShown = false

    func prepareForPopoverPresentation() {
        isPopoverShown = true
    }
}
