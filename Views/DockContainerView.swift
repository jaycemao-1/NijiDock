import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit // Ensure AppKit is available for NSWorkspace
import AVFoundation

private let dockItemTypeIdentifier = "com.jaycemao.nijidock.dock-item"
private let dockItemUTType = UTType(exportedAs: dockItemTypeIdentifier)

// MARK: - 主容器视图
struct DockContainerView: View {
    @Bindable var group: DockGroup
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var windowManager: WindowManager
    @State private var selectedCategory: DockCategory? = nil
    @State private var showSettings = false
    @State private var showCategoryManager = false
    @State private var isHoveringWindow = false
    @State private var dockViewSize: CGSize = .zero
    @State private var isHoveringHeaderRevealZone = false
    @State private var isHoveringHeaderBar = false
    @State private var isHeaderBarPresented = true
    @State private var headerRevealTask: Task<Void, Never>?
    @State private var headerHideTask: Task<Void, Never>?
    @State private var searchText = ""
    @State private var draggingItemId: UUID?
    @State private var lastReorderTargetId: UUID?
    @State private var lastReorderDraggingId: UUID?
    @State private var orderedItems: [DockItem] = []
    @FocusState private var isSearchFocused: Bool
    @State private var isWindowVisible = true
    @State private var selectedWidget: WidgetKind?
    @State private var settingsWidget: WidgetKind?
    @ObservedObject private var playbackControl = VideoPlaybackControl.shared
    private let headerBarHeight: CGFloat = 50
    private let headerBarHideDelaySeconds: Double = 0.6
    private let headerBarRevealDelaySecondsFallback: Double = 2.0
    private let headerBarRevealDelaySecondsMax: Double = 10.0
    // 配置栏隐藏时的“呼出悬停区”高度：适当下移/扩大，避免必须贴到窗口最上沿才能触发
    private let headerBarRevealZoneHeight: CGFloat = 60
    private let iconScaleFactorMin: CGFloat = 0.25
    private let iconScaleFactorMax: CGFloat = 3.0

    // 主题色
    var themeColor: Color {
        if let categoryColor = selectedCategory?.colorHex {
            return Color(hex: categoryColor)
        }
        return Color(hex: group.themeColorHex)
    }

    private var dockTextColor: Color {
        group.customTextColorEnabled ? Color(hex: group.textColorHex) : .primary
    }

    private var dockSecondaryTextColor: Color {
        group.customTextColorEnabled ? dockTextColor.opacity(0.75) : .secondary
    }

    private var dockTertiaryTextColor: Color {
        group.customTextColorEnabled ? dockTextColor.opacity(0.55) : .secondary.opacity(0.7)
    }

    // 根据分类过滤项目
    var filteredItems: [DockItem] {
        // 支持排序：目前按 sortIndex，后续可扩展
        let sorted = orderedItems.isEmpty ? group.items.sorted(by: { $0.sortIndex < $1.sortIndex }) : orderedItems
        guard let category = selectedCategory else { return sorted }
        // 过滤属于当前分类的项目
        return sorted.filter { $0.category == category }
    }

    var searchedItems: [DockItem] {
        let baseItems = filteredItems
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return baseItems }

