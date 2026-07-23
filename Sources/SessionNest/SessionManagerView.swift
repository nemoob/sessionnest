import SwiftUI

enum SessionSearchKeyboard {
    static func handleEscape(query: inout String, isFocused: inout Bool) -> Bool {
        guard isFocused else { return false }
        if query.isEmpty {
            isFocused = false
        } else {
            query = ""
        }
        return true
    }
}

enum SessionRowAccessibility {
    static func label(for item: ManagedThread, relativeActivity: String) -> String {
        var components = [
            item.thread.displayTitle,
            "项目 \(item.projectName)",
        ]
        if let branch = item.thread.gitInfo?.branch, !branch.isEmpty {
            components.append("分支 \(branch)")
        }
        if !item.tags.isEmpty {
            components.append("标签 \(item.tags.map(\.name).joined(separator: "、"))")
        }
        components.append("更新于 \(relativeActivity)")
        return components.joined(separator: "，")
    }
}

struct SessionManagerView: View {
    @ObservedObject var model: SessionListModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isSearchFocused: Bool

    @State private var showingNewCollection = false
    @State private var showingNewTag = false
    @State private var showingNewSavedView = false
    @State private var collectionName = ""
    @State private var tagName = ""
    @State private var tagColorHex = "#5C78BB"
    @State private var savedViewName = ""

