import SwiftUI

struct SessionManagerView: View {
    @ObservedObject var model: SessionListModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingNewCollection = false
    @State private var showingNewTag = false
    @State private var collectionName = ""
    @State private var tagName = ""
    @State private var tagColorHex = "#5C78BB"

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            detail
        }
        .task { await model.reloadIfStale() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.reloadIfStale() }
        }
        .onChange(of: model.selection) { _, _ in
            model.selectedThreadID = nil
        }
        .onChange(of: model.visibleThreads.map(\.id)) { _, visibleThreadIDs in
            guard let selectedThreadID = model.selectedThreadID,
                !visibleThreadIDs.contains(selectedThreadID)
            else { return }
            model.selectedThreadID = nil
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
        .alert("操作失败", isPresented: errorPresented) {
            Button("知道了") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Label("统计概览", systemImage: "chart.bar.xaxis")
                .tag(SidebarSelection.statistics)
            sidebarRow("最近会话", systemImage: "clock", count: model.activeThreads.count)
                .tag(SidebarSelection.recent)
            sidebarRow("收藏", systemImage: "star.fill", count: favoriteCount)
                .tag(SidebarSelection.favorites)
            sidebarRow("未加入分类", systemImage: "tray", count: unclassifiedCount)
                .tag(SidebarSelection.unclassified)
            sidebarRow("无项目", systemImage: "questionmark.folder", count: noProjectCount)
                .tag(SidebarSelection.noProject)
            sidebarRow("已归档", systemImage: "archivebox", count: model.archivedThreads.count)
                .tag(SidebarSelection.archived)

            Section("项目") {
                OutlineGroup(model.projectTree, children: \.outlineChildren) { project in
                    sidebarRow(project.name, systemImage: "folder", count: project.totalCount)
                        .help(project.path)
                        .tag(SidebarSelection.project(project.path))
                }
            }

            Section("分类") {
                ForEach(model.collections) { collection in
                    sidebarRow(
                        collection.name,
                        systemImage: "square.grid.2x2",
                        count: collectionCount(collection.id)
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
                        countText(tagCount(tag.id))
                    }
                    .tag(SidebarSelection.tag(tag.id))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SessionNest")
    }

    @ViewBuilder
    private var detail: some View {
        if model.selection == .statistics {
            StatisticsDashboardView(model: model)
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        List(model.visibleThreads, selection: $model.selectedThreadID) { item in
            SessionRow(item: item) {
                Task { await model.toggleFavorite(threadID: item.id) }
            }
            .tag(item.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.selectedThreadID = item.id
                model.open(threadID: item.id)
            }
            .contextMenu { contextMenu(for: item) }
        }
        .overlay {
            if model.isLoading && model.visibleThreads.isEmpty {
                ProgressView("正在加载会话…")
            } else if model.visibleThreads.isEmpty {
                ContentUnavailableView(
                    "没有会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("当前分类或筛选条件下没有可显示的会话。")
                )
            }
        }
        .onKeyPress(.return) {
            guard let threadID = model.selectedThreadID else { return .ignored }
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
            .disabled(model.isLoading)

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
        Button(model.selection == .archived ? "取消归档" : "归档") {
            Task {
                if model.selection == .archived {
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
                    model.selection = selection
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
        }
    }

    private var favoriteCount: Int {
        model.activeThreads.count { model.metadata[$0.id]?.isFavorite == true }
    }

    private var unclassifiedCount: Int {
        model.activeThreads.count { model.metadata[$0.id]?.collectionID == nil }
    }

    private var noProjectCount: Int {
        model.activeThreads.count {
            ThreadProjectClassification.effectiveResolution(
                for: $0,
                cached: model.threadProjects[$0.id]
            ).isNoProject
        }
    }

    private func collectionCount(_ collectionID: String) -> Int {
        model.activeThreads.count { model.metadata[$0.id]?.collectionID == collectionID }
    }

    private func tagCount(_ tagID: String) -> Int {
        model.activeThreads.count { model.threadTags[$0.id]?.contains(tagID) == true }
    }

    private var trimmedCollectionName: String {
        collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTagName: String {
        tagName.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func resetTagInput() {
        tagName = ""
        tagColorHex = "#5C78BB"
    }
}

private struct SessionRow: View {
    let item: ManagedThread
    let toggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleFavorite) {
                Image(systemName: item.metadata.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(item.metadata.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.metadata.isFavorite ? "取消收藏" : "收藏")
            .help(item.metadata.isFavorite ? "取消收藏" : "收藏")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.thread.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.thread.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.projectName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let branch = item.thread.gitInfo?.branch, !branch.isEmpty {
                    Text(branch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 140, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(item.tags.prefix(2)) { tag in
                    Text(tag.name)
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
        .padding(.vertical, 5)
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
