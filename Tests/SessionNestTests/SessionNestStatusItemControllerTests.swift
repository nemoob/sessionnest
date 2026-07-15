import AppKit
import Testing

@testable import SessionNest

@Test func publicLinksUseApprovedDestinationsAndSymbols() {
    #expect(SessionNestPublicLink.website.url.absoluteString == "https://www.nemoob.cn/")
    #expect(SessionNestPublicLink.website.systemImage == "globe")
    #expect(
        SessionNestPublicLink.repository.url.absoluteString
            == "https://github.com/nemoob/sessionnest"
    )
    #expect(
        SessionNestPublicLink.repository.systemImage
            == "chevron.left.forwardslash.chevron.right"
    )
}

@Test func statusItemClickRoutesLeftAndRightMouseButtons() {
    #expect(StatusItemClickAction.resolve(eventType: .leftMouseUp) == .togglePopover)
    #expect(StatusItemClickAction.resolve(eventType: .rightMouseUp) == .showMenu)
    #expect(StatusItemClickAction.resolve(eventType: nil) == .togglePopover)
}

@Test func statusPopoverClickPolicyClosesOnlyOutsideTargets() {
    let popoverWindowNumber = 11
    let statusItemWindowNumber = 22

    #expect(
        !StatusPopoverClickPolicy.shouldClose(
            eventWindowNumber: popoverWindowNumber,
            popoverWindowNumber: popoverWindowNumber,
            statusItemWindowNumber: statusItemWindowNumber
        )
    )
    #expect(
        !StatusPopoverClickPolicy.shouldClose(
            eventWindowNumber: statusItemWindowNumber,
            popoverWindowNumber: popoverWindowNumber,
            statusItemWindowNumber: statusItemWindowNumber
        )
    )
    #expect(
        StatusPopoverClickPolicy.shouldClose(
            eventWindowNumber: 33,
            popoverWindowNumber: popoverWindowNumber,
            statusItemWindowNumber: statusItemWindowNumber
        )
    )
    #expect(
        StatusPopoverClickPolicy.shouldClose(
            eventWindowNumber: nil,
            popoverWindowNumber: popoverWindowNumber,
            statusItemWindowNumber: statusItemWindowNumber
        )
    )
}

@MainActor
@Test func statusItemViewStateTracksPopoverSelection() {
    let state = StatusItemRefreshState()

    #expect(!state.isPopoverShown)

    state.prepareForPopoverPresentation()

    #expect(state.isPopoverShown)
    #expect(SessionNestStatusLabelLayout.selectedBackgroundWhiteLevel == 0.23)
    #expect(SessionNestStatusLabelLayout.selectedBackgroundCornerRadius == 6)
}

@Test func statusPopoverUsesComfortableSharedDimensions() {
    #expect(SessionNestStatusPopoverLayout.width == 420)
    #expect(SessionNestStatusPopoverLayout.height == 620)
    #expect(SessionNestStatusPopoverLayout.scrollContentTrailingGutter == 8)
    #expect(SessionNestStatusPopoverLayout.scrollViewTrailingExtension == 8)
    #expect(
        SessionNestStatusPopoverLayout.scrollViewTrailingExtension
            == SessionNestStatusPopoverLayout.scrollContentTrailingGutter
    )
}

@Test func compactQuotaRingKeepsSmallRemainingGapVisible() {
    #expect(SessionNestStatusLabelLayout.ringLineWidth == 3)
    #expect(SessionNestStatusLabelLayout.ringLineCap == .butt)
}

@Test func quotaRefreshScheduleBalancesFreshnessAndEnergy() {
    #expect(SessionNestQuotaRefreshSchedule.interval == 10 * 60)
    #expect(SessionNestQuotaRefreshSchedule.tolerance == 60)
}

@Test func statusPopoverStatisticsScopePrefersQuotaCycleAndLabelsFallback() {
    let cycle = StatisticsSnapshot(
        totalUsage: .zero,
        totalSessionCount: 1,
        measuredSessionCount: 0,
        averageTokensPerMeasuredSession: 0,
        dailyPoints: [],
        projectRows: [],
        sessionRows: []
    )
    let fallback = StatisticsSnapshot(
        totalUsage: .zero,
        totalSessionCount: 7,
        measuredSessionCount: 0,
        averageTokensPerMeasuredSession: 0,
        dailyPoints: [],
        projectRows: [],
        sessionRows: []
    )

    let current = StatusPopoverStatisticsScope.resolve(
        cycleSnapshot: cycle,
        fallbackSnapshot: fallback
    )
    let missing = StatusPopoverStatisticsScope.resolve(
        cycleSnapshot: nil,
        fallbackSnapshot: fallback
    )

    #expect(current.snapshot == cycle)
    #expect(current.title == "统计概览 · 本额度周期")
    #expect(missing.snapshot == fallback)
    #expect(missing.title == "统计概览 · 最近 7 天")
}

@Test func compactStatusLayoutFitsOneHundredPercentQuota() {
    let font = NSFont.monospacedDigitSystemFont(
        ofSize: SessionNestStatusLabelLayout.fontSize,
        weight: .semibold
    )
    let textWidth = ceil(
        ("周剩 100%" as NSString).size(withAttributes: [.font: font]).width
    )
    let requiredWidth =
        SessionNestStatusLabelLayout.ringDiameter
        + SessionNestStatusLabelLayout.spacing
        + textWidth

    #expect(requiredWidth <= SessionNestStatusLabelLayout.contentWidth)
}

@Test func compactStatusLayoutFitsQuotaCycleTokenUsage() {
    let font = NSFont.monospacedDigitSystemFont(
        ofSize: SessionNestStatusLabelLayout.tokenFontSize,
        weight: .medium
    )
    let textWidth = ceil(
        ("已用 9999亿" as NSString).size(withAttributes: [.font: font]).width
    )
    let requiredWidth =
        SessionNestStatusLabelLayout.ringDiameter
        + SessionNestStatusLabelLayout.spacing
        + textWidth

    #expect(requiredWidth <= SessionNestStatusLabelLayout.contentWidth)
}

@Test func compactStatusTwoLineHeightFitsExistingStatusItem() {
    let quotaFont = NSFont.monospacedDigitSystemFont(
        ofSize: SessionNestStatusLabelLayout.fontSize,
        weight: .semibold
    )
    let tokenFont = NSFont.monospacedDigitSystemFont(
        ofSize: SessionNestStatusLabelLayout.tokenFontSize,
        weight: .medium
    )
    let requiredHeight =
        ceil(quotaFont.boundingRectForFont.height)
        + ceil(tokenFont.boundingRectForFont.height)
        + SessionNestStatusLabelLayout.verticalSpacing

    #expect(SessionNestStatusLabelLayout.statusItemLength == 68)
    #expect(requiredHeight <= SessionNestStatusLabelLayout.hostedHeight)
}
