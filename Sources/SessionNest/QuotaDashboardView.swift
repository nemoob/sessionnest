import SwiftUI

struct QuotaDashboardView: View {
    @ObservedObject var model: SessionListModel

    var body: some View {
        let quota = MenuBarQuotaStatus(
            window: model.rateLimitSnapshot?.weeklyWindow,
            now: Int64(Date().timeIntervalSince1970)
        )
        let account = MenuBarAccountStatus(
            account: model.accountSnapshot,
            entitlementPlanType: model.rateLimitSnapshot?.planType
        )
        let resetCredits = MenuBarResetCreditsStatus(summary: model.resetCreditsSnapshot)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                accountHeader(account)

                if let errorMessage = model.usageRefreshErrorMessage {
                    refreshError(errorMessage)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                    spacing: 12
                ) {
                    weeklyQuotaCard(quota)
                    cycleTokenCard
                }

                resetCreditsSection(resetCredits)

                Text(
                    "额度百分比和重置时间来自 Codex App Server；Token 数量只根据本机可读取的 Codex 会话记录统计，不代表服务端计费量，也不能与额度百分比直接换算。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .navigationTitle("额度")
        .toolbar { toolbarContent }
        .task {
            await model.reloadIfStale()
            await model.refreshRateLimitsIfStale()
        }
    }

    private func accountHeader(_ account: MenuBarAccountStatus) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Codex 账户")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Text(account.planText)
                        .fontWeight(.semibold)
                    Text(account.emailText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let refreshedAt = model.lastSuccessfulUsageRefreshAt {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("最后更新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(
                        refreshedAt,
                        format: .dateTime
                            .year().month().day()
                            .hour().minute().second()
                    )
                    .font(.caption.monospacedDigit())
                }
            } else {
                Text("尚未取得额度数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .quotaDashboardCard()
    }

    private func refreshError(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("额度刷新失败")
                    .font(.callout.weight(.semibold))
                Text("已保留上一次成功数据。\(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func weeklyQuotaCard(_ quota: MenuBarQuotaStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("每周额度", systemImage: "calendar.badge.clock")
                .font(.headline)
            Text(quota.remainingText)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            ProgressView(value: quota.fraction)
                .tint(quota.color.swiftUIColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(quota.resetText)
                Text(quota.resetAtText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 155, alignment: .topLeading)
        .padding(16)
        .quotaDashboardCard()
    }

    private var cycleTokenCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("本额度周期 Token", systemImage: "number.circle")
                .font(.headline)
            Text(cycleTokenText)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let snapshot = model.quotaCycleStatisticsSnapshot {
                ProgressView(
                    value: Double(snapshot.measuredSessionCount),
                    total: Double(max(1, snapshot.totalSessionCount))
                )
                Text(
                    "覆盖 \(snapshot.measuredSessionCount) / \(snapshot.totalSessionCount) 个本周期会话"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("服务端周期边界暂不可用，无法计算本周期本地 Token。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 155, alignment: .topLeading)
        .padding(16)
        .quotaDashboardCard()
    }

    private func resetCreditsSection(_ status: MenuBarResetCreditsStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("额度重置卡")
                    .font(.headline)
                Text("\(status.summaryText) · \(status.expirationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if status.availableCredits.isEmpty {
                ContentUnavailableView(
                    status.isKnown ? "暂无可用重置卡" : "重置卡信息暂不可用",
                    systemImage: "arrow.counterclockwise.circle",
                    description: Text(status.expirationText)
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(status.availableCredits) { credit in
                        resetCreditCard(credit, status: status)
                    }
                }
            }
        }
        .padding(16)
        .quotaDashboardCard()
    }

    private func resetCreditCard(
        _ credit: CodexRateLimitResetCredit,
        status: MenuBarResetCreditsStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("完整重置", systemImage: "arrow.counterclockwise.circle.fill")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("可用")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Text("\(status.fullExpirationText(for: credit)) 到期")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(credit.description)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(12)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if model.isLoading || model.isRefreshingUsage {
                ProgressView()
                    .controlSize(.small)
                    .help(model.isLoading ? "正在加载账户数据" : "正在刷新额度")
            }

            Button {
                Task { await model.refreshRateLimits() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("刷新额度与重置卡信息")
            .disabled(model.isLoading || model.isRefreshingUsage)
        }
    }

    private var cycleTokenText: String {
        guard let tokenUsage = model.quotaCycleTokenUsage else { return "--" }
        return tokenUsage.formatted(
            .number
                .notation(.compactName)
                .locale(Locale(identifier: "zh-Hans-CN"))
        )
    }
}

extension View {
    fileprivate func quotaDashboardCard() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.45), lineWidth: 1)
            }
    }
}
