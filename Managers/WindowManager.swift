import SwiftUI
import SwiftData
import AppKit

@MainActor
class WindowManager: ObservableObject {
    private var modelContext: ModelContext?
    private var windows: [UUID: FloatingPanel] = [:]
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 0.4
    private let wallpaperManager = WallpaperManager()
    private let wallpaperPreferenceKey = "NijiDockDesktopWallpaperConfigV2"
    private let legacyWallpaperPreferenceKey = "NijiDockDesktopWallpaperConfig"
    private let stayOnDesktopMigrationKey = "NijiDockStayOnDesktopDefaultEnabledV1"
    private var sleepObservers: [NSObjectProtocol] = []
    private var pendingResumeWorkItem: DispatchWorkItem?
    private var isSuspended = false
    private var createGeneration = 0
    private var teardownGeneration = 0
    private var attachGeneration = 0
    private let hostingViewIdentifier = NSUserInterfaceItemIdentifier("DockHostingView")
    private var wasVisibleBeforeSleep: Set<UUID> = []
    private var pendingVideoResumeWorkItem: DispatchWorkItem?
    private var pendingTransitionResumeWorkItem: DispatchWorkItem?
    private var didHideForSleep = false
    // 常驻桌面：使用桌面图标层级，让窗口在“点击桌面显示桌面项目/Stage Manager”等场景下不被系统收起
    private let desktopPinnedLevel = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    private let normalDockLevel: NSWindow.Level = .normal

