import SwiftUI

extension MenuBarQuotaColor {
    var swiftUIColor: Color {
        switch self {
        case .gray: .gray
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }
}

struct SessionNestStatusLabel: View {
    @ObservedObject var model: SessionListModel
    @ObservedObject var refreshState: StatusItemRefreshState

    var body: some View {
        let status = status

        HStack(spacing: SessionNestStatusLabelLayout.spacing) {
            ZStack {
                Circle()
                    .stroke(
                        Color.primary.opacity(0.2),
                        lineWidth: SessionNestStatusLabelLayout.ringLineWidth
                    )
                Circle()
                    .trim(from: 0, to: CGFloat(status.quotaFraction))
                    .stroke(
                        status.quotaColor.swiftUIColor,
                        style: StrokeStyle(
                            lineWidth: SessionNestStatusLabelLayout.ringLineWidth,
                            lineCap: SessionNestStatusLabelLayout.ringLineCap
                        )
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(
                width: SessionNestStatusLabelLayout.ringDiameter,
                height: SessionNestStatusLabelLayout.ringDiameter
            )

            VStack(alignment: .leading, spacing: SessionNestStatusLabelLayout.verticalSpacing) {
                Text(status.compactQuotaText)
                    .font(
                        .system(
                            size: SessionNestStatusLabelLayout.fontSize,
                            weight: .semibold
                        )
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)

                Text(status.compactTokenText)
                    .font(
                        .system(
                            size: SessionNestStatusLabelLayout.tokenFontSize,
                            weight: .medium
                        )
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            refreshState.isPopoverShown
                ? Color(white: SessionNestStatusLabelLayout.selectedBackgroundWhiteLevel)
                : Color.clear,
            in: RoundedRectangle(
                cornerRadius: SessionNestStatusLabelLayout.selectedBackgroundCornerRadius
            )
        )
        .allowsHitTesting(false)
    }

    private var status: MenuBarStatus {
        let statistics = model.statisticsSnapshot
        return MenuBarStatus(
            totalSessions: model.totalSessionCount,
            measuredSessions: statistics.measuredSessionCount,
            quotaCycleTokens: model.currentQuotaCycleTokenUsage(),
            rateLimits: model.rateLimitSnapshot,
            account: model.accountSnapshot,
            isLoading: model.isLoading,
            isRefreshing: refreshState.isRefreshing || model.isScanningTokenUsage
        )
    }
}
