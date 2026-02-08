import SwiftUI
import AppKit

@MainActor
final class WallpaperManager: ObservableObject {
    @Published private(set) var isActive = false

    private var configs: [String: WallpaperConfig] = [:]
    private var windows: [String: WallpaperWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pendingRebuildWorkItem: DispatchWorkItem?

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRebuild()
        })

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRebuild()
        })
    }

    deinit {
        pendingRebuildWorkItem?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    static func screenId(for screen: NSScreen) -> String {
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return screenNumber?.stringValue ?? UUID().uuidString
    }

    func apply(config: WallpaperConfig, screenId: String) {
        configs[screenId] = config
        updateActiveState()
        scheduleRebuild(delay: 0.1)
    }

    func setConfigs(_ configs: [String: WallpaperConfig]) {
        self.configs = configs
        updateActiveState()
        scheduleRebuild(delay: 0.1)
    }

    func currentConfig(for screenId: String) -> WallpaperConfig? {
        configs[screenId]
    }

    func allConfigs() -> [String: WallpaperConfig] {
        configs
    }

    func updateSound(isMuted: Bool, for screenId: String) {
        guard let config = configs[screenId] else { return }
        configs[screenId] = WallpaperConfig(
            url: config.url,
            type: config.type,
            contentMode: config.contentMode,
            scale: config.scale,
            offset: config.offset,
            opacity: config.opacity,
            isMuted: isMuted,
            securityScopedBookmarkData: config.securityScopedBookmarkData
        )
        scheduleRebuild(delay: 0.1)
    }

    func clear(screenId: String) {
        configs.removeValue(forKey: screenId)
        updateActiveState()
        scheduleRebuild(delay: 0.1)
    }

    func clearAll() {
        isActive = false
        configs.removeAll()
        scheduleRebuild(delay: 0.1)
    }

    func suspendWindowsForSleep() {
        windows.values.forEach { $0.close() }
        windows.removeAll()
    }

    func isUsing(config: WallpaperConfig, for screenId: String) -> Bool {
        configs[screenId] == config
    }

    private func rebuildWindows() {
        let screens = NSScreen.screens
        var activeIDs: Set<String> = []

        for screen in screens {
            let id = Self.screenId(for: screen)
            activeIDs.insert(id)

            if let config = configs[id] {
                if let window = windows[id] {
                    window.update(screen: screen, config: config)
                } else {
                    windows[id] = WallpaperWindow(screen: screen, config: config)
                }
            } else if let window = windows[id] {
                window.deactivate(screen: screen)
            }
        }

        for (id, window) in windows where !activeIDs.contains(id) {
            window.close()
            windows.removeValue(forKey: id)
        }
    }

    private func scheduleRebuild(delay: TimeInterval = 0.6) {
        pendingRebuildWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.rebuildWindows()
        }
        pendingRebuildWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func updateActiveState() {
        isActive = !configs.isEmpty
    }
}

struct WallpaperConfig: Equatable {
    let url: URL
    let type: SkinType
    let contentMode: SkinContentMode
    let scale: Double
    let offset: CGSize
    let opacity: Double
    let isMuted: Bool
    let securityScopedBookmarkData: Data?
}

private struct WallpaperContentView: View {
    let config: WallpaperConfig
    let playerKey: String
    @ObservedObject private var playbackControl = VideoPlaybackControl.shared

    private var resolvedURL: URL {
        SecurityScopedBookmark.resolveFileURL(
            pathOrURLString: config.url.path,
            bookmarkData: config.securityScopedBookmarkData
        )?.url ?? config.url
    }

    var body: some View {
        SkinBackgroundView(
            url: resolvedURL,
            type: config.type,
            contentMode: config.contentMode,
            scale: config.scale,
            offset: config.offset,
            isMuted: config.isMuted,
            allowVideoPlayback: playbackControl.isVideoPlaybackAllowed,
            systemPlaybackEnabled: playbackControl.isSystemPlaybackEnabled,
            playerKey: playerKey,
            previewURL: VideoPreviewStore.shared.previewURL(for: resolvedURL)
        )
        .opacity(config.opacity)
        .background(Color.black)
        .ignoresSafeArea()
    }
}

private struct EmptyWallpaperContentView: View {
    var body: some View {
        Color.clear
            .background(Color.clear)
            .ignoresSafeArea()
    }
}

final class WallpaperWindow {
    private let window: NSWindow
    private let hostingView: NSHostingView<AnyView>
    private let playerKey: String

    init(screen: NSScreen, config: WallpaperConfig) {
        let rect = screen.frame
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        self.playerKey = "wallpaper-\(screenNumber?.stringValue ?? UUID().uuidString)"
        let window = DesktopWindow(
            contentRect: rect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.animationBehavior = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: AnyView(WallpaperContentView(config: config, playerKey: playerKey)))
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = rect
        window.contentView = hostingView

        self.window = window
        self.hostingView = hostingView

        window.setFrame(rect, display: true)
        window.orderFrontRegardless()
    }

    func update(screen: NSScreen, config: WallpaperConfig) {
        let rect = screen.frame
        window.setFrame(rect, display: true)
        hostingView.rootView = AnyView(WallpaperContentView(config: config, playerKey: playerKey))
        window.orderFrontRegardless()
    }

    func deactivate(screen: NSScreen) {
        let rect = screen.frame
        window.setFrame(rect, display: true)
        hostingView.rootView = AnyView(EmptyWallpaperContentView())
        window.orderOut(nil)
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