    var body: some View {
        // 仪表盘不显示会话列表，避免为其状态更新构建并排序隐藏列表。
        let visibleThreads =
            model.selection.showsSessionList
            ? model.visibleThreads : []
        let sidebarCounts = model.sidebarCounts
        NavigationSplitView {
            sidebar(counts: sidebarCounts)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detail(visibleThreads: visibleThreads)
        }
        .task { await model.reloadIfStale() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.reloadIfStale() }
        }
        .onChange(of: model.selection) { _, _ in
            model.selectedThreadIDs.removeAll()
        }
        .onChange(of: visibleThreads.map(\.id)) { _, visibleThreadIDs in
            model.selectedThreadIDs.formIntersection(visibleThreadIDs)
        }
        .alert("新建分类", isPresented: $showingNewCollection) {
            TextField("分类名称", text: $collectionName)
            Button("取消", role: .cancel) { collectionName = "" }
            Button("创建") { createCollection() }
                .disabled(trimmedCollectionName.isEmpty)
        }
        .alert("新建标签", isPresented: $showingNewTag) {
            TextField("标签名称", text: $tagName)
            TextField("颜色（如 #5C78BB）", text: $tagColorHex)
            Button("取消", role: .cancel) { resetTagInput() }
            Button("创建") { createTag() }
                .disabled(trimmedTagName.isEmpty || normalizedHexColor(tagColorHex) == nil)
        }
        .alert("保存当前视图", isPresented: $showingNewSavedView) {
            TextField("视图名称", text: $savedViewName)
            Button("取消", role: .cancel) { savedViewName = "" }
            Button("保存") { createSavedView() }
                .disabled(trimmedSavedViewName.isEmpty)
        } message: {
            Text("保存当前范围、搜索词、时间和排序。")
        }
        .alert("操作失败", isPresented: errorPresented) {
            Button("知道了") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private func sidebar(counts: SidebarCounts) -> some View {
        List(selection: sidebarSelection) {
            Label("额度", systemImage: "gauge.with.dots.needle.67percent")
                .tag(SidebarSelection.quota)
            Label("统计概览", systemImage: "chart.bar.xaxis")
                .tag(SidebarSelection.statistics)
            sidebarRow("最近会话", systemImage: "clock", count: model.activeThreads.count)
                .tag(SidebarSelection.recent)
            sidebarRow("收藏", systemImage: "star.fill", count: counts.favoriteCount)
                .tag(SidebarSelection.favorites)
            sidebarRow("未加入分类", systemImage: "tray", count: counts.unclassifiedCount)
                .tag(SidebarSelection.unclassified)
            sidebarRow("无项目", systemImage: "questionmark.folder", count: counts.noProjectCount)
                .tag(SidebarSelection.noProject)
            sidebarRow("已归档", systemImage: "archivebox", count: model.archivedThreads.count)
                .tag(SidebarSelection.archived)

            if !model.savedViews.isEmpty {
                Section("保存视图") {
                    ForEach(model.savedViews) { savedView in
                        Label(savedView.name, systemImage: "bookmark")
                            .lineLimit(1)
                            .tag(SidebarSelection.savedView(savedView.id))
                            .contextMenu {
                                Button("删除视图", role: .destructive) {
                                    Task { await model.deleteSavedView(id: savedView.id) }
                                }
                            }
                    }
                }
            }

            Section("项目") {
                ProjectDirectoryRows(
                    projects: model.projectTree,
                    expandedProjectPaths: $model.expandedProjectPaths
                )
            }

            Section("分类") {
                ForEach(model.collections) { collection in
                    sidebarRow(
                        collection.name,
                        systemImage: "square.grid.2x2",
                        count: counts.collectionCounts[collection.id] ?? 0
                    )
                    .tag(SidebarSelection.collection(collection.id))
                }
            }

            Section("标签") {
                ForEach(model.tags) { tag in
                    HStack {
                        Circle()
                            .fill(color(for: tag.colorHex))
                            .frame(width: 8, height: 8)
                        Text(tag.name)
                            .lineLimit(1)
                        Spacer()
                        countText(counts.tagCounts[tag.id] ?? 0)
                    }
                    .tag(SidebarSelection.tag(tag.id))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SessionNest")
    }

    @ViewBuilder
    private func detail(visibleThreads: [ManagedThread]) -> some View {
        if model.selection == .quota {
            QuotaDashboardView(model: model)
        } else if model.selection == .statistics {
            StatisticsDashboardView(model: model)
        } else {
            sessionList(visibleThreads: visibleThreads)
        }
    }

    private func sessionList(visibleThreads: [ManagedThread]) -> some View {
        List(visibleThreads, selection: $model.selectedThreadIDs) { item in
            SessionRow(
                item: item,
                query: model.query,
                open: { model.open(threadID: item.id) },
                toggleFavorite: {
                    Task { await model.toggleFavorite(threadID: item.id) }
                }
            )
            .tag(item.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.selectedThreadIDs = [item.id]
                model.open(threadID: item.id)
            }
            .contextMenu { contextMenu(for: item) }
        }
        .overlay {
            if model.isLoading && visibleThreads.isEmpty {
                ProgressView("正在加载会话…")
            } else if visibleThreads.isEmpty {
                ContentUnavailableView(
                    "没有会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("当前分类或筛选条件下没有可显示的会话。")
                )
            }
        }
        .onKeyPress(.return) {
            guard model.selectedThreadIDs.count == 1,
                let threadID = model.selectedThreadIDs.first
            else { return .ignored }
            model.open(threadID: threadID)
            return .handled
        }
        .navigationTitle(selectionTitle)
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            TextField("搜索标题、预览、项目、分支或标签", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
                .focused($isSearchFocused)
                .onKeyPress(.escape) {
                    var isFocused = isSearchFocused
                    guard
                        SessionSearchKeyboard.handleEscape(
                            query: &model.query,
                            isFocused: &isFocused
                        )
                    else { return .ignored }
                    isSearchFocused = isFocused
                    return .handled
                }
                .help("空格分隔多个关键词，全部命中才显示")

            Button {
                isSearchFocused = true
            } label: {
                Label("搜索", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .help("聚焦会话搜索（⌘F）")

            Picker("时间", selection: $model.timeFilter) {
                ForEach(SessionTimeFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            Picker("排序", selection: $model.sortOrder) {
                ForEach(SessionSortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if model.isClassifyingProjects {
                ProgressView()
                    .controlSize(.small)
                    .help("正在根据会话内容整理项目目录")
            }

            Button {
                Task { await model.reload() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("刷新")
            // Token 扫描尚未完成时禁止重新加载，避免取消并重启同一批日志工作。
            .disabled(model.isLoading || model.isScanningTokenUsage)

            Button {
                collectionName = ""
                showingNewCollection = true
            } label: {
                Label("新建分类", systemImage: "folder.badge.plus")
            }

            Button {
                resetTagInput()
                showingNewTag = true
            } label: {
                Label("新建标签", systemImage: "tag")
            }

            Button {
                savedViewName = ""
                showingNewSavedView = true
            } label: {
                Label("保存当前视图", systemImage: "bookmark")
            }
            .help("保存当前范围、搜索词、时间和排序")

            if !model.selectedThreadIDs.isEmpty {
                Menu {
                    Button("收藏") {
                        let selectedThreadIDs = model.selectedThreadIDs
                        Task {
                            await model.setFavorite(
                                threadIDs: selectedThreadIDs,
                                isFavorite: true
                            )
                        }
                    }
                    Button("取消收藏") {
                        let selectedThreadIDs = model.selectedThreadIDs
                        Task {
                            await model.setFavorite(
                                threadIDs: selectedThreadIDs,
                                isFavorite: false
                            )
                        }
                    }
                    Divider()
                    Button(model.isShowingArchivedThreads ? "取消归档" : "归档") {
                        let selectedThreadIDs = model.selectedThreadIDs
                        let isShowingArchivedThreads = model.isShowingArchivedThreads
                        Task {
                            if isShowingArchivedThreads {
                                await model.unarchive(threadIDs: selectedThreadIDs)
                            } else {
                                await model.archive(threadIDs: selectedThreadIDs)
                            }
                        }
                    }
                } label: {
                    Label(
                        "\(model.selectedThreadIDs.count) 个会话",
                        systemImage: "checkmark.circle"
                    )
                }
                .help("批量操作选中的会话")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ManagedThread) -> some View {
        Button(item.metadata.isFavorite ? "取消收藏" : "收藏") {
            Task { await model.toggleFavorite(threadID: item.id) }
        }
        Menu("移动到分类") {
            Button("未分类") {
                Task { await model.move(threadID: item.id, to: nil) }
            }
            ForEach(model.collections) { collection in
                Button(collection.name) {
                    Task { await model.move(threadID: item.id, to: collection.id) }
                }
            }
        }
        Menu("标签") {
            ForEach(model.tags) { tag in
                let isSelected = item.tags.contains { $0.id == tag.id }
                Button((isSelected ? "✓ " : "") + tag.name) {
                    var ids = Set(item.tags.map(\.id))
                    if isSelected {
                        ids.remove(tag.id)
                    } else {
                        ids.insert(tag.id)
                    }
                    Task { await model.setTags(threadID: item.id, tagIDs: ids) }
                }
            }
        }
        Divider()
        Button(model.isShowingArchivedThreads ? "取消归档" : "归档") {
            Task {
                if model.isShowingArchivedThreads {
                    await model.unarchive(threadID: item.id)
                } else {
                    await model.archive(threadID: item.id)
                }
            }
        }
    }

    private func sidebarRow(_ title: String, systemImage: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            Spacer()
            countText(count)
        }
    }

    private func countText(_ count: Int) -> some View {
        Text(count.formatted())
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: { model.selection },
            set: { selection in
                if let selection {
                    if case .savedView(let id) = selection {
                        model.applySavedView(id: id)
                    } else {
                        model.selection = selection
                    }
                }
            }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.errorMessage = nil
                }
            }
        )
    }

    private var selectionTitle: String {
        switch model.selection {
        case .quota: "额度"
        case .recent: "最近会话"
        case .statistics: "统计概览"
        case .favorites: "收藏"
        case .unclassified: "未加入分类"
        case .noProject: "无项目"
        case .archived: "已归档"
        case .project(let path): URL(fileURLWithPath: path).lastPathComponent
        case .collection(let id):
            model.collections.first { $0.id == id }?.name ?? "分类"
        case .tag(let id):
            model.tags.first { $0.id == id }?.name ?? "标签"
        case .savedView(let id):
            model.savedViews.first { $0.id == id }?.name ?? "保存视图"
        }
    }

    private var trimmedCollectionName: String {
        collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTagName: String {
        tagName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSavedViewName: String {
        savedViewName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createCollection() {
        let name = trimmedCollectionName
        guard !name.isEmpty else { return }
        collectionName = ""
        Task { await model.createCollection(name: name) }
    }

    private func createTag() {
        let name = trimmedTagName
        guard !name.isEmpty, let colorHex = normalizedHexColor(tagColorHex) else { return }
        resetTagInput()
        Task { await model.createTag(name: name, colorHex: colorHex) }
    }

    private func createSavedView() {
        let name = trimmedSavedViewName
        guard !name.isEmpty else { return }
        savedViewName = ""
        Task { await model.createSavedView(name: name) }
    }

    private func resetTagInput() {
        tagName = ""
        tagColorHex = "#5C78BB"
    }
}

private struct ProjectDirectoryRows: View {
    let projects: [ProjectDirectoryNode]
    @Binding var expandedProjectPaths: Set<String>

    var body: some View {
        ForEach(projects) { project in
            ProjectDirectoryRow(
                project: project,
                expandedProjectPaths: $expandedProjectPaths
            )
        }
    }
}

private struct ProjectDirectoryRow: View {
    let project: ProjectDirectoryNode
    @Binding var expandedProjectPaths: Set<String>

    var body: some View {
        Group {
            if project.children.isEmpty {
                rowLabel
            } else {
                DisclosureGroup(isExpanded: expansionBinding) {
                    ProjectDirectoryRows(
                        projects: project.children,
                        expandedProjectPaths: $expandedProjectPaths
                    )
                } label: {
                    rowLabel
                }
            }
        }
        .help(
            project.isSmartFolder
                ? "\(project.path)\n按真实目录自动归组"
                : project.path
        )
        .tag(SidebarSelection.project(project.path))
    }

    private var rowLabel: some View {
        HStack {
            Label(
                project.name,
                systemImage: project.isSmartFolder ? "folder.fill" : "folder"
            )
            .lineLimit(1)
            Spacer()
            Text(project.totalCount.formatted())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expandedProjectPaths.contains(project.path) },
            set: { isExpanded in
                if isExpanded {
                    expandedProjectPaths.insert(project.path)
                } else {
                    expandedProjectPaths.remove(project.path)
                }
            }
        )
    }
}

private struct SessionRow: View {
    let item: ManagedThread
    let query: String
    let open: () -> Void
    let toggleFavorite: () -> Void

    var body: some View {
        rowContent
            .padding(.vertical, 5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                SessionRowAccessibility.label(
                    for: item,
                    relativeActivity: relativeTime(item.thread.activityTimestamp)
                )
            )
            .accessibilityValue(item.metadata.isFavorite ? "已收藏" : "未收藏")
            .accessibilityHint("按 Return 在 Codex 中打开")
            .accessibilityAction {
                open()
            }
            .accessibilityAction(named: item.metadata.isFavorite ? "取消收藏" : "收藏") {
                toggleFavorite()
            }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            Button(action: toggleFavorite) {
                Image(systemName: item.metadata.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(item.metadata.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.metadata.isFavorite ? "取消收藏" : "收藏")
            .help(item.metadata.isFavorite ? "取消收藏" : "收藏")

            VStack(alignment: .leading, spacing: 4) {
                highlightedText(item.thread.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                highlightedText(item.thread.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                highlightedText(item.projectName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let branch = item.thread.gitInfo?.branch, !branch.isEmpty {
                    highlightedText(branch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 140, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(item.tags.prefix(2)) { tag in
                    highlightedText(tag.name)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .foregroundStyle(color(for: tag.colorHex))
                        .background(color(for: tag.colorHex).opacity(0.14), in: Capsule())
                }
                if item.tags.count > 2 {
                    Text("+\(item.tags.count - 2)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, alignment: .leading)

            Text(relativeTime(item.thread.activityTimestamp))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
    }

    private func highlightedText(_ value: String) -> Text {
        SessionSearch.highlightedSegments(in: value, query: query)
            .reduce(Text("")) { result, segment in
                let text = Text(segment.text)
                return result
                    + (segment.isMatch
                        ? text.bold().foregroundColor(.accentColor)
                        : text)
            }
    }
}

private func relativeTime(_ timestamp: Int64) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(
        for: Date(timeIntervalSince1970: TimeInterval(timestamp)),
        relativeTo: Date()
    )
}

private func normalizedHexColor(_ value: String) -> String? {
    var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") {
        hex.removeFirst()
    }
    if hex.count == 3 {
        hex = hex.map { "\($0)\($0)" }.joined()
    }
    guard hex.count == 6 || hex.count == 8, UInt64(hex, radix: 16) != nil else {
        return nil
    }
    return "#\(hex.uppercased())"
}

private func color(for hex: String) -> Color {
    guard let normalized = normalizedHexColor(hex),
        let value = UInt64(normalized.dropFirst(), radix: 16)
    else {
        return .accentColor
    }
    let hasAlpha = normalized.count == 9
    let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    let opacity = hasAlpha ? Double(value & 0xFF) / 255 : 1
    return Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
}