    init() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        sleepObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.suspendForSleep()
        })
        sleepObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleResumeAfterWake()
        })
        sleepObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSessionDidBecomeActive()
        })
        sleepObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSessionDidResignActive()
        })

        sleepObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayChange()
        })
    }

    deinit {
        sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        sleepObservers.removeAll()
        pendingResumeWorkItem?.cancel()
        pendingVideoResumeWorkItem?.cancel()
        pendingTransitionResumeWorkItem?.cancel()
    }

    func setContext(_ context: ModelContext) {
        self.modelContext = context
        loadInitialDocks()
    }

    private func suspendForSleep() {
        guard !isSuspended else { return }
        isSuspended = true
        DebugLog.log("willSleep: windows=\(windows.count)")
        pendingResumeWorkItem?.cancel()
        pendingVideoResumeWorkItem?.cancel()
        pendingTransitionResumeWorkItem?.cancel()
        saveWorkItem?.cancel()
        VideoPlaybackControl.shared.pauseForSystem()
        createGeneration += 1
        attachGeneration += 1
        didHideForSleep = false
    }

    private func scheduleResumeAfterWake() {
        guard isSuspended else { return }
        DebugLog.log("didWake: schedule resume")
        pendingResumeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.resumeAfterWake()
        }
        pendingResumeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func resumeAfterWake() {
        guard isSuspended else { return }
        isSuspended = false
        guard modelContext != nil else { return }
        DebugLog.log("resumeAfterWake: windows=\(windows.count) didHideForSleep=\(didHideForSleep)")
        if windows.isEmpty {
            loadDocksAfterWake()
        } else if didHideForSleep {
            restoreWindowsAfterWake()
        }
        scheduleVideoPlaybackResume()
    }

    private func handleSessionDidBecomeActive() {
        DebugLog.log("sessionDidBecomeActive")
        scheduleResumeAfterWake()
        scheduleTransitionPlaybackResume()
    }

    private func handleSessionDidResignActive() {
        DebugLog.log("sessionDidResignActive")
        VideoPlaybackControl.shared.pauseForSystem()
    }

    private func handleDisplayChange() {
        DebugLog.log("displayChange")
        VideoPlaybackControl.shared.pauseForSystem()
        scheduleTransitionPlaybackResume()
    }

    private func loadInitialDocks(staggered: Bool = false, restoreWallpaper: Bool = true) {
        do {
            let groups = try fetchDockGroups()

            if staggered {
                createGeneration += 1
                createWindowsStaggered(groups: groups, generation: createGeneration)
            } else {
                for group in groups where windows[group.id] == nil {
                    autoreleasepool {
                        createWindow(for: group)
                    }
                }
            }

            if restoreWallpaper {
                restoreWallpaperIfNeeded()
            }
            // 保存迁移更改
            try? modelContext?.save()
        } catch {
            print("Failed to load docks: \(error)")
        }
    }

    private func loadDocksAfterWake() {
        do {
            let groups = try fetchDockGroups()
            createGeneration += 1
            createWindowShellsStaggered(groups: groups, generation: createGeneration)
            attachGeneration += 1
            attachContentStaggered(groups: groups, generation: attachGeneration)
            restoreWallpaperIfNeeded()
            try? modelContext?.save()
        } catch {
            print("Failed to load docks after wake: \(error)")
        }
    }

    private func scheduleVideoPlaybackResume() {
        pendingVideoResumeWorkItem?.cancel()
        let item = DispatchWorkItem {
            DebugLog.log("resume playback after wake")
            VideoPlaybackControl.shared.resumeForSystem()
        }
        pendingVideoResumeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
    }

    private func scheduleTransitionPlaybackResume() {
        pendingTransitionResumeWorkItem?.cancel()
        let item = DispatchWorkItem {
            DebugLog.log("resume playback after transition")
            VideoPlaybackControl.shared.resumeForSystem()
        }
        pendingTransitionResumeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: item)
    }

    private func restoreWindowsAfterWake() {
        for (groupId, panel) in windows {
            if let group = findGroup(by: groupId) {
                panel.updateAppearance(backgroundOpacity: group.opacity, material: group.blurStyle.material)
                panel.setAspectRatio(group.aspectRatioLock.ratio)
                if wasVisibleBeforeSleep.contains(groupId), group.isVisible {
                    panel.makeKeyAndOrderFront(nil)
                } else {
                    panel.orderOut(nil)
                }
            } else {
                panel.orderOut(nil)
            }
        }
        wasVisibleBeforeSleep.removeAll()
    }

    private func fetchDockGroups() throws -> [DockGroup] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<DockGroup>()
        let groups = try context.fetch(descriptor)
        // 一次性迁移：将“常驻桌面”默认改为开启后，旧用户数据可能仍为关闭。
        // 这里仅在首次升级时统一打开一次，之后用户手动关闭的不会被覆盖。
        let shouldApplyStayOnDesktopDefault = !UserDefaults.standard.bool(forKey: stayOnDesktopMigrationKey)
        if shouldApplyStayOnDesktopDefault {
            for group in groups {
                group.stayOnDesktopEnabled = true
            }
            UserDefaults.standard.set(true, forKey: stayOnDesktopMigrationKey)
        }
        for group in groups {
            // 数据迁移/修复：如果旧数据没有分类，自动添加默认分类
            if group.categories.isEmpty {
                let categories = [
                    DockCategory(name: "Apps", sortIndex: 0),
                    DockCategory(name: "Files", sortIndex: 1, isDefault: true),
                    DockCategory(name: "Web", sortIndex: 2)
                ]
                group.categories = categories
                // 尝试将现有未分类的项目归类
                for item in group.items where item.category == nil {
                    if let target = categories.first(where: { cat in
                        (cat.name == "Apps" && item.type == .app) ||
                        (cat.name == "Files" && (item.type == .file || item.type == .folder)) ||
                        (cat.name == "Web" && item.type == .url)
                    }) {
                        item.category = target
                    }
                }
            }
            normalizeSkinPathIfNeeded(for: group)
            normalizeIconScaleDefaultsIfNeeded(for: group)
        }
        return groups
    }

    private func normalizeSkinPathIfNeeded(for group: DockGroup) {
        guard let path = group.skinPath, !path.isEmpty else { return }
        if path.hasPrefix("builtin://") {
            group.skinBookmarkData = nil
            return
        }

        if let resolved = SecurityScopedBookmark.resolveFileURL(pathOrURLString: path, bookmarkData: group.skinBookmarkData) {
            if let refreshed = resolved.refreshedBookmarkData {
                group.skinBookmarkData = refreshed
            } else if group.skinBookmarkData == nil {
                group.skinBookmarkData = SecurityScopedBookmark.createBookmarkData(for: resolved.url)
            }

            group.skinPath = resolved.url.path
            if SecurityScopedBookmark.fileExists(at: resolved.url) {
                let bundlePath = Bundle.main.bundlePath
                if resolved.url.path.hasPrefix(bundlePath) {
                    let filename = resolved.url.lastPathComponent
                    group.skinPath = BuiltInSkinCatalog.builtinPath(for: filename)
                    group.skinBookmarkData = nil
                }
                return
            }
        }

        if let resolved = BuiltInSkinCatalog.resolveURL(from: path) {
            let filename = resolved.lastPathComponent
            group.skinPath = BuiltInSkinCatalog.builtinPath(for: filename)
            group.skinBookmarkData = nil
        }
    }

    private func normalizeIconScaleDefaultsIfNeeded(for group: DockGroup) {
        // 新功能迁移：旧数据没有基准尺寸时，默认开启“窗口缩放时图标等比缩放”
        // 这样可以避免用户把窗口缩小后图标被裁切，也能满足“缩放窗口=图标跟随缩放”的直觉预期。
        guard group.iconScaleBaseWidth <= 0 || group.iconScaleBaseHeight <= 0 else { return }

        let rect = NSRectFromString(group.frameString)
        let fallback = NSSize(width: 320, height: 400)
        let width = rect.width > 0 ? rect.width : fallback.width
        let height = rect.height > 0 ? rect.height : fallback.height

        group.iconScaleWithWindowEnabled = true
        group.iconScaleBaseWidth = Double(width)
        group.iconScaleBaseHeight = Double(height)
    }

    private func teardownWindowsStaggered(panels: [FloatingPanel], generation: Int, index: Int = 0) {
        guard generation == teardownGeneration else { return }
        guard index < panels.count else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            autoreleasepool {
                let panel = panels[index]
                panel.animationBehavior = .none
                panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
                panel.orderOut(nil)
                panel.close()
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.teardownWindowsStaggered(panels: panels, generation: generation, index: index + 1)
        }
    }

    private func createWindowsStaggered(groups: [DockGroup], generation: Int, index: Int = 0) {
        guard generation == createGeneration else { return }
        guard index < groups.count else { return }
        let group = groups[index]
        if windows[group.id] == nil {
            autoreleasepool {
                createWindow(for: group)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.createWindowsStaggered(groups: groups, generation: generation, index: index + 1)
        }
    }

    private func createWindowShellsStaggered(groups: [DockGroup], generation: Int, index: Int = 0) {
        guard generation == createGeneration else { return }
        guard index < groups.count else { return }
        let group = groups[index]
        if windows[group.id] == nil {
            autoreleasepool {
                _ = createWindowShell(for: group)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.createWindowShellsStaggered(groups: groups, generation: generation, index: index + 1)
        }
    }

    private func attachContentStaggered(groups: [DockGroup], generation: Int, index: Int = 0) {
        guard generation == attachGeneration else { return }
        guard index < groups.count else { return }
        let group = groups[index]
        if let panel = windows[group.id] {
            autoreleasepool {
                attachContent(for: group, panel: panel)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.attachContentStaggered(groups: groups, generation: generation, index: index + 1)
        }
    }

    func createNewDock() {
        guard let context = modelContext else { return }
        let newGroup = DockGroup(name: "New Dock")

        // 初始化默认分类
        let categories = [
            DockCategory(name: "Apps", sortIndex: 0),
            DockCategory(name: "Files", sortIndex: 1, isDefault: true),
            DockCategory(name: "Web", sortIndex: 2)
        ]
        newGroup.categories = categories

        context.insert(newGroup)
        createWindow(for: newGroup)
        try? context.save()
    }

    func removeDock(_ group: DockGroup) {
        if let panel = windows[group.id] {
            panel.close()
            windows.removeValue(forKey: group.id)
        }
        modelContext?.delete(group)
        try? modelContext?.save()
    }

    func toggleAllDocksVisibility() {
        let hasVisible = windows.values.contains(where: { $0.isVisible })
        let shouldShow = !hasVisible

        for (groupId, panel) in windows {
            if shouldShow {
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
            if let group = findGroup(by: groupId) {
                group.isVisible = shouldShow
            }
        }
        try? modelContext?.save()
    }

    func updateWindowAppearance(for group: DockGroup) {
        guard let panel = windows[group.id] else { return }
        updateWindowStayOnDesktop(for: group, panel: panel)
        panel.updateAppearance(backgroundOpacity: group.opacity, material: group.blurStyle.material)
    }

    func updateStayOnDesktop(for group: DockGroup) {
        guard let panel = windows[group.id] else { return }
        updateWindowStayOnDesktop(for: group, panel: panel)
    }

    private func updateWindowStayOnDesktop(for group: DockGroup, panel: NSWindow) {
        if group.stayOnDesktopEnabled {
            panel.level = desktopPinnedLevel
            panel.collectionBehavior.insert(.stationary)
        } else {
            panel.level = normalDockLevel
            panel.collectionBehavior.remove(.stationary)
        }
    }

    func updateAspectRatio(for group: DockGroup) {
        guard let panel = windows[group.id] as? FloatingPanel else { return }
        panel.setAspectRatio(group.aspectRatioLock.ratio)
    }

    func setWindowAlpha(for group: DockGroup, alpha: Double) {
        guard let panel = windows[group.id] else { return }
        panel.animator().alphaValue = CGFloat(min(max(alpha, 0.05), 1.0))
    }

    func applyDesktopWallpaper(config: WallpaperConfig, screenId: String) {
        var appliedConfig = config
        if appliedConfig.securityScopedBookmarkData == nil,
           appliedConfig.url.isFileURL,
           !appliedConfig.url.path.hasPrefix(Bundle.main.bundlePath) {
            let bookmarkData = SecurityScopedBookmark.createBookmarkData(for: appliedConfig.url)
            appliedConfig = WallpaperConfig(
                url: appliedConfig.url,
                type: appliedConfig.type,
                contentMode: appliedConfig.contentMode,
                scale: appliedConfig.scale,
                offset: appliedConfig.offset,
                opacity: appliedConfig.opacity,
                isMuted: appliedConfig.isMuted,
                securityScopedBookmarkData: bookmarkData
            )
        }

        wallpaperManager.apply(config: appliedConfig, screenId: screenId)
        saveWallpaperPreferences()
    }

    func clearDesktopWallpaper() {
        wallpaperManager.clearAll()
        UserDefaults.standard.removeObject(forKey: wallpaperPreferenceKey)
        UserDefaults.standard.removeObject(forKey: legacyWallpaperPreferenceKey)
    }

    func clearDesktopWallpaper(for screenId: String) {
        wallpaperManager.clear(screenId: screenId)
        saveWallpaperPreferences()
    }

    func isUsingWallpaper(config: WallpaperConfig, screenId: String) -> Bool {
        wallpaperManager.isUsing(config: config, for: screenId)
    }

    var isDesktopWallpaperActive: Bool {
        wallpaperManager.isActive
    }

    func currentWallpaperConfig(for screenId: String) -> WallpaperConfig? {
        wallpaperManager.currentConfig(for: screenId)
    }

    func updateDesktopWallpaperSound(isMuted: Bool, for screenId: String) {
        wallpaperManager.updateSound(isMuted: isMuted, for: screenId)
        saveWallpaperPreferences()
    }

    private func restoreWallpaperIfNeeded() {
        let data = UserDefaults.standard.data(forKey: wallpaperPreferenceKey)
            ?? UserDefaults.standard.data(forKey: legacyWallpaperPreferenceKey)
        guard let data else {
            clearDesktopWallpaper()
            return
        }

        if let bundle = try? JSONDecoder().decode(WallpaperPreferenceBundle.self, from: data) {
            var configs: [String: WallpaperConfig] = [:]
            for (screenId, pref) in bundle.configs {
                let config = pref.config
                if SecurityScopedBookmark.fileExists(at: config.url) {
                    configs[screenId] = config
                }
            }
            if configs.isEmpty {
                clearDesktopWallpaper()
            } else {
                wallpaperManager.setConfigs(configs)
            }
            return
        }

        if let pref = try? JSONDecoder().decode(WallpaperPreference.self, from: data) {
            let config = pref.config
            if SecurityScopedBookmark.fileExists(at: config.url) {
                var configs: [String: WallpaperConfig] = [:]
                for screen in NSScreen.screens {
                    let screenId = WallpaperManager.screenId(for: screen)
                    configs[screenId] = config
                }
                wallpaperManager.setConfigs(configs)
                saveWallpaperPreferences()
            } else {
                clearDesktopWallpaper()
            }
            return
        }

        if let legacyId = String(data: data, encoding: .utf8),
           let uuid = UUID(uuidString: legacyId),
           let context = modelContext {
            let descriptor = FetchDescriptor<DockGroup>()
            if let groups = try? context.fetch(descriptor),
               let group = groups.first(where: { $0.id == uuid }),
               let url = group.skinURL,
               group.skinType != .none {
               let config = WallpaperConfig(
                    url: url,
                    type: group.skinType,
                    contentMode: group.skinContentMode,
                    scale: group.skinScale,
                    offset: CGSize(width: group.skinOffsetX, height: group.skinOffsetY),
                    opacity: group.skinOpacity,
                    isMuted: true,
                    securityScopedBookmarkData: group.skinBookmarkData
                )
                var configs: [String: WallpaperConfig] = [:]
                for screen in NSScreen.screens {
                    let screenId = WallpaperManager.screenId(for: screen)
                    configs[screenId] = config
                }
                wallpaperManager.setConfigs(configs)
                saveWallpaperPreferences()
                return
            }
        }

        clearDesktopWallpaper()
    }

    private struct WallpaperPreference: Codable {
        let urlPath: String
        let securityScopedBookmarkData: Data?
        let typeRaw: Int
        let contentModeRaw: Int
        let scale: Double
        let offsetX: Double
        let offsetY: Double
        let opacity: Double
        let isMuted: Bool

        init(config: WallpaperConfig) {
            self.urlPath = config.url.path
            self.securityScopedBookmarkData = config.securityScopedBookmarkData
            self.typeRaw = config.type.rawValue
            self.contentModeRaw = config.contentMode.rawValue
            self.scale = config.scale
            self.offsetX = config.offset.width
            self.offsetY = config.offset.height
            self.opacity = config.opacity
            self.isMuted = config.isMuted
        }

        var url: URL {
            URL(fileURLWithPath: urlPath)
        }

        var config: WallpaperConfig {
            let resolved = SecurityScopedBookmark.resolveFileURL(pathOrURLString: urlPath, bookmarkData: securityScopedBookmarkData)
            let resolvedURL = resolved?.url ?? url
            let refreshedData = resolved?.refreshedBookmarkData ?? securityScopedBookmarkData
            return WallpaperConfig(
                url: resolvedURL,
                type: SkinType(rawValue: typeRaw) ?? .image,
                contentMode: SkinContentMode(rawValue: contentModeRaw) ?? .fill,
                scale: scale,
                offset: CGSize(width: offsetX, height: offsetY),
                opacity: opacity,
                isMuted: isMuted,
                securityScopedBookmarkData: refreshedData
            )
        }
    }

    private struct WallpaperPreferenceBundle: Codable {
        let configs: [String: WallpaperPreference]
    }

    private func saveWallpaperPreferences() {
        let configs = wallpaperManager.allConfigs()
        let mapped = configs.mapValues { config in
            let resolved = SecurityScopedBookmark.resolveFileURL(
                pathOrURLString: config.url.path,
                bookmarkData: config.securityScopedBookmarkData
            )
            let resolvedURL = resolved?.url ?? config.url
            let bookmarkData = resolvedURL.path.hasPrefix(Bundle.main.bundlePath)
                ? nil
                : (resolved?.refreshedBookmarkData
                   ?? config.securityScopedBookmarkData
                   ?? SecurityScopedBookmark.createBookmarkData(for: resolvedURL))
            let normalizedConfig = WallpaperConfig(
                url: resolvedURL,
                type: config.type,
                contentMode: config.contentMode,
                scale: config.scale,
                offset: config.offset,
                opacity: config.opacity,
                isMuted: config.isMuted,
                securityScopedBookmarkData: bookmarkData
            )
            return WallpaperPreference(config: normalizedConfig)
        }
        if mapped.isEmpty {
            UserDefaults.standard.removeObject(forKey: wallpaperPreferenceKey)
            return
        }
        if let data = try? JSONEncoder().encode(WallpaperPreferenceBundle(configs: mapped)) {
            UserDefaults.standard.set(data, forKey: wallpaperPreferenceKey)
        }
    }

    private func createWindow(for group: DockGroup) {
        let panel = createWindowShell(for: group)
        attachContent(for: group, panel: panel)
    }

    @discardableResult
    private func createWindowShell(for group: DockGroup) -> FloatingPanel {
        let frame = NSRectFromString(group.frameString)

        // Ensure frame is valid, else default
        // 默认尺寸调整为 320x400，更接近参考产品
        let validFrame = frame.width > 0 && frame.height > 0 ? frame : NSRect(x: 100, y: 300, width: 320, height: 400)

        let panel = FloatingPanel(
            contentRect: validFrame,
            backing: .buffered,
            defer: false
        )
        updateWindowStayOnDesktop(for: group, panel: panel)
        panel.updateAppearance(backgroundOpacity: group.opacity, material: group.blurStyle.material)
        panel.alphaValue = group.isVisible ? 1.0 : 0.0
        panel.setAspectRatio(group.aspectRatioLock.ratio)

        // Observe window movement to save state
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            self?.handleWindowMove(group: group, panel: panel)
        }

        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            self?.saveWindowState(group: group, panel: panel)
        }

        if group.isVisible {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderOut(nil)
        }
        windows[group.id] = panel
        return panel
    }

    private func attachContent(for group: DockGroup, panel: FloatingPanel) {
        guard let context = modelContext else { return }
        if panel.contentView?.subviews.contains(where: { $0.identifier == hostingViewIdentifier }) == true {
            return
        }
        let rootView = DockContainerView(group: group)
            .environment(\.modelContext, context)
            .environmentObject(self)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.identifier = hostingViewIdentifier
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = panel.contentView?.bounds ?? .zero
        panel.contentView?.addSubview(hostingView)
    }

    private func handleWindowMove(group: DockGroup, panel: NSWindow) {
        snapToEdge(panel: panel)
        saveWindowState(group: group, panel: panel)
    }

    // 屏幕边缘吸附功能
    private func snapToEdge(panel: NSWindow) {
        guard let screen = panel.screen else { return }
        let screenFrame = screen.visibleFrame
        var newFrame = panel.frame
        let threshold: CGFloat = 15.0 // 吸附阈值
        var didSnap = false

        // 吸附到左边缘
        if abs(newFrame.minX - screenFrame.minX) < threshold {
            newFrame.origin.x = screenFrame.minX
            didSnap = true
        }
        // 吸附到右边缘
        else if abs(newFrame.maxX - screenFrame.maxX) < threshold {
            newFrame.origin.x = screenFrame.maxX - newFrame.width
            didSnap = true
        }

        // 吸附到下边缘
        if abs(newFrame.minY - screenFrame.minY) < threshold {
            newFrame.origin.y = screenFrame.minY
            didSnap = true
        }
        // 吸附到上边缘
        else if abs(newFrame.maxY - screenFrame.maxY) < threshold {
            newFrame.origin.y = screenFrame.maxY - newFrame.height
            didSnap = true
        }

        if didSnap && newFrame != panel.frame {
            panel.setFrame(newFrame, display: true)
        }
    }

    private func saveWindowState(group: DockGroup, panel: NSWindow) {
        group.frameString = NSStringFromRect(panel.frame)
        scheduleSave()
    }

    private func persistAllWindowFrames() {
        guard modelContext != nil else { return }
        for (groupId, panel) in windows {
            if let group = findGroup(by: groupId) {
                group.frameString = NSStringFromRect(panel.frame)
                group.isVisible = panel.isVisible
            }
        }
        try? modelContext?.save()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            try? self?.modelContext?.save()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: workItem)
    }

    private func findGroup(by id: UUID) -> DockGroup? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<DockGroup>()
        if let groups = try? context.fetch(descriptor) {
            return groups.first(where: { $0.id == id })
        }
        return nil
    }
}