        return baseItems.filter { item in
            let labelMatch = item.label.lowercased().contains(keyword)
            let urlMatch = item.urlString.lowercased().contains(keyword)
            return labelMatch || urlMatch
        }
    }

    // 获取分类列表
    var categories: [DockCategory] {
        group.categories.sorted(by: { $0.sortIndex < $1.sortIndex })
    }

    private var hasSkin: Bool {
        group.skinType != .none && group.skinPath != nil
    }

    private var hasWidgets: Bool {
        group.clockEnabled
            || group.weatherEnabled
            || group.batteryEnabled
            || group.cpuEnabled
            || group.networkEnabled
            || group.memoryEnabled
            || group.diskEnabled
    }

    private var enabledWidgetKinds: [WidgetKind] {
        var kinds: [WidgetKind] = []
        if group.clockEnabled { kinds.append(.clock) }
        if group.weatherEnabled { kinds.append(.weather) }
        if group.batteryEnabled { kinds.append(.battery) }
        if group.cpuEnabled { kinds.append(.cpu) }
        if group.networkEnabled { kinds.append(.network) }
        if group.memoryEnabled { kinds.append(.memory) }
        if group.diskEnabled { kinds.append(.disk) }
        return kinds
    }

    private var isEditingMode: Bool {
        group.skinEditEnabled || group.widgetEditEnabled
    }

    private var isHeaderBarAutoHideActive: Bool {
        group.headerBarAutoHideEnabled && !isEditingMode
    }

    private var isHeaderBarVisible: Bool {
        !isHeaderBarAutoHideActive || isHeaderBarPresented || isSearchFocused
    }

    private var headerBarRevealDelaySeconds: Double {
        let value = group.headerBarRevealDelaySeconds
        guard value.isFinite else { return headerBarRevealDelaySecondsFallback }
        return min(max(value, 0), headerBarRevealDelaySecondsMax)
    }

    private var iconScaleFactor: CGFloat {
        guard group.iconScaleWithWindowEnabled else { return 1.0 }
        guard dockViewSize.width > 0, dockViewSize.height > 0 else { return 1.0 }

        let baseWidth = CGFloat(max(group.iconScaleBaseWidth, 1))
        let baseHeight = CGFloat(max(group.iconScaleBaseHeight, 1))
        let scaleX = dockViewSize.width / baseWidth
        let scaleY = dockViewSize.height / baseHeight

        // 期望效果：
        // - 缩小任意一边时，图标要跟着缩小以避免被裁切（取更受限的一边）
        // - 放大其中一边时，图标也应有明显变化（用几何平均避免“只拉宽不变”）
        let rawScale: CGFloat
        if scaleX < 1 || scaleY < 1 {
            rawScale = min(scaleX, scaleY)
        } else {
            rawScale = sqrt(scaleX * scaleY)
        }

        if !rawScale.isFinite {
            return 1.0
        }
        return min(max(rawScale, iconScaleFactorMin), iconScaleFactorMax)
    }

    private var effectiveGridIconSize: Double {
        let scaled = group.iconSize * Double(iconScaleFactor)
        return min(max(scaled, 24), 256)
    }

    private var effectiveListIconSize: Double {
        let scaled = 32.0 * Double(iconScaleFactor)
        return min(max(scaled, 18), 72)
    }

    var body: some View {
        rootView
    }

    private var rootView: some View {
        ZStack {
            // 背景层（支持皮肤）
            backgroundLayer

            // 内容层
            contentLayer
        }
        .overlay(skinEditorOverlay)
        .overlay(widgetInteractiveOverlay)
        .overlay(widgetEditorOverlay)
        .sheet(item: $settingsWidget) { kind in
            WidgetSettingsSheet(group: group, kind: kind)
        }
        .background(visibilityReader)
        .frame(minWidth: 280, minHeight: 240)
        // 视图加载时自愈数据
        .onAppear {
            ensureDefaultCategories()
            syncOrderedItems()
            migrateWidgetStylesIfNeeded()
            normalizeWidgetFontSizesIfNeeded()
            updateAutoHide(hovering: isHoveringWindow)
            isHeaderBarPresented = !group.headerBarAutoHideEnabled
            windowManager.updateWindowAppearance(for: group)
            if group.skinType == .video,
               let url = group.resolveSkinURLAndRefreshBookmarkIfNeeded() {
                VideoPreviewStore.shared.ensurePreview(for: url)
            }
            let skinPath = group.skinPath ?? "nil"
            DebugLog.log("dock appear: id=\(group.id) name=\(group.name) skinType=\(group.skinType) skinPath=\(skinPath)")
        }
        .onDisappear {
            headerRevealTask?.cancel()
            headerHideTask?.cancel()
        }
        .onChange(of: group.widgetEditEnabled) { _ in
            // 为避免误操作：进入/退出编辑模式时都清空选中态
            selectedWidget = nil
            settingsWidget = nil
        }
        .onChange(of: group.items.count) { _ in
            syncOrderedItems()
        }
        .onChange(of: group.items.map { $0.id }) { _ in
            syncOrderedItems()
        }
        .onChange(of: group.headerBarAutoHideEnabled) { enabled in
            headerRevealTask?.cancel()
            headerHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.22)) {
                isHeaderBarPresented = !enabled
            }
        }
        .onChange(of: group.iconScaleWithWindowEnabled) { enabled in
            guard enabled else { return }
            resetIconScaleBaseToCurrentWindow()
        }
        .onChange(of: group.headerBarRevealDelaySeconds) { _ in
            guard isHeaderBarAutoHideActive else { return }
            if isHoveringHeaderRevealZone, !isHeaderBarPresented {
                startHeaderBarRevealCountdown()
            }
        }
        .onChange(of: isSearchFocused) { focused in
            guard isHeaderBarAutoHideActive else { return }
            if focused {
                headerRevealTask?.cancel()
                headerHideTask?.cancel()
                setHeaderBarPresented(true)
            } else {
                scheduleHeaderBarHideIfNeeded()
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHoveringWindow = hovering
            }
            updateAutoHide(hovering: hovering)
            handleWindowHoverChange(hovering: hovering)
        }
        .onDrop(of: [dockItemUTType, .url, .plainText], isTargeted: nil) { providers in
            guard !isEditingMode else { return false }
            return DropHandler.handleDrop(providers: providers, group: group, category: selectedCategory, context: modelContext)
        }
        .contextMenu {
            Button("重命名 Dock") { showSettings = true }
            Button("管理分类...") { showCategoryManager = true }
            Divider()
            Button("删除 Dock", role: .destructive) { windowManager.removeDock(group) }
        }
        .sheet(isPresented: $showSettings) {
            DockSettingsView(group: group)
                .environmentObject(windowManager)
        }
        .sheet(isPresented: $showCategoryManager) {
            CategoryManagementView(group: group)
        }
        .overlay(keyboardShortcutsOverlay)
    }

    private var contentLayer: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    headerBar
                        .frame(height: isHeaderBarVisible ? headerBarHeight : 0)
                        .clipped()
                        .opacity(isHeaderBarVisible ? 1 : 0)
                        .allowsHitTesting(isHeaderBarVisible)
                        .animation(.easeInOut(duration: 0.22), value: isHeaderBarVisible)
                        .onHover { hovering in
                            isHoveringHeaderBar = hovering
                            if hovering {
                                headerHideTask?.cancel()
                            } else {
                                scheduleHeaderBarHideIfNeeded()
                            }
                        }

                    contentArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                headerRevealZone
            }
            .onAppear {
                updateDockViewSize(proxy.size)
            }
            .onChange(of: proxy.size) { newSize in
                updateDockViewSize(newSize)
            }
        }
        .allowsHitTesting(!(group.skinEditEnabled || group.widgetEditEnabled))
    }

    private var headerBar: some View {
        HStack {
            // 标签栏
            if !categories.isEmpty {
                topTabBar
            } else {
                // 如果没有分类，显示 Dock 名称
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dockSecondaryTextColor)
                    .padding(.horizontal, 4)
            }

            headerDragArea

            // 搜索 + 设置与管理按钮 (始终显示以便操作)
            HStack(spacing: 10) {
                searchField

                if hasSkin {
                    Button {
                        toggleSkinEdit()
                    } label: {
                        Image(systemName: group.skinEditEnabled ? "paintbrush.fill" : "paintbrush")
                            .font(.system(size: 12))
                            .foregroundStyle(group.skinEditEnabled ? themeColor : .secondary)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("皮肤编辑")
                }

                if hasWidgets {
                    Button {
                        group.widgetEditEnabled.toggle()
                        try? modelContext.save()
                    } label: {
                        Image(systemName: group.widgetEditEnabled ? "slider.horizontal.3" : "slider.horizontal.2.square")
                            .font(.system(size: 12))
                            .foregroundStyle(group.widgetEditEnabled ? themeColor : .secondary)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("组件编辑")
                }

                Button {
                    showCategoryManager = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("管理分类")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("设置")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: headerBarHeight) // 强制高度，防止布局塌陷
        .background(
            ZStack {
                // 允许在顶部配置栏空白区域拖动窗口（点击按钮/标签仍正常工作）
                WindowDragArea()
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.5)
                    .allowsHitTesting(false) // 材质层不拦截点击/拖拽
            }
        )
        .overlay(
            Divider().opacity(0.1), alignment: .bottom
        )
    }

    /// 顶部可拖动区域：放在标签栏与按钮之间的“空白区”，避免拦截按钮/分类点击。
    private var headerDragArea: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(minWidth: 40) // 保证在窄窗口下也有一块可拖动区域
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WindowDragArea())
    }

    private var headerRevealZone: some View {
        // 说明：
        // 以前仅在“配置栏隐藏”时启用悬停区，配置栏出现后悬停区立刻消失。
        // 当鼠标停在窗口顶部但略低于配置栏高度时，会出现：
        //  - 悬停区触发显示 -> 配置栏下压 -> 鼠标不在配置栏上 -> 触发隐藏 -> 再触发显示...
        // 造成配置栏“上下跳动”。
        // 解决：只要启用自动隐藏，就持续保留顶部悬停区，作为“显示/保持显示”的共同区域。
        let isEnabled = isHeaderBarAutoHideActive

        return PassthroughHoverZone { hovering in
            isHoveringHeaderRevealZone = hovering
            if hovering {
                headerHideTask?.cancel()
                // 仅当当前配置栏处于隐藏状态时才开始倒计时显示
                if !isHeaderBarPresented, !isSearchFocused {
                    startHeaderBarRevealCountdown()
                }
            } else {
                headerRevealTask?.cancel()
                scheduleHeaderBarHideIfNeeded()
            }
        }
        .frame(height: isEnabled ? headerBarRevealZoneHeight : 0)
        .frame(maxWidth: .infinity, alignment: .top)
        .clipped()
        .opacity(isEnabled ? 1 : 0)
        // HoverView 的 hitTest 会返回 nil，不会拦截点击/拖拽
        .allowsHitTesting(isEnabled)
    }

    @ViewBuilder
    private var contentArea: some View {
        if group.items.isEmpty {
            emptyStateView
        } else if searchedItems.isEmpty {
            emptyCategoryView
        } else {
            // 根据视图模式渲染
            if group.viewMode == .list {
                contentList
            } else {
                contentGrid
            }
        }
    }

    private var skinEditorOverlay: some View {
        Group {
            if group.skinEditEnabled, group.skinType != .none, group.skinURL != nil {
                SkinEditorOverlay(group: group)
            }
        }
    }

    private var widgetEditorOverlay: some View {
        Group {
            if group.widgetEditEnabled {
                WidgetEditorOverlay(
                    group: group,
                    selectedWidget: $selectedWidget,
                    enabledWidgets: enabledWidgetKinds
                )
            }
        }
    }

    private var widgetInteractiveOverlay: some View {
        Group {
            // 编辑模式时强制放到最上层，确保可拖动/缩放
            if group.widgetEditEnabled || group.widgetLayer == .foreground {
                widgetLayerView
            }
        }
    }

    private var visibilityReader: some View {
        WindowVisibilityReader(isVisible: $isWindowVisible)
            .frame(width: 0, height: 0)
    }

    private var keyboardShortcutsOverlay: some View {
        Group {
            Button("") {
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()

            Button("") {
                selectPreviousCategory()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .hidden()

            Button("") {
                selectNextCategory()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .hidden()
        }
    }

    private func ensureDefaultCategories() {
        if group.categories.isEmpty {
            print("Detected empty categories, initializing defaults...")
            let apps = DockCategory(name: "Apps", sortIndex: 0)
            let files = DockCategory(name: "Files", sortIndex: 1, isDefault: true)
            let web = DockCategory(name: "Web", sortIndex: 2)

            group.categories = [apps, files, web]
            try? modelContext.save()
        }
    }

    // MARK: - 背景层（皮肤优先）
    private var backgroundLayer: some View {
        ZStack {
            if group.skinType != .none, let skinURL = group.skinURL {
                SkinBackgroundView(
                    url: skinURL,
                    type: group.skinType,
                    contentMode: group.skinContentMode,
                    scale: group.skinScale,
                    offset: CGSize(width: group.skinOffsetX, height: group.skinOffsetY),
                    isMuted: !group.skinSoundEnabled,
                    allowVideoPlayback: playbackControl.isVideoPlaybackAllowed,
                    systemPlaybackEnabled: playbackControl.isSystemPlaybackEnabled,
                    playerKey: "dock-\(group.id.uuidString)",
                    previewURL: VideoPreviewStore.shared.previewURL(for: skinURL)
                )
                .opacity(group.skinOpacity)
                .allowsHitTesting(false)
            } else {
                gradientBackground
            }

            // 编辑模式时组件层会被提升到 overlay，避免背景层被内容层遮挡/拦截事件
            if group.widgetLayer == .background, !group.widgetEditEnabled {
                widgetLayerView
            }

            // 拖拽层始终在最上层
            WindowDragArea()
                .allowsHitTesting(!(group.skinEditEnabled || group.widgetEditEnabled))
        }
        .ignoresSafeArea()
    }

    private var widgetLayerView: some View {
        WidgetLayerView(
            group: group,
            isWindowVisible: $isWindowVisible,
            selectedWidget: $selectedWidget,
            settingsWidget: $settingsWidget
        )
        .allowsHitTesting(group.widgetEditEnabled)
    }

    // MARK: - 强烈渐变背景（参考产品样式）
    private var gradientBackground: some View {
        ZStack {
            // 背景色底
            Color.clear.background(.regularMaterial)

            // 主渐变 - 从左上到右下
            LinearGradient(
                gradient: Gradient(colors: [
                    themeColor.opacity(0.25),
                    themeColor.opacity(0.10),
                    Color.clear
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false) // 确保渐变不拦截点击

            // 叠加光晕效果
            RadialGradient(
                gradient: Gradient(colors: [
                    themeColor.opacity(0.15),
                    Color.clear
                ]),
                center: .topLeading,
                startRadius: 0,
                endRadius: 250
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: - 顶部标签栏（胶囊按钮样式）
    private var topTabBar: some View {
        HorizontalWheelScrollView(updateKey: topTabBarUpdateKey) {
            HStack(spacing: 8) {
                ForEach(categories) { category in
                    TopTabButton(
                        title: category.name,
                        isSelected: selectedCategory == category,
                        themeColor: themeColor,
                        inactiveTextColor: dockSecondaryTextColor,
                        action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if selectedCategory == category {
                                    selectedCategory = nil  // 再次点击取消选择
                                } else {
                                    selectedCategory = category
                                }
                            }
                        },
                        onDropItem: isEditingMode ? nil : { itemId in
                            moveItem(itemId, to: category)
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var topTabBarUpdateKey: String {
        let categorySignature = categories
            .map { "\($0.id.uuidString):\($0.name)" }
            .joined(separator: "|")

        let selectedId = selectedCategory?.id.uuidString ?? "all"
        let selectedColor = selectedCategory?.colorHex ?? ""

        let keyParts = [
            categorySignature,
            "selected=\(selectedId)",
            "selColor=\(selectedColor)",
            "theme=\(group.themeColorHex)",
            "textEnabled=\(group.customTextColorEnabled ? "1" : "0")",
            "text=\(group.textColorHex)",
            "editing=\(isEditingMode ? "1" : "0")",
        ]

        return keyParts.joined(separator: "#")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(dockSecondaryTextColor)
            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(dockTextColor)
                .focused($isSearchFocused)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .frame(width: 150)
    }

    private func moveItem(_ itemId: UUID, to category: DockCategory) {
        guard let item = group.items.first(where: { $0.id == itemId }) else { return }

        // 只有当分类不同时才移动
        if item.category != category {
            withAnimation {
                item.category = category
                try? modelContext.save()
            }
        }
    }

    private func selectNextCategory() {
        let cats = categories
        guard !cats.isEmpty else { return }
        if let selected = selectedCategory, let index = cats.firstIndex(of: selected) {
            let nextIndex = (index + 1) % cats.count
            selectedCategory = cats[nextIndex]
        } else {
            selectedCategory = cats.first
        }
    }

    private func selectPreviousCategory() {
        let cats = categories
        guard !cats.isEmpty else { return }
        if let selected = selectedCategory, let index = cats.firstIndex(of: selected) {
            let prevIndex = (index - 1 + cats.count) % cats.count
            selectedCategory = cats[prevIndex]
        } else {
            selectedCategory = cats.last
        }
    }

    private func updateAutoHide(hovering: Bool) {
        guard group.autoHideEnabled else {
            windowManager.setWindowAlpha(for: group, alpha: 1.0)
            return
        }
        let targetAlpha = hovering ? 1.0 : group.autoHideOpacity
        windowManager.setWindowAlpha(for: group, alpha: targetAlpha)
    }

    private func handleWindowHoverChange(hovering: Bool) {
        guard !hovering else { return }
        headerRevealTask?.cancel()
        headerHideTask?.cancel()
        isHoveringHeaderRevealZone = false
        isHoveringHeaderBar = false
        if isHeaderBarAutoHideActive {
            setHeaderBarPresented(false)
        }
    }

    private func setHeaderBarPresented(_ presented: Bool) {
        guard isHeaderBarPresented != presented else { return }
        if !presented {
            isHoveringHeaderBar = false
        }
        withAnimation(.easeInOut(duration: 0.22)) {
            isHeaderBarPresented = presented
        }
    }

    private func startHeaderBarRevealCountdown() {
        guard isHeaderBarAutoHideActive else { return }
        guard !isHeaderBarPresented else { return }
        guard !isSearchFocused else { return }
        headerHideTask?.cancel()
        headerRevealTask?.cancel()

        headerRevealTask = Task {
            let delayNanoseconds = UInt64(headerBarRevealDelaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            await MainActor.run {
                guard isHeaderBarAutoHideActive else { return }
                guard isHoveringHeaderRevealZone else { return }
                setHeaderBarPresented(true)
            }
        }
    }

    private func scheduleHeaderBarHideIfNeeded() {
        guard isHeaderBarAutoHideActive else { return }
        guard !isSearchFocused else { return }
        guard !isHoveringHeaderBar, !isHoveringHeaderRevealZone else { return }
        headerHideTask?.cancel()

        headerHideTask = Task {
            let delayNanoseconds = UInt64(headerBarHideDelaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            await MainActor.run {
                guard isHeaderBarAutoHideActive else { return }
                guard !isSearchFocused else { return }
                guard !isHoveringHeaderBar, !isHoveringHeaderRevealZone else { return }
                setHeaderBarPresented(false)
            }
        }
    }

    private func updateDockViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        dockViewSize = size
        ensureIconScaleBaseIfNeeded(windowSize: size)
    }

    private func ensureIconScaleBaseIfNeeded(windowSize: CGSize) {
        guard group.iconScaleWithWindowEnabled else { return }
        guard group.iconScaleBaseWidth <= 0 || group.iconScaleBaseHeight <= 0 else { return }
        guard windowSize.width > 0, windowSize.height > 0 else { return }
        group.iconScaleBaseWidth = Double(windowSize.width)
        group.iconScaleBaseHeight = Double(windowSize.height)
        try? modelContext.save()
    }

    private func resetIconScaleBaseToCurrentWindow() {
        guard group.iconScaleWithWindowEnabled else { return }
        guard let size = currentWindowSizeForIconScaleBase() else { return }
        group.iconScaleBaseWidth = Double(size.width)
        group.iconScaleBaseHeight = Double(size.height)
        try? modelContext.save()
    }

    private func currentWindowSizeForIconScaleBase() -> CGSize? {
        if dockViewSize.width > 0, dockViewSize.height > 0 {
            return dockViewSize
        }
        let rect = NSRectFromString(group.frameString)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect.size
    }

    private func toggleSkinEdit() {
        group.skinEditEnabled.toggle()
        try? modelContext.save()
    }

    // MARK: - 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(themeColor.opacity(0.6))

            VStack(spacing: 4) {
                Text("拖拽文件到此处")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(dockSecondaryTextColor)

                Text("支持应用、文件、文件夹和网页链接")
                    .font(.system(size: 11))
                    .foregroundStyle(dockTertiaryTextColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(WindowDragArea()) // 允许在空状态下拖拽窗口
    }

    // MARK: - 分类为空视图
    private var emptyCategoryView: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(themeColor.opacity(0.5))

            Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "此分类暂无内容" : "无搜索结果")
                .font(.system(size: 13))
                .foregroundStyle(dockSecondaryTextColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(WindowDragArea()) // 允许在空分类下拖拽窗口
    }

    // MARK: - 内容列表（List 模式）
    private var contentList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(searchedItems) { item in
                    Group {
                        if isEditingMode {
                            listRowView(item)
                        } else {
                            listRowView(item)
                                .onDrag {
                                    draggingItemId = item.id
                                    DockDragContext.shared.beginDrag(itemId: item.id, sourceGroupId: group.id)
                                    let ext = item.type == .url
                                        ? (item.webURL?.pathExtension ?? "")
                                        : (item.resolveFileURLAndRefreshBookmarkIfNeeded()?.pathExtension ?? "")
                                    DebugLog.log("开始拖拽: id=\(item.id) type=\(item.type) ext=\(ext) url=\(item.urlString)")
                                    // 功能1：支持拖拽到外部应用 - 同时提供内部ID和真实文件URL
                                    let provider = NSItemProvider()
                                    // 内部重排序用的ID
                                    provider.registerDataRepresentation(forTypeIdentifier: dockItemTypeIdentifier, visibility: .all) { completion in
                                        let data = "dock-item:\(item.id.uuidString)".data(using: .utf8)
                                        completion(data, nil)
                                        return nil
                                    }
                                    provider.registerObject(NSString(string: "dock-item:\(item.id.uuidString)"), visibility: .ownProcess)

                                    // 外部应用用的文件URL - 直接注册URL对象，避免SwiftUI内部走loadInPlaceFileRepresentation触发崩溃
                                    if item.type != .url {
                                        if let fileURL = item.resolveFileURLAndRefreshBookmarkIfNeeded() {
                                            provider.registerObject(fileURL as NSURL, visibility: .all)
                                        }
                                    } else if item.type == .url {
                                        if let url = item.webURL {
                                            provider.registerObject(url as NSURL, visibility: .all)
                                        }
                                    }
                                    return provider
                                }
                                .onDrop(of: [.plainText], delegate: DockItemDropDelegate(
                                    targetItem: item,
                                    group: group,
                                    modelContext: modelContext,
                                    draggingItemId: $draggingItemId,
                                    lastReorderTargetId: $lastReorderTargetId,
                                    lastReorderDraggingId: $lastReorderDraggingId,
                                    orderedItems: $orderedItems
                                ))
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(WindowDragArea()) // 允许在列表空白处拖拽窗口
    }

    private func listRowView(_ item: DockItem) -> some View {
        let iconSize = effectiveListIconSize
        let iconFrame = CGFloat(max(40.0, iconSize + 8))

        return HStack {
            DockItemView(item: item, themeColor: themeColor, textColor: dockTextColor, iconSize: iconSize)
                .frame(width: iconFrame, height: iconFrame)

            VStack(alignment: .leading) {
                Text(item.label)
                    .font(.system(size: 13))
                    .foregroundStyle(dockTextColor)
                    .lineLimit(3)
                    .truncationMode(.tail)
                if item.type == .url {
                    if let url = item.webURL {
                        Text(url.host ?? url.absoluteString)
                            .font(.system(size: 10))
                            .foregroundStyle(dockSecondaryTextColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else if let fileURL = item.resolveFileURLAndRefreshBookmarkIfNeeded() {
                    Text(fileURL.path)
                        .font(.system(size: 10))
                        .foregroundStyle(dockSecondaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.clear) // 列表项背景
        )
    }

    // MARK: - 内容网格（完全自适应）
    private var contentGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: max(64, effectiveGridIconSize + 12), maximum: max(100, effectiveGridIconSize + 40)), spacing: 12)],
                spacing: 16
            ) {
                ForEach(searchedItems) { item in
                    Group {
                        if isEditingMode {
                            gridItemView(item)
                        } else {
                            gridItemView(item)
                                .onDrag {
                                    draggingItemId = item.id
                                    DockDragContext.shared.beginDrag(itemId: item.id, sourceGroupId: group.id)
                                    let ext = item.type == .url
                                        ? (item.webURL?.pathExtension ?? "")
                                        : (item.resolveFileURLAndRefreshBookmarkIfNeeded()?.pathExtension ?? "")
                                    DebugLog.log("开始拖拽: id=\(item.id) type=\(item.type) ext=\(ext) url=\(item.urlString)")
                                    // 功能1：Grid模式同样支持拖拽到外部应用
                                    let provider = NSItemProvider()
                                    // 内部重排序用的ID
                                    provider.registerDataRepresentation(forTypeIdentifier: dockItemTypeIdentifier, visibility: .all) { completion in
                                        let data = "dock-item:\(item.id.uuidString)".data(using: .utf8)
                                        completion(data, nil)
                                        return nil
                                    }
                                    provider.registerObject(NSString(string: "dock-item:\(item.id.uuidString)"), visibility: .ownProcess)

                                    // 外部应用用的文件URL - 直接注册URL对象，避免SwiftUI内部走loadInPlaceFileRepresentation触发崩溃
                                    if item.type != .url {
                                        if let fileURL = item.resolveFileURLAndRefreshBookmarkIfNeeded() {
                                            provider.registerObject(fileURL as NSURL, visibility: .all)
                                        }
                                    } else if item.type == .url {
                                        if let url = item.webURL {
                                            provider.registerObject(url as NSURL, visibility: .all)
                                        }
                                    }
                                    return provider
                                }
                                .onDrop(of: [.plainText], delegate: DockItemDropDelegate(
                                    targetItem: item,
                                    group: group,
                                    modelContext: modelContext,
                                    draggingItemId: $draggingItemId,
                                    lastReorderTargetId: $lastReorderTargetId,
                                    lastReorderDraggingId: $lastReorderDraggingId,
                                    orderedItems: $orderedItems
                                ))
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(WindowDragArea()) // 允许在网格空白处拖拽窗口
    }

    private func gridItemView(_ item: DockItem) -> some View {
        DockItemView(item: item, themeColor: themeColor, textColor: dockTextColor, iconSize: effectiveGridIconSize)
    }

    private func syncOrderedItems() {
        let sorted = group.items.sorted(by: { $0.sortIndex < $1.sortIndex })
        if orderedItems.isEmpty {
            orderedItems = sorted
            return
        }

        let currentMap = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        var next: [DockItem] = []
        next.reserveCapacity(sorted.count)

        for item in orderedItems {
            if let fresh = currentMap[item.id] {
                next.append(fresh)
            }
        }

        let existingIds = Set(next.map { $0.id })
        for item in sorted where !existingIds.contains(item.id) {
            next.append(item)
        }

        orderedItems = next
    }

    private func migrateWidgetStylesIfNeeded() {
        var didChange = false

        if group.widgetStyleVersion < 1 {
            let baseFont = min(max(group.widgetFontSize, 10), 36)
            group.weatherFontSize = baseFont
            group.batteryFontSize = baseFont
            group.cpuFontSize = baseFont
            group.networkFontSize = baseFont
            group.weatherOpacity = group.widgetOpacity
            group.batteryOpacity = group.widgetOpacity
            group.cpuOpacity = group.widgetOpacity
            group.networkOpacity = group.widgetOpacity
            group.weatherMaskOpacity = group.widgetMaskOpacity
            group.batteryMaskOpacity = group.widgetMaskOpacity
            group.cpuMaskOpacity = group.widgetMaskOpacity
            group.networkMaskOpacity = group.widgetMaskOpacity
            group.weatherColorHex = group.widgetColorHex
            group.batteryColorHex = group.widgetColorHex
            group.cpuColorHex = group.widgetColorHex
            group.networkColorHex = group.widgetColorHex
            group.widgetStyleVersion = 1
            didChange = true
        }

        if group.widgetStyleVersion < 2 {
            let baseFont = min(max(group.widgetFontSize, 10), 36)
            group.memoryFontSize = baseFont
            group.diskFontSize = baseFont
            group.memoryOpacity = group.widgetOpacity
            group.diskOpacity = group.widgetOpacity
            group.memoryMaskOpacity = group.widgetMaskOpacity
            group.diskMaskOpacity = group.widgetMaskOpacity
            group.memoryColorHex = group.widgetColorHex
            group.diskColorHex = group.widgetColorHex
            group.widgetStyleVersion = 2
            didChange = true
        }

        if didChange {
            try? modelContext.save()
        }
    }

    private func normalizeWidgetFontSizesIfNeeded() {
        let base = min(max(group.widgetFontSize, 10), 36)
        var didChange = false
        if group.weatherFontSize <= 0 {
            group.weatherFontSize = base
            didChange = true
        }
        if group.batteryFontSize <= 0 {
            group.batteryFontSize = base
            didChange = true
        }
        if group.cpuFontSize <= 0 {
            group.cpuFontSize = base
            didChange = true
        }
        if group.networkFontSize <= 0 {
            group.networkFontSize = base
            didChange = true
        }
        if group.memoryFontSize <= 0 {
            group.memoryFontSize = base
            didChange = true
        }
        if group.diskFontSize <= 0 {
            group.diskFontSize = base
            didChange = true
        }
        if didChange {
            try? modelContext.save()
        }
    }
}

// MARK: - 拖拽排序
struct DockItemDropDelegate: DropDelegate {
    let targetItem: DockItem
    let group: DockGroup
    let modelContext: ModelContext
    @Binding var draggingItemId: UUID?
    @Binding var lastReorderTargetId: UUID?
    @Binding var lastReorderDraggingId: UUID?
    @Binding var orderedItems: [DockItem]

    func validateDrop(info: DropInfo) -> Bool {
        guard draggingItemId != nil else { return false }
        return info.hasItemsConforming(to: [UTType.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let draggingId = draggingItemId, draggingId != targetItem.id else { return }
        if lastReorderTargetId == targetItem.id, lastReorderDraggingId == draggingId {
            return
        }
        withAnimation(.easeInOut(duration: 0.12)) {
            reorderItems(draggingId: draggingId, targetId: targetItem.id)
        }
        lastReorderTargetId = targetItem.id
        lastReorderDraggingId = draggingId
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggingItemId != nil else { return false }
        draggingItemId = nil
        lastReorderTargetId = nil
        lastReorderDraggingId = nil
        applyOrderToModel()
        try? modelContext.save()
        return true
    }

    func dropExited(info: DropInfo) {
        lastReorderTargetId = nil
        lastReorderDraggingId = nil
    }

    private func reorderItems(draggingId: UUID, targetId: UUID) {
        var ordered = orderedItems
        guard let fromIndex = ordered.firstIndex(where: { $0.id == draggingId }),
              let toIndex = ordered.firstIndex(where: { $0.id == targetId }) else {
            return
        }

        if fromIndex != toIndex {
            let item = ordered.remove(at: fromIndex)
            ordered.insert(item, at: toIndex)
            orderedItems = ordered
        }
    }

    private func applyOrderToModel() {
        for (index, item) in orderedItems.enumerated() {
            if item.sortIndex != index {
                item.sortIndex = index
            }
        }
    }
}

// MARK: - 顶部标签按钮
struct TopTabButton: View {
    let title: String
    let isSelected: Bool
    let themeColor: Color
    let inactiveTextColor: Color
    let action: () -> Void
    var onDropItem: ((UUID) -> Void)? = nil
    @State private var isTargeted = false

    var body: some View {
        Group {
            if onDropItem == nil {
                tabButton
            } else {
                tabButton
                    .onDrop(of: [dockItemUTType, .plainText], isTargeted: $isTargeted) { providers in
                        guard let provider = providers.first else { return false }
                        if provider.hasItemConformingToTypeIdentifier(dockItemTypeIdentifier) {
                            provider.loadItem(forTypeIdentifier: dockItemTypeIdentifier, options: nil) { (data, error) in
                                if let data = data as? Data,
                                   let string = String(data: data, encoding: .utf8),
                                   string.hasPrefix("dock-item:") {
                                    let uuidString = String(string.dropFirst(10))
                                    if let uuid = UUID(uuidString: uuidString) {
                                        DispatchQueue.main.async {
                                            onDropItem?(uuid)
                                        }
                                    }
                                }
                            }
                            return true
                        }
                        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { (data, error) in
                            if let data = data as? Data, let string = String(data: data, encoding: .utf8), string.hasPrefix("dock-item:") {
                                let uuidString = String(string.dropFirst(10))
                                if let uuid = UUID(uuidString: uuidString) {
                                    DispatchQueue.main.async {
                                        onDropItem?(uuid)
                                    }
                                }
                            }
                        }
                        return true
                    }
            }
        }
    }

    private var tabButton: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isSelected ? themeColor.opacity(0.25) : (isTargeted ? themeColor.opacity(0.15) : Color.primary.opacity(0.04)))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected || isTargeted ? themeColor.opacity(0.6) : Color.clear, lineWidth: 1)
                )
                .foregroundStyle(isSelected || isTargeted ? themeColor : inactiveTextColor)
                .scaleEffect(isTargeted ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isTargeted)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 单个图标视图
struct DockItemView: View {
    var item: DockItem
    var themeColor: Color
    var textColor: Color = .primary
    var iconSize: Double = 52.0

    // 图标缓存，避免拖拽/悬停频繁触发文件系统与图标加载
    private static let iconCache = NSCache<NSString, NSImage>()

    @State private var isHovering = false
    @State private var showFullNameOnHover = false
    @State private var hoverNameTask: Task<Void, Never>?
    @State private var showFolderStack = false
    @State private var isRenaming = false
    @State private var editingLabel = ""
    // @State private var previewUrl: URL? // Quick Look disabled
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isFocused: Bool // 焦点状态

    // 兼容旧初始化方法
    init(item: DockItem, themeColor: Color) {
        self.item = item
        self.themeColor = themeColor
        self.textColor = .primary
        self.iconSize = 52.0
    }

    init(item: DockItem, themeColor: Color, textColor: Color = .primary, iconSize: Double) {
        self.item = item
        self.themeColor = themeColor
        self.textColor = textColor
        self.iconSize = iconSize
    }

    var body: some View {
        let labelFontSize = max(10.0, iconSize * 0.2)
        let labelLineHeight = labelFontSize * 1.25
        // 最多显示 3 行；若 3 行仍放不下，才在第 3 行末尾显示省略号
        let labelMaxHeight = CGFloat(max(labelLineHeight * 3, 32))

        VStack(spacing: 6) {
            // 图标
            itemIcon
                .frame(width: iconSize, height: iconSize)
                .shadow(color: .black.opacity(isHovering ? 0.15 : 0.05), radius: isHovering ? 6 : 2, y: isHovering ? 3 : 1)
                .scaleEffect(isHovering ? 1.05 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)

            // 名称
            Text(item.label)
                .font(.system(size: labelFontSize))
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .foregroundStyle(textColor.opacity(0.9))
                .frame(height: labelMaxHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovering || isFocused ? themeColor.opacity(0.15) : Color.clear) // 焦点态也显示背景
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isFocused ? themeColor.opacity(0.5) : Color.clear, lineWidth: 1.5) // 焦点边框
                )
        )
        .overlay(alignment: .top) {
            if showFullNameOnHover, shouldShowFullNameBubble {
                fullNameBubble
                    .offset(y: -10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(Rectangle())
        // 1. 悬停提示 (Tooltip)
        .help(itemTooltip)
        // 2. 焦点与键盘事件
        .focusable()
        .focused($isFocused)
        /*
        .onKeyPress(.space) {
            toggleQuickLook()
            return .handled
        }
        */
        .onHover { hover in
            isHovering = hover
            if hover {
                scheduleShowFullNameBubble()
            } else {
                cancelFullNameBubble()
            }
        }
        .onDisappear {
            cancelFullNameBubble()
        }
        .onChange(of: isRenaming) { renaming in
            if renaming {
                cancelFullNameBubble()
            }
        }
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                handleTap() // 双击打开
            }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                isFocused = true // 单击获取焦点
            }
        )
        .contextMenu {
            itemContextMenu
        }
        .alert("重命名", isPresented: $isRenaming) {
            TextField("名称", text: $editingLabel)
            Button("取消", role: .cancel) { }
            Button("完成") {
                let newName = editingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !newName.isEmpty {
                    item.label = newName
                    try? modelContext.save()
                }
            }
        }
        .popover(isPresented: $showFolderStack, arrowEdge: .bottom) {
            if let url = item.resolveFileURLAndRefreshBookmarkIfNeeded() {
                FolderStackView(folderURL: url, themeColor: themeColor, textColor: textColor)
            }
        }
    }

    private var shouldShowFullNameBubble: Bool {
        guard !isRenaming else { return false }
        let name = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        // 仅对较长名称显示悬停全名，避免过度干扰
        return name.count >= 90
    }

    private var fullNameBubble: some View {
        Text(item.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(textColor)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
            .allowsHitTesting(false)
    }

    private func scheduleShowFullNameBubble() {
        guard shouldShowFullNameBubble else { return }
        hoverNameTask?.cancel()
        hoverNameTask = Task {
            let delayNanoseconds: UInt64 = 180_000_000 // 0.18s，避免快速划过时闪烁
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            await MainActor.run {
                guard isHovering, shouldShowFullNameBubble else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    showFullNameOnHover = true
                }
            }
        }
    }

    private func cancelFullNameBubble() {
        hoverNameTask?.cancel()
        hoverNameTask = nil
        if showFullNameOnHover {
            withAnimation(.easeInOut(duration: 0.08)) {
                showFullNameOnHover = false
            }
        }
    }

    private var itemTooltip: String {
        if item.type == .url, let url = item.webURL {
            return "\(item.label)\n\(url.absoluteString)"
        }
        if let url = item.resolveFileURLAndRefreshBookmarkIfNeeded() {
            return "\(item.label)\n\(url.path)"
        }
        return item.label
    }

    private func handleTap() {
        // Fix: Apps are directories but should act as files, not folders
        let pathForTypeCheck = item.resolveFileURLAndRefreshBookmarkIfNeeded()?.path ?? item.urlString
        let isApp = pathForTypeCheck.hasSuffix(".app") || pathForTypeCheck.hasSuffix(".app/")

        if item.type == .folder && !isApp {
            showFolderStack = true
        } else {
            openItem()
        }
    }

    @ViewBuilder
    var itemContextMenu: some View {
        Button("打开") { openItem() }
        Button("在 Finder 中显示") { showInFinder() }

        // 功能9：打开所在文件夹
        if item.type != .url {
            Button("打开所在文件夹") { openContainingFolder() }
        }

        Divider()
        Button("重命名") {
            editingLabel = item.label
            isRenaming = true
        }

        // 移动到... 子菜单
        if let group = item.group, !group.categories.isEmpty {
            Menu("移动到...") {
                ForEach(group.categories.sorted(by: { $0.sortIndex < $1.sortIndex })) { category in
                    Button(category.name) {
                        moveItem(to: category)
                    }
                    .disabled(item.category == category)
                }

                if item.category != nil {
                    Divider()
                    Button("移出分类") {
                        moveItem(to: nil)
                    }
                }
            }
        }

        Divider()
        Button("删除", role: .destructive) {
            deleteItem()
        }
    }


    private func moveItem(to category: DockCategory?) {
        item.category = category
        // 尝试保存上下文以持久化更改
        try? modelContext.save()
    }

    private func deleteItem() {
        guard let group = item.group else { return }
        group.items.removeAll { $0.id == item.id }
        modelContext.delete(item)
        reindexItems(in: group)
        try? modelContext.save()
    }

    private func reindexItems(in group: DockGroup) {
        let ordered = group.items.sorted(by: { $0.sortIndex < $1.sortIndex })
        for (index, dockItem) in ordered.enumerated() {
            dockItem.sortIndex = index
        }
    }

    @ViewBuilder
    private var itemIcon: some View {
        if let icon = getIcon() {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: defaultIconName)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
        }
    }

    private var defaultIconName: String {
        switch item.type {
        case .app: return "app.fill"
        case .file: return "doc.fill"
        case .folder: return "folder.fill"
        case .url: return "globe"
        }
    }

    private func getIcon() -> NSImage? {
        if item.type == .url {
            let cacheKey = "url-default" as NSString
            if let cached = DockItemView.iconCache.object(forKey: cacheKey) {
                return cached
            }
            let icon = IconStore.shared.icon(for: "/Applications/Safari.app")
            icon.size = NSSize(width: 128, height: 128)
            DockItemView.iconCache.setObject(icon, forKey: cacheKey)
            return icon
        } else {
            guard let fileURL = item.resolveFileURLAndRefreshBookmarkIfNeeded() else { return nil }
            let path = fileURL.path
            let cacheKey = path as NSString
            if let cached = DockItemView.iconCache.object(forKey: cacheKey) {
                return cached
            }
            if SecurityScopedBookmark.fileExists(at: fileURL) {
                let icon = IconStore.shared.icon(for: path)
                icon.size = NSSize(width: 128, height: 128)
                DockItemView.iconCache.setObject(icon, forKey: cacheKey)
                return icon
            }
            return nil
        }
    }

    private func openItem() {
        if item.type == .url {
            guard let url = item.webURL else { return }
            NSWorkspace.shared.open(url)
        } else {
            guard let fileURL = item.resolveFileURLAndRefreshBookmarkIfNeeded() else { return }
            SecurityScopedBookmark.withAccess(to: fileURL) { scopedURL in
                NSWorkspace.shared.open(scopedURL)
            }
        }
    }

    private func showInFinder() {
        guard let fileURL = item.resolveFileURLAndRefreshBookmarkIfNeeded() else { return }
        SecurityScopedBookmark.withAccess(to: fileURL) { scopedURL in
            NSWorkspace.shared.activateFileViewerSelecting([scopedURL])
        }
    }

    // 功能9：打开所在文件夹（直接打开父目录）
    private func openContainingFolder() {
        guard let fileURL = item.resolveFileURLAndRefreshBookmarkIfNeeded() else { return }
        let parentFolder = fileURL.deletingLastPathComponent()
        SecurityScopedBookmark.withAccess(to: parentFolder) { scopedURL in
            NSWorkspace.shared.open(scopedURL)
        }
    }
}

// MARK: - Dock 设置视图
struct DockSettingsView: View {
    @Bindable var group: DockGroup
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var windowManager: WindowManager
    @Environment(\.modelContext) private var modelContext
    private var builtInSkins: [BuiltInSkin] { BuiltInSkinCatalog.load() }
    @State private var showBuiltInSkinPicker = false
    @State private var isFetchingWeatherLocation = false
    @State private var weatherLocationError: String?
    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "版本 \(version)（构建 \(build)）"
    }

    var body: some View {
        VStack(spacing: 20) {
            // 标题
            HStack {
                Text("Dock 设置")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            Text(appVersionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    // 名称
                    HStack {
                        Text("名称")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("名称", text: Binding(
                            get: { group.name },
                            set: { group.name = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    }

                    // 显示模式
                    HStack {
                        Text("显示模式")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $group.viewMode) {
                            ForEach(ViewMode.allCases, id: \.self) { mode in
                                Label(mode.title, systemImage: mode.icon).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }

                    // 图标大小
                    HStack {
                        Text(group.iconScaleWithWindowEnabled ? "基准图标大小" : "图标大小")
                            .foregroundStyle(.secondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Slider(value: $group.iconSize, in: 32...128, step: 4)
                                .frame(width: 150)
                            Text("\(Int(group.iconSize)) px")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // 窗口缩放时图标等比缩放
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("窗口缩放时图标等比缩放", isOn: $group.iconScaleWithWindowEnabled)
                        if group.iconScaleWithWindowEnabled {
                            Text("启用后，调整 Dock 窗口尺寸时，图标会按比例自动缩放。")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // 窗口比例锁定
                    HStack {
                        Text("窗口比例")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $group.aspectRatioLockRaw) {
                            ForEach(AspectRatioLock.allCases, id: \.self) { ratio in
                                Text(ratio.title).tag(ratio.rawValue)
                            }
                        }
                        .frame(width: 150)
                    }

                    // 常驻桌面
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("常驻桌面（点击桌面不收起）", isOn: $group.stayOnDesktopEnabled)
                        Text("启用后 Dock 会固定在桌面层级，可能会被其他应用窗口遮挡；但在点击桌面显示桌面项目时不会被系统收起。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // 背景透明度
                    HStack {
                        Text("背景透明度")
                            .foregroundStyle(.secondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Slider(value: $group.opacity, in: 0.2...1.0, step: 0.05)
                                .frame(width: 150)
                            Text("\(Int(group.opacity * 100)) %")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // 模糊样式
                    HStack {
                        Text("模糊样式")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $group.blurStyleRaw) {
                            ForEach(BlurStyle.allCases, id: \.self) { style in
                                Text(style.title).tag(style.rawValue)
                            }
                        }
                        .frame(width: 150)
                    }

                    // 皮肤设置
                    VStack(alignment: .leading, spacing: 10) {
                        Text("窗口皮肤")
                            .foregroundStyle(.secondary)

                        if !builtInSkins.isEmpty {
                            Button("选择内置皮肤") {
                                showBuiltInSkinPicker = true
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        HStack {
                            Button("选择图片/视频...") {
                                pickSkinFile()
                            }
                            .buttonStyle(.bordered)

                            if group.skinType != .none, group.skinPath != nil {
                                Button("清除皮肤") {
                                    clearSkin()
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        if let skinPath = group.skinPath, group.skinType != .none {
                            Text(skinPath)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)

                            HStack {
                                Text("显示模式")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Picker("", selection: $group.skinContentModeRaw) {
                                    ForEach(SkinContentMode.allCases, id: \.self) { mode in
                                        Text(mode.title).tag(mode.rawValue)
                                    }
                                }
                                .frame(width: 150)
                            }

                            if group.skinType == .video {
                                Toggle("播放皮肤声音", isOn: $group.skinSoundEnabled)
                            }

                            HStack {
                                Text("缩放")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Slider(value: $group.skinScale, in: 0.5...3.0, step: 0.05)
                                        .frame(width: 150)
                                    Text(String(format: "%.2f x", group.skinScale))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            HStack {
                                Text("透明度")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Slider(value: $group.skinOpacity, in: 0.2...1.0, step: 0.05)
                                        .frame(width: 150)
                                    Text("\(Int(group.skinOpacity * 100)) %")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            HStack {
                                Text("水平位置")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Slider(value: $group.skinOffsetX, in: -400...400, step: 1)
                                        .frame(width: 150)
                                    Text("\(Int(group.skinOffsetX)) px")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            HStack {
                                Text("垂直位置")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Slider(value: $group.skinOffsetY, in: -400...400, step: 1)
                                        .frame(width: 150)
                                    Text("\(Int(group.skinOffsetY)) px")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            HStack {
                                Spacer()
                                Button("重置位置与缩放") {
                                    resetSkinTransform()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    // 组件
                    VStack(alignment: .leading, spacing: 10) {
                        Text("组件")
                            .foregroundStyle(.secondary)

                        Toggle("时钟", isOn: $group.clockEnabled)
                        Toggle("天气", isOn: $group.weatherEnabled)
                        Toggle("电量", isOn: $group.batteryEnabled)
                        Toggle("CPU", isOn: $group.cpuEnabled)
                        Toggle("网速", isOn: $group.networkEnabled)
                        Toggle("内存", isOn: $group.memoryEnabled)
                        Toggle("磁盘", isOn: $group.diskEnabled)

                        if group.weatherEnabled {
                            Divider()
                                .opacity(0.2)

                            VStack(alignment: .leading, spacing: 10) {
                                Text("天气设置")
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 8) {
                                    TextField("城市（如：上海/Beijing）", text: $group.weatherLocationQuery)
                                        .textFieldStyle(.roundedBorder)

                                    Button {
                                        fetchWeatherLocationFromSystem()
                                    } label: {
                                        Label(isFetchingWeatherLocation ? "获取中" : "使用定位", systemImage: "location")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isFetchingWeatherLocation)
                                }

                                HStack {
                                    Text("温度单位")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Picker("", selection: $group.weatherUnitRaw) {
                                        ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                                            Text(unit.title).tag(unit.rawValue)
                                        }
                                    }
                                    .frame(width: 150)
                                }

                                if let weatherLocationError, !weatherLocationError.isEmpty {
                                    Text(weatherLocationError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }

                        Text("提示：如需调整组件位置/样式，请点击顶部“组件编辑”，选中组件后右键选择“设置...”。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // 配置栏
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("配置栏自动隐藏", isOn: $group.headerBarAutoHideEnabled)
                        if group.headerBarAutoHideEnabled {
                            Text("启用后，鼠标在窗口顶部悬停指定时间显示配置栏，离开自动收起。")
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            HStack {
                                Text("悬停显示延迟")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Slider(value: $group.headerBarRevealDelaySeconds, in: 0...5, step: 0.5)
                                        .frame(width: 150)
                                    Text(String(format: "%.1f 秒", group.headerBarRevealDelaySeconds))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    // 自动隐藏
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("自动隐藏", isOn: $group.autoHideEnabled)

                        if group.autoHideEnabled {
                            HStack {
                                Text("隐藏透明度")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Slider(value: $group.autoHideOpacity, in: 0.05...0.6, step: 0.05)
                                        .frame(width: 150)
                                    Text("\(Int(group.autoHideOpacity * 100)) %")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    // 文字颜色
                    VStack(alignment: .leading, spacing: 10) {
                        Text("文字颜色")
                            .foregroundStyle(.secondary)

                        Toggle("自定义文字颜色", isOn: $group.customTextColorEnabled)

                        if group.customTextColorEnabled {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                                ForEach(["FFFFFF", "000000"] + ThemeColor.allCases.map { $0.rawValue }, id: \.self) { hex in
                                    Button {
                                        group.textColorHex = hex
                                    } label: {
                                        Circle()
                                            .fill(Color(hex: hex))
                                            .frame(width: 22, height: 22)
                                            .overlay(
                                                Circle()
                                                    .strokeBorder(Color.primary, lineWidth: group.textColorHex == hex ? 2 : 0)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // 全局主题色 (当分类未设置颜色时使用)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("默认主题色")
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                            ForEach(ThemeColor.allCases, id: \.self) { color in
                                Button {
                                    group.themeColorHex = color.rawValue
                                } label: {
                                    Circle()
                                        .fill(color.color)
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.primary, lineWidth: group.themeColorHex == color.rawValue ? 2 : 0)
                                        )
                                        .shadow(color: color.color.opacity(0.4), radius: 2, y: 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(20)
        .frame(width: 340, height: 760)
        .sheet(isPresented: $showBuiltInSkinPicker) {
            BuiltInSkinLibrarySheet(skins: builtInSkins) { skin in
                applyBuiltInSkin(skin)
            }
        }
        .onChange(of: group.opacity) { _ in
            windowManager.updateWindowAppearance(for: group)
            saveContext()
        }
        .onChange(of: group.blurStyleRaw) { _ in
            windowManager.updateWindowAppearance(for: group)
            saveContext()
        }
        .onChange(of: group.skinTypeRaw) { _ in
            saveContext()
        }
        .onChange(of: group.skinPath) { _ in
            saveContext()
        }
        .onChange(of: group.skinScale) { _ in
            saveContext()
        }
        .onChange(of: group.skinOffsetX) { _ in
            saveContext()
        }
        .onChange(of: group.skinOffsetY) { _ in
            saveContext()
        }
        .onChange(of: group.skinOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.skinContentModeRaw) { _ in
            saveContext()
        }
        .onChange(of: group.skinEditEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.skinTypeRaw) { _ in
            applyDefaultTextColorForSkinIfNeeded()
            saveContext()
        }
        .onChange(of: group.skinPath) { _ in
            applyDefaultTextColorForSkinIfNeeded()
            saveContext()
        }
        .onChange(of: group.skinSoundEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.clockEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.widgetLayerRaw) { _ in
            saveContext()
        }
        .onChange(of: group.clockFormatRaw) { _ in
            saveContext()
        }
        .onChange(of: group.clockShowDate) { _ in
            saveContext()
        }
        .onChange(of: group.clockShowSeconds) { _ in
            saveContext()
        }
        .onChange(of: group.clockFontSize) { _ in
            saveContext()
        }
        .onChange(of: group.clockOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.clockColorHex) { _ in
            saveContext()
        }
        .onChange(of: group.widgetEditEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.weatherEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.weatherLocationQuery) { _ in
            weatherLocationError = nil
            saveContext()
        }
        .onChange(of: group.weatherUnitRaw) { _ in
            saveContext()
        }
        .onChange(of: group.batteryEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.cpuEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.networkEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.memoryEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.diskEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.widgetFontSize) { _ in
            applyWidgetFontSizeToAll()
        }
        .onChange(of: group.weatherFontSize) { _ in
            saveContext()
        }
        .onChange(of: group.batteryFontSize) { _ in
            saveContext()
        }
        .onChange(of: group.cpuFontSize) { _ in
            saveContext()
        }
        .onChange(of: group.networkFontSize) { _ in
            saveContext()
        }
        .onChange(of: group.weatherOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.weatherMaskOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.weatherColorHex) { _ in
            saveContext()
        }
        .onChange(of: group.batteryOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.batteryMaskOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.batteryColorHex) { _ in
            saveContext()
        }
        .onChange(of: group.cpuOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.cpuMaskOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.cpuColorHex) { _ in
            saveContext()
        }
        .onChange(of: group.networkOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.networkMaskOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.networkColorHex) { _ in
            saveContext()
        }
        .onChange(of: group.widgetOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.widgetMaskOpacity) { _ in
            saveContext()
        }
        .onChange(of: group.widgetColorHex) { _ in
            saveContext()
        }
        .onChange(of: group.autoHideEnabled) { _ in
            windowManager.setWindowAlpha(for: group, alpha: 1.0)
            saveContext()
        }
        .onChange(of: group.autoHideOpacity) { _ in
            if group.autoHideEnabled {
                windowManager.setWindowAlpha(for: group, alpha: group.autoHideOpacity)
            }
            saveContext()
        }
        .onChange(of: group.name) { _ in
            saveContext()
        }
        .onChange(of: group.viewModeRaw) { _ in
            saveContext()
        }
        .onChange(of: group.iconSize) { _ in
            saveContext()
        }
        .onChange(of: group.iconScaleWithWindowEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.headerBarAutoHideEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.headerBarRevealDelaySeconds) { _ in
            saveContext()
        }
        .onChange(of: group.themeColorHex) { _ in
            saveContext()
        }
        .onChange(of: group.customTextColorEnabled) { _ in
            saveContext()
        }
        .onChange(of: group.textColorHex) { _ in
            saveContext()
        }
        .onChange(of: group.stayOnDesktopEnabled) { _ in
            windowManager.updateStayOnDesktop(for: group)
            saveContext()
        }
        .onChange(of: group.aspectRatioLockRaw) { _ in
            windowManager.updateAspectRatio(for: group)
            saveContext()
        }
    }

    private func saveContext() {
        try? modelContext.save()
    }

    private func applyDefaultTextColorForSkinIfNeeded() {
        guard group.skinType != .none, group.skinPath != nil else { return }
        if !group.customTextColorEnabled {
            group.customTextColorEnabled = true
            group.textColorHex = "FFFFFF"
        }
    }

    private func pickSkinFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]

        if panel.runModal() == .OK, let url = panel.url {
            applySkin(url: url)
        }
    }

    private func applySkin(url: URL) {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        if let type = UTType(filenameExtension: fileURL.pathExtension) {
            if type.conforms(to: .movie) {
                group.skinType = .video
                VideoPreviewStore.shared.ensurePreview(for: fileURL)
            } else if type.conforms(to: .image) {
                group.skinType = .image
            } else {
                return
            }
        } else {
            return
        }
        group.skinPath = fileURL.path
        group.skinBookmarkData = SecurityScopedBookmark.createBookmarkData(for: fileURL)
    }

    private func applyBuiltInSkin(_ skin: BuiltInSkin) {
        guard let url = skin.fileURL else { return }
        group.skinType = skin.skinType
        group.skinPath = BuiltInSkinCatalog.builtinPath(for: skin.filename)
        group.skinBookmarkData = nil
        if skin.skinType == .video {
            VideoPreviewStore.shared.ensurePreview(for: url)
        }
    }

    private func clearSkin() {
        group.skinType = .none
        group.skinPath = nil
        group.skinBookmarkData = nil
        group.skinOpacity = 1.0
    }

    private func resetSkinTransform() {
        group.skinScale = 1.0
        group.skinOffsetX = 0
        group.skinOffsetY = 0
        group.skinOpacity = 1.0
    }

    private func fetchWeatherLocationFromSystem() {
        weatherLocationError = nil
        isFetchingWeatherLocation = true

        Task { @MainActor in
            defer { isFetchingWeatherLocation = false }
            do {
                let city = try await LocationService.shared.requestCurrentCityName()
                group.weatherLocationQuery = city
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                weatherLocationError = message
            }
        }
    }

    private func applyWidgetFontSizeToAll() {
        let base = min(max(group.widgetFontSize, 10), 36)
        group.weatherFontSize = base
        group.batteryFontSize = base
        group.cpuFontSize = base
        group.networkFontSize = base
        group.memoryFontSize = base
        group.diskFontSize = base
        saveContext()
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class DragView: NSView {
        private var initialLocation: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }

        override func mouseDown(with event: NSEvent) {
            self.initialLocation = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window = self.window, let initialLocation = self.initialLocation else { return }

            // 使用屏幕坐标进行计算，手动更新窗口位置，响应更灵敏
            // 获取当前鼠标在屏幕上的绝对位置
            // 注意：NSEvent.mouseLocation 返回的是屏幕坐标
            let currentLocation = NSEvent.mouseLocation

            // 计算新的窗口原点
            // 新原点 = 当前鼠标屏幕坐标 - 鼠标点击时的窗口内相对偏移
            let newOrigin = NSPoint(
                x: currentLocation.x - initialLocation.x,
                y: currentLocation.y - initialLocation.y
            )

            window.setFrameOrigin(newOrigin)
        }
    }
}

// MARK: - 悬停触发区域（不拦截点击）
struct PassthroughHoverZone: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = HoverView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? HoverView else { return }
        view.onHoverChanged = onHoverChanged
    }

    final class HoverView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        private var trackingAreaRef: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }

            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect,
            ]

            let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            onHoverChanged?(false)
        }

        // 不参与命中测试，保证鼠标点击/拖拽等事件继续传递给下层 SwiftUI 视图
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

// MARK: - 横向滚动容器（支持鼠标滚轮纵向滚动来横向滑动）
struct HorizontalWheelScrollView<Content: View>: NSViewRepresentable {
    /// 用于控制 NSHostingView 的更新频率：
    /// - Dock 主视图会因各种状态变化频繁刷新（例如组件数据、悬停状态等）
    /// - 顶部分类栏内容通常不需要每次都重建，否则会产生大量临时对象，主线程在 autoreleasepool drain 时可能出现卡顿
    /// - 仅当 updateKey 变化时才更新 rootView；窗口尺寸变化时仅更新布局
    let updateKey: AnyHashable
    let content: Content

    init(updateKey: AnyHashable, @ViewBuilder content: () -> Content) {
        self.updateKey = updateKey
        self.content = content()
    }

    func makeNSView(context: Context) -> WheelScrollView {
        let scrollView = WheelScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.borderType = .noBorder

        let hostingView = NSHostingView(rootView: AnyView(content))
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = []
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        scrollView.documentView = hostingView
        scrollView.hostingView = hostingView
        context.coordinator.lastUpdateKey = updateKey
        context.coordinator.lastBoundsSize = scrollView.contentView.bounds.size
        scrollView.updateHostingViewFrame()

        return scrollView
    }

    func updateNSView(_ nsView: WheelScrollView, context: Context) {
        let didKeyChange = context.coordinator.lastUpdateKey != updateKey
        if didKeyChange {
            nsView.setRootView(AnyView(content))
            context.coordinator.lastUpdateKey = updateKey
        }

        let boundsSize = nsView.contentView.bounds.size
        if didKeyChange || boundsSize != context.coordinator.lastBoundsSize {
            context.coordinator.lastBoundsSize = boundsSize
            nsView.updateHostingViewFrame()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastUpdateKey: AnyHashable?
        var lastBoundsSize: CGSize = .zero
    }

    final class WheelScrollView: NSScrollView {
        fileprivate var hostingView: NSHostingView<AnyView>?

        fileprivate func setRootView(_ rootView: AnyView) {
            guard let hostingView else { return }
            hostingView.rootView = rootView
            updateHostingViewFrame()
        }

        fileprivate func updateHostingViewFrame() {
            guard let hostingView else { return }
            hostingView.layoutSubtreeIfNeeded()

            // 让内容高度至少等于可视高度，避免垂直方向抖动/回弹
            let fitting = hostingView.fittingSize
            let visibleHeight = max(contentView.bounds.height, 1)
            hostingView.frame.size = NSSize(
                width: fitting.width,
                height: max(fitting.height, visibleHeight)
            )
        }

        override func scrollWheel(with event: NSEvent) {
            guard let documentView else {
                super.scrollWheel(with: event)
                return
            }

            let canScrollHorizontally = documentView.frame.width > contentView.bounds.width + 1
            let wantsHorizontal = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)

            guard canScrollHorizontally, wantsHorizontal else {
                super.scrollWheel(with: event)
                return
            }

            var origin = contentView.bounds.origin
            // 将纵向滚动映射为横向滚动：滚轮向下 -> 内容向左移动（显示右侧更多内容）
            origin.x -= event.scrollingDeltaY

            let maxX = max(0, documentView.frame.width - contentView.bounds.width)
            origin.x = min(max(origin.x, 0), maxX)

            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        }
    }
}

// MARK: - 皮肤编辑覆盖层（所见即所得）
struct SkinEditorOverlay: View {
    @Bindable var group: DockGroup
    @Environment(\.modelContext) private var modelContext
    @State private var dragStartOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var scrollMonitor: Any?

    var body: some View {
        ZStack {
            Color.black.opacity(0.08)

            // 中心参考线
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 1, height: 24)
                Spacer()
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 1, height: 24)
            }
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 24, height: 1)
                Spacer()
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 24, height: 1)
            }

            VStack(spacing: 6) {
                Text("皮肤编辑中")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("拖动调整位置 · 滚轮缩放 · 双击重置")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.35))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            resetTransform()
        }
        .highPriorityGesture(dragGesture)
        .overlay(
            Button("完成") {
                group.skinEditEnabled = false
                saveContext()
            }
            .buttonStyle(.borderedProminent)
            .padding(12),
            alignment: .topTrailing
        )
        .onAppear {
            startScrollMonitor()
        }
        .onDisappear {
            stopScrollMonitor()
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if !isDragging {
                    dragStartOffset = CGSize(width: group.skinOffsetX, height: group.skinOffsetY)
                    isDragging = true
                }
                group.skinOffsetX = dragStartOffset.width + value.translation.width
                group.skinOffsetY = dragStartOffset.height - value.translation.height
            }
            .onEnded { _ in
                isDragging = false
                saveContext()
            }
    }

    private func handleScroll(_ event: NSEvent) {
        let delta = event.scrollingDeltaY
        let step = event.hasPreciseScrollingDeltas ? 0.005 : 0.05
        let next = group.skinScale + Double(-delta) * step
        group.skinScale = min(max(next, 0.5), 3.0)
        saveContext()
    }

    private func resetTransform() {
        group.skinScale = 1.0
        group.skinOffsetX = 0
        group.skinOffsetY = 0
        saveContext()
    }

    private func saveContext() {
        try? modelContext.save()
    }

    private func startScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            guard event.window == NSApp.keyWindow else { return event }
            handleScroll(event)
            return nil
        }
    }

    private func stopScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}

// MARK: - 组件编辑覆盖层
struct WidgetEditorOverlay: View {
    @Bindable var group: DockGroup
    @Binding var selectedWidget: WidgetKind?
    let enabledWidgets: [WidgetKind]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            Color.black.opacity(0.05)
                .allowsHitTesting(false)

            VStack(spacing: 10) {
                VStack(spacing: 6) {
                    Text("组件编辑中")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(selectedWidgetTitleText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.9))
                }

                if !enabledWidgets.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(enabledWidgets) { kind in
                                Button {
                                    selectedWidget = kind
                                } label: {
                                    Text(kind.title)
                                        .font(.system(size: 11, weight: selectedWidget == kind ? .semibold : .regular))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(selectedWidget == kind ? Color.white.opacity(0.26) : Color.white.opacity(0.12))
                                        )
                                }
                                .buttonStyle(.plain)
                            }

                            if selectedWidget != nil {
                                Button {
                                    selectedWidget = nil
                                } label: {
                                    Text("取消选中")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.95))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color.white.opacity(0.10))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .frame(maxWidth: 420)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.35))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)
        }
        .overlay(
            Button("完成") {
                group.widgetEditEnabled = false
                saveContext()
            }
            .buttonStyle(.borderedProminent)
            .padding(12),
            alignment: .topTrailing
        )
    }

    private func saveContext() {
        try? modelContext.save()
    }

    private var selectedWidgetTitleText: String {
        if let selectedWidget {
            return "已选中「\(selectedWidget.title)」· 拖动调整位置 · 滚轮缩放 · 右键设置"
        }
        return "先点选组件，再拖动调整位置 · 滚轮缩放 · 右键设置"
    }
}

// MARK: - 窗口可见性监听
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = VisibilityView()
        view.onVisibilityChanged = { visible in
            DispatchQueue.main.async {
                self.isVisible = visible
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class VisibilityView: NSView {
        var onVisibilityChanged: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()

            if let window = window {
                observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    self?.notify()
                })
                observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
                    self?.notify()
                })
                observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
                    self?.notify()
                })
                observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    self?.notify()
                })
            }
            notify()
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
        }

        private func notify() {
            guard let window = window else {
                onVisibilityChanged?(false)
                return
            }
            let visible = window.isVisible && window.occlusionState.contains(.visible)
            onVisibilityChanged?(visible)
        }
    }
}

// MARK: - 滚轮捕获
struct ScrollWheelCaptureView: NSViewRepresentable {
    let onScroll: (NSEvent) -> Void

    func makeNSView(context: Context) -> ScrollWheelView {
        let view = ScrollWheelView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollWheelView: NSView {
        var onScroll: ((NSEvent) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            onScroll?(event)
        }

        override func mouseDown(with event: NSEvent) {
            nextResponder?.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            nextResponder?.mouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            nextResponder?.mouseUp(with: event)
        }
    }
}

enum WidgetKind: String, Identifiable, CaseIterable {
    case clock
    case weather
    case battery
    case cpu
    case network
    case memory
    case disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: return "时钟"
        case .weather: return "天气"
        case .battery: return "电量"
        case .cpu: return "CPU"
        case .network: return "网速"
        case .memory: return "内存"
        case .disk: return "磁盘"
        }
    }
}

// MARK: - 组件层
struct WidgetLayerView: View {
    @Bindable var group: DockGroup
    // 放在组件层内部，避免每秒刷新组件数据时导致整个 DockContainerView 也被迫重绘，
    // 从而在主线程 autoreleasepool drain 时产生大量释放压力（远程连接场景更容易卡死）。
    @StateObject private var data = WidgetDataController()
    @Binding var isWindowVisible: Bool
    @Binding var selectedWidget: WidgetKind?
    @Binding var settingsWidget: WidgetKind?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard group.widgetEditEnabled else { return }
                    selectedWidget = nil
                }

            if group.clockEnabled {
                DraggableWidget(
                    offsetX: $group.clockOffsetX,
                    offsetY: $group.clockOffsetY,
                    isEditing: group.widgetEditEnabled,
                    isSelected: selectedWidget == .clock,
                    onEnd: saveContext,
                    onScroll: handleClockScroll,
                    onSelect: { selectedWidget = .clock },
                    onOpenSettings: {
                        selectedWidget = .clock
                        settingsWidget = .clock
                    }
                ) {
                    ClockWidgetContentView(
                        date: data.now,
                        format: group.clockFormat,
                        showDate: group.clockShowDate,
                        showSeconds: group.clockShowSeconds,
                        fontSize: group.clockFontSize,
                        color: Color(hex: group.clockColorHex),
                        opacity: group.clockOpacity
                    )
                }
            }

            if group.weatherEnabled {
                DraggableWidget(
                    offsetX: $group.weatherOffsetX,
                    offsetY: $group.weatherOffsetY,
                    isEditing: group.widgetEditEnabled,
                    isSelected: selectedWidget == .weather,
                    onEnd: saveContext,
                    onScroll: handleWeatherScroll,
                    onSelect: { selectedWidget = .weather },
                    onOpenSettings: {
                        selectedWidget = .weather
                        settingsWidget = .weather
                    }
                ) {
                    WidgetBadgeView(
                        icon: "cloud.sun.fill",
                        title: data.weatherLocation,
                        value: data.weatherDesc.isEmpty
                            ? data.weatherTemp
                            : "\(data.weatherTemp) \(data.weatherDesc)",
                        fontSize: group.weatherFontSize,
                        color: Color(hex: group.weatherColorHex),
                        opacity: group.weatherOpacity,
                        maskOpacity: group.weatherMaskOpacity
                    )
                }
            }

            if group.batteryEnabled {
                DraggableWidget(
                    offsetX: $group.batteryOffsetX,
                    offsetY: $group.batteryOffsetY,
                    isEditing: group.widgetEditEnabled,
                    isSelected: selectedWidget == .battery,
                    onEnd: saveContext,
                    onScroll: handleBatteryScroll,
                    onSelect: { selectedWidget = .battery },
                    onOpenSettings: {
                        selectedWidget = .battery
                        settingsWidget = .battery
                    }
                ) {
                    WidgetBadgeView(
                        icon: data.batteryIsCharging ? "battery.100.bolt" : "battery.100",
                        title: "电量",
                        value: data.batteryAvailable ? "\(data.batteryPercent)%" : "无电池",
                        fontSize: group.batteryFontSize,
                        color: Color(hex: group.batteryColorHex),
                        opacity: group.batteryOpacity,
                        maskOpacity: group.batteryMaskOpacity
                    )
                }
            }

            if group.cpuEnabled {
                DraggableWidget(
                    offsetX: $group.cpuOffsetX,
                    offsetY: $group.cpuOffsetY,
                    isEditing: group.widgetEditEnabled,
                    isSelected: selectedWidget == .cpu,
                    onEnd: saveContext,
                    onScroll: handleCpuScroll,
                    onSelect: { selectedWidget = .cpu },
                    onOpenSettings: {
                        selectedWidget = .cpu
                        settingsWidget = .cpu
                    }
                ) {
                    WidgetBadgeView(
                        icon: "cpu",
                        title: "CPU",
                        value: String(format: "%.0f%%", data.cpuUsage),
                        fontSize: group.cpuFontSize,
                        color: Color(hex: group.cpuColorHex),
                        opacity: group.cpuOpacity,
                        maskOpacity: group.cpuMaskOpacity
                    )
                }
            }

            if group.networkEnabled {
                DraggableWidget(
                    offsetX: $group.networkOffsetX,
                    offsetY: $group.networkOffsetY,
                    isEditing: group.widgetEditEnabled,
                    isSelected: selectedWidget == .network,
                    onEnd: saveContext,
                    onScroll: handleNetworkScroll,
                    onSelect: { selectedWidget = .network },
                    onOpenSettings: {
                        selectedWidget = .network
                        settingsWidget = .network
                    }
                ) {
                    WidgetBadgeView(
                        icon: "arrow.up.arrow.down",
                        title: "网速",
                        value: "\(formatSpeed(data.networkUp)) ↑  \(formatSpeed(data.networkDown)) ↓",
                        fontSize: group.networkFontSize,
                        color: Color(hex: group.networkColorHex),
                        opacity: group.networkOpacity,
                        maskOpacity: group.networkMaskOpacity
                    )
                }
            }

            if group.memoryEnabled {
                DraggableWidget(
                    offsetX: $group.memoryOffsetX,
                    offsetY: $group.memoryOffsetY,
                    isEditing: group.widgetEditEnabled,
                    isSelected: selectedWidget == .memory,
                    onEnd: saveContext,
                    onScroll: handleMemoryScroll,
                    onSelect: { selectedWidget = .memory },
                    onOpenSettings: {
                        selectedWidget = .memory
                        settingsWidget = .memory
                    }
                ) {
                    WidgetBadgeView(
                        icon: "memorychip",
                        title: "内存",
                        value: memoryValueText,
                        fontSize: group.memoryFontSize,
                        color: Color(hex: group.memoryColorHex),
                        opacity: group.memoryOpacity,
                        maskOpacity: group.memoryMaskOpacity
                    )
                }
            }

            if group.diskEnabled {
                DraggableWidget(
                    offsetX: $group.diskOffsetX,
                    offsetY: $group.diskOffsetY,
                    isEditing: group.widgetEditEnabled,
                    isSelected: selectedWidget == .disk,
                    onEnd: saveContext,
                    onScroll: handleDiskScroll,
                    onSelect: { selectedWidget = .disk },
                    onOpenSettings: {
                        selectedWidget = .disk
                        settingsWidget = .disk
                    }
                ) {
                    WidgetBadgeView(
                        icon: "internaldrive",
                        title: "磁盘",
                        value: diskValueText,
                        fontSize: group.diskFontSize,
                        color: Color(hex: group.diskColorHex),
                        opacity: group.diskOpacity,
                        maskOpacity: group.diskMaskOpacity
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            applyConfig()
        }
        .onChange(of: isWindowVisible) { _ in
            applyConfig()
        }
        .onChange(of: group.clockEnabled) { _ in
            applyConfig()
        }
        .onChange(of: group.clockShowSeconds) { _ in
            applyConfig()
        }
        .onChange(of: group.weatherEnabled) { _ in
            applyConfig()
        }
        .onChange(of: group.weatherLocationQuery) { _ in
            applyConfig()
        }
        .onChange(of: group.weatherUnitRaw) { _ in
            applyConfig()
        }
        .onChange(of: group.batteryEnabled) { _ in
            applyConfig()
        }
        .onChange(of: group.cpuEnabled) { _ in
            applyConfig()
        }
        .onChange(of: group.networkEnabled) { _ in
            applyConfig()
        }
        .onChange(of: group.memoryEnabled) { _ in
            applyConfig()
        }
        .onChange(of: group.diskEnabled) { _ in
            applyConfig()
        }
    }

    private func applyConfig() {
        let anyEnabled = group.clockEnabled
            || group.weatherEnabled
            || group.batteryEnabled
            || group.cpuEnabled
            || group.networkEnabled
            || group.memoryEnabled
            || group.diskEnabled
        let active = isWindowVisible && anyEnabled
        data.updateConfig(
            clockEnabled: group.clockEnabled,
            showSeconds: group.clockShowSeconds,
            weatherEnabled: group.weatherEnabled,
            weatherQuery: group.weatherLocationQuery,
            weatherUnit: group.weatherUnit,
            batteryEnabled: group.batteryEnabled,
            cpuEnabled: group.cpuEnabled,
            networkEnabled: group.networkEnabled,
            memoryEnabled: group.memoryEnabled,
            diskEnabled: group.diskEnabled
        )
        data.setActive(active)
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / (1024 * 1024))
        }
        if bytesPerSecond >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private var memoryValueText: String {
        let total = data.memoryTotalBytes
        guard total > 0 else { return "--" }
        let used = min(data.memoryUsedBytes, total)
        let percent = Int((Double(used) / Double(total) * 100.0).rounded())
        return "\(percent)% · \(formatBytes(used))/\(formatBytes(total))"
    }

    private var diskValueText: String {
        let total = data.diskTotalBytes
        guard total > 0 else { return "--" }
        let free = min(data.diskFreeBytes, total)
        let freePercent = Int((Double(free) / Double(total) * 100.0).rounded())
        return "剩余 \(formatBytes(free)) · \(freePercent)%"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let capped = min(bytes, UInt64(Int64.max))
        return Self.byteFormatter.string(fromByteCount: Int64(capped))
    }

    private func saveContext() {
        try? modelContext.save()
    }

    private func handleClockScroll(_ event: NSEvent) {
        let delta = event.scrollingDeltaY
        let step = event.hasPreciseScrollingDeltas ? 0.2 : 1.5
        let next = group.clockFontSize + Double(-delta) * step
        group.clockFontSize = min(max(next, 12), 120)
        saveContext()
    }

    private func handleWeatherScroll(_ event: NSEvent) {
        updateWidgetFontSize(\.weatherFontSize, event: event)
    }

    private func handleBatteryScroll(_ event: NSEvent) {
        updateWidgetFontSize(\.batteryFontSize, event: event)
    }

    private func handleCpuScroll(_ event: NSEvent) {
        updateWidgetFontSize(\.cpuFontSize, event: event)
    }

    private func handleNetworkScroll(_ event: NSEvent) {
        updateWidgetFontSize(\.networkFontSize, event: event)
    }

    private func handleMemoryScroll(_ event: NSEvent) {
        updateWidgetFontSize(\.memoryFontSize, event: event)
    }

    private func handleDiskScroll(_ event: NSEvent) {
        updateWidgetFontSize(\.diskFontSize, event: event)
    }

    private func updateWidgetFontSize(_ keyPath: ReferenceWritableKeyPath<DockGroup, Double>, event: NSEvent) {
        let delta = event.scrollingDeltaY
        let step = event.hasPreciseScrollingDeltas ? 0.2 : 1.0
        let current = group[keyPath: keyPath]
        let base = current <= 0 ? max(10, min(group.widgetFontSize, 36)) : current
        let next = base + Double(-delta) * step
        group[keyPath: keyPath] = min(max(next, 10), 36)
        saveContext()
    }
}

// MARK: - 可拖拽组件
struct DraggableWidget<Content: View>: View {
    @Binding var offsetX: Double
    @Binding var offsetY: Double
    let isEditing: Bool
    let isSelected: Bool
    let onEnd: () -> Void
    let onScroll: ((NSEvent) -> Void)?
    let onSelect: () -> Void
    let onOpenSettings: () -> Void
    let content: () -> Content

    @State private var startOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var scrollMonitor: Any?
    @State private var isHovering = false

    var body: some View {
        Group {
            // 编辑模式：必须先选中，再允许拖动/缩放，避免多组件场景误操作
            if isEditing, isSelected {
                contentView
                    .highPriorityGesture(dragGesture, including: .all)
            } else {
                contentView
            }
        }
    }

    private var contentView: some View {
        content()
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isEditing ? (isSelected ? Color.white : Color.white.opacity(0.6)) : Color.clear, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
            .offset(x: offsetX, y: offsetY)
            .zIndex(isSelected ? 1 : 0)
            .allowsHitTesting(isEditing)
            .onTapGesture {
                guard isEditing else { return }
                onSelect()
            }
            .contextMenu {
                if isEditing {
                    Button("设置...") {
                        onOpenSettings()
                    }
                }
            }
            .onHover { hovering in
                isHovering = hovering
                updateScrollMonitor()
            }
            .onAppear {
                updateScrollMonitor()
            }
            .onDisappear {
                stopScrollMonitor()
            }
            .onChange(of: isEditing) { _ in
                updateScrollMonitor()
            }
            .onChange(of: isSelected) { _ in
                updateScrollMonitor()
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if !isDragging {
                    startOffset = CGSize(width: offsetX, height: offsetY)
                    isDragging = true
                }
                offsetX = startOffset.width + value.translation.width
                offsetY = startOffset.height + value.translation.height
            }
            .onEnded { _ in
                isDragging = false
                onEnd()
            }
    }

    private func updateScrollMonitor() {
        guard isEditing, isSelected, isHovering, onScroll != nil else {
            stopScrollMonitor()
            return
        }
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            onScroll?(event)
            return nil
        }
    }

    private func stopScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}

// MARK: - 时钟内容视图
struct ClockWidgetContentView: View {
    let date: Date
    let format: ClockFormat
    let showDate: Bool
    let showSeconds: Bool
    let fontSize: Double
    let color: Color
    let opacity: Double

    var body: some View {
        VStack(spacing: 2) {
            Text(timeString(from: date))
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(color.opacity(opacity))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)

            if showDate {
                Text(dateString(from: date))
                    .font(.system(size: max(10, fontSize * 0.35), weight: .medium))
                    .foregroundStyle(color.opacity(opacity * 0.9))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            }
        }
    }

    private func timeString(from date: Date) -> String {
        let formatter: DateFormatter
        switch (format, showSeconds) {
        case (.h24, false):
            formatter = ClockWidgetContentView.timeFormatter24
        case (.h24, true):
            formatter = ClockWidgetContentView.timeFormatter24WithSeconds
        case (.h12, false):
            formatter = ClockWidgetContentView.timeFormatter12
        case (.h12, true):
            formatter = ClockWidgetContentView.timeFormatter12WithSeconds
        }
        return formatter.string(from: date)
    }

    private func dateString(from date: Date) -> String {
        ClockWidgetContentView.dateFormatter.string(from: date)
    }

    private static let timeFormatter24: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let timeFormatter24WithSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let timeFormatter12: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm a"
        return formatter
    }()

    private static let timeFormatter12WithSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm:ss a"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

struct WidgetSettingsSheet: View {
    @Bindable var group: DockGroup
    let kind: WidgetKind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var isFetchingWeatherLocation = false
    @State private var weatherLocationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(kind.title)设置")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("组件层级（全局）")
                    .foregroundStyle(.secondary)
                HStack {
                    Text("层级")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $group.widgetLayerRaw) {
                        ForEach(WidgetLayer.allCases, id: \.self) { layer in
                            Text(layer.title).tag(layer.rawValue)
                        }
                    }
                    .frame(width: 150)
                }
            }

            Group {
                switch kind {
                case .clock:
                    clockSettings
                case .weather:
                    weatherSettings
                case .battery:
                    batterySettings
                case .cpu:
                    cpuSettings
                case .network:
                    networkSettings
                case .memory:
                    memorySettings
                case .disk:
                    diskSettings
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 360, height: 620)
        .onDisappear {
            saveContext()
        }
        .onChange(of: group.weatherLocationQuery) { _ in
            weatherLocationError = nil
        }
    }

    private var colorOptions: [String] {
        ["FFFFFF", "000000"] + ThemeColor.allCases.map { $0.rawValue }
    }

    private var clockSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("时间格式")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $group.clockFormatRaw) {
                    ForEach(ClockFormat.allCases, id: \.self) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
                .frame(width: 150)
            }

            Toggle("显示日期", isOn: $group.clockShowDate)
            Toggle("显示秒", isOn: $group.clockShowSeconds)

            HStack {
                Text("字号")
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Slider(value: $group.clockFontSize, in: 16...96, step: 1)
                        .frame(width: 150)
                    Text("\(Int(group.clockFontSize)) px")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Text("不透明度")
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Slider(value: $group.clockOpacity, in: 0.2...1.0, step: 0.05)
                        .frame(width: 150)
                    Text("\(Int(group.clockOpacity * 100)) %")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("时钟颜色")
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                    ForEach(colorOptions, id: \.self) { hex in
                        Button {
                            group.clockColorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.primary, lineWidth: group.clockColorHex == hex ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("重置位置") {
                    group.clockOffsetX = 0
                    group.clockOffsetY = 0
                    saveContext()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var weatherSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("城市（如：上海/Beijing）", text: $group.weatherLocationQuery)
                    .textFieldStyle(.roundedBorder)

                Button {
                    fetchWeatherLocationFromSystem()
                } label: {
                    Label(isFetchingWeatherLocation ? "获取中" : "使用定位", systemImage: "location")
                }
                .buttonStyle(.bordered)
                .disabled(isFetchingWeatherLocation)
            }

            if let weatherLocationError, !weatherLocationError.isEmpty {
                Text(weatherLocationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Text("温度单位")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $group.weatherUnitRaw) {
                    ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                        Text(unit.title).tag(unit.rawValue)
                    }
                }
                .frame(width: 150)
            }

            badgeStyleSection(
                fontSize: $group.weatherFontSize,
                opacity: $group.weatherOpacity,
                maskOpacity: $group.weatherMaskOpacity,
                colorHex: $group.weatherColorHex
            )

            HStack {
                Spacer()
                Button("重置位置") {
                    group.weatherOffsetX = 0
                    group.weatherOffsetY = 0
                    saveContext()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var batterySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            badgeStyleSection(
                fontSize: $group.batteryFontSize,
                opacity: $group.batteryOpacity,
                maskOpacity: $group.batteryMaskOpacity,
                colorHex: $group.batteryColorHex
            )

            HStack {
                Spacer()
                Button("重置位置") {
                    group.batteryOffsetX = 0
                    group.batteryOffsetY = 0
                    saveContext()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var cpuSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            badgeStyleSection(
                fontSize: $group.cpuFontSize,
                opacity: $group.cpuOpacity,
                maskOpacity: $group.cpuMaskOpacity,
                colorHex: $group.cpuColorHex
            )

            HStack {
                Spacer()
                Button("重置位置") {
                    group.cpuOffsetX = 0
                    group.cpuOffsetY = 0
                    saveContext()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var networkSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            badgeStyleSection(
                fontSize: $group.networkFontSize,
                opacity: $group.networkOpacity,
                maskOpacity: $group.networkMaskOpacity,
                colorHex: $group.networkColorHex
            )

            HStack {
                Spacer()
                Button("重置位置") {
                    group.networkOffsetX = 0
                    group.networkOffsetY = 0
                    saveContext()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var memorySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            badgeStyleSection(
                fontSize: $group.memoryFontSize,
                opacity: $group.memoryOpacity,
                maskOpacity: $group.memoryMaskOpacity,
                colorHex: $group.memoryColorHex
            )

            HStack {
                Spacer()
                Button("重置位置") {
                    group.memoryOffsetX = 0
                    group.memoryOffsetY = 0
                    saveContext()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var diskSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            badgeStyleSection(
                fontSize: $group.diskFontSize,
                opacity: $group.diskOpacity,
                maskOpacity: $group.diskMaskOpacity,
                colorHex: $group.diskColorHex
            )

            HStack {
                Spacer()
                Button("重置位置") {
                    group.diskOffsetX = 0
                    group.diskOffsetY = 0
                    saveContext()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func badgeStyleSection(
        fontSize: Binding<Double>,
        opacity: Binding<Double>,
        maskOpacity: Binding<Double>,
        colorHex: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("字号")
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Slider(value: fontSize, in: 10...36, step: 1)
                        .frame(width: 150)
                    Text("\(Int(fontSize.wrappedValue)) px")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Text("不透明度")
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Slider(value: opacity, in: 0.2...1.0, step: 0.05)
                        .frame(width: 150)
                    Text("\(Int(opacity.wrappedValue * 100)) %")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Text("蒙版透明度")
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Slider(value: maskOpacity, in: 0.0...0.8, step: 0.05)
                        .frame(width: 150)
                    Text("\(Int(maskOpacity.wrappedValue * 100)) %")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("组件颜色")
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 12) {
                    ForEach(colorOptions, id: \.self) { hex in
                        Button {
                            colorHex.wrappedValue = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.primary, lineWidth: colorHex.wrappedValue == hex ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func saveContext() {
        try? modelContext.save()
    }

    private func fetchWeatherLocationFromSystem() {
        weatherLocationError = nil
        isFetchingWeatherLocation = true

        Task { @MainActor in
            defer { isFetchingWeatherLocation = false }
            do {
                let city = try await LocationService.shared.requestCurrentCityName()
                group.weatherLocationQuery = city
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                weatherLocationError = message
            }
        }
    }
}

// MARK: - 组件气泡
struct WidgetBadgeView: View {
    let icon: String
    let title: String
    let value: String
    let fontSize: Double
    let color: Color
    let opacity: Double
    let maskOpacity: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: fontSize * 0.9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: max(9, fontSize * 0.7), weight: .medium))
                    .opacity(0.85)
                Text(value)
                    .font(.system(size: fontSize, weight: .semibold))
            }
        }
        .foregroundStyle(color.opacity(opacity))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(maskOpacity))
        )
    }
}

struct FolderStackView: View {
    let folderURL: URL
    let themeColor: Color
    let textColor: Color
    @Environment(\.dismiss) private var dismiss

    @State private var files: [URL] = []
    @State private var hoveringItem: URL?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(nsImage: IconStore.shared.icon(for: folderURL.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(folderURL.lastPathComponent)
                    .font(.headline)
                    .foregroundStyle(textColor)
                Spacer()
                Button {
                    NSWorkspace.shared.open(folderURL)
                    dismiss()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("在 Finder 中打开")
            }
            .padding(12)
            .background(.regularMaterial)

            Divider()

            // Grid Content
            ScrollView {
                if files.isEmpty {
                    Text("文件夹为空")
                        .foregroundStyle(textColor.opacity(0.7))
                        .padding(20)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60, maximum: 80), spacing: 12)], spacing: 16) {
                        ForEach(files, id: \.self) { file in
                            StackItemView(fileURL: file, themeColor: themeColor, textColor: textColor, isHovering: hoveringItem == file)
                                .onHover { isHovering in
                                    hoveringItem = isHovering ? file : nil
                                }
                                .onTapGesture {
                                    NSWorkspace.shared.open(file)
                                    dismiss()
                                }
                        }
                    }
                    .padding(16)
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 320)
        .background(Color.clear)
        .onAppear {
            loadFiles()
        }
    }

    private func loadFiles() {
        do {
            let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            let fileURLs = try SecurityScopedBookmark.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: resourceKeys)

            // Filter out hidden files
            self.files = fileURLs
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            DebugLog.log("文件夹读取失败: path=\(folderURL.path) error=\(error.localizedDescription)")
        }
    }
}

struct StackItemView: View {
    let fileURL: URL
    let themeColor: Color
    let textColor: Color
    let isHovering: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: IconStore.shared.icon(for: fileURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(isHovering ? 0.2 : 0), radius: 4, y: 2)

            Text(fileURL.lastPathComponent)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(textColor.opacity(0.9))
                .frame(height: 26, alignment: .top)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? themeColor.opacity(0.15) : Color.clear)
        )
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .animation(.spring(duration: 0.2), value: isHovering)
    }
}
