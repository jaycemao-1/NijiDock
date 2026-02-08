import SwiftUI
import SwiftData
import AppKit

@main
struct NijiDockApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            DockGroup.self,
            DockItem.self,
            DockCategory.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @StateObject private var windowManager = WindowManager()
    @State private var isInitialized = false

    init() {
        // 设置为后台应用模式，不在 Dock 栏显示图标
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        // 菜单栏图标
        MenuBarExtra("次元坞", systemImage: "square.stack.3d.up.fill") {
            MenuBarContentView(
                windowManager: windowManager,
                modelContext: sharedModelContainer.mainContext,
                isInitialized: $isInitialized
            )
        }
        .modelContainer(sharedModelContainer)
    }
}

// 单独的菜单内容视图，用于处理初始化
struct MenuBarContentView: View {
    @ObservedObject var windowManager: WindowManager
    let modelContext: ModelContext
    @Binding var isInitialized: Bool
    @ObservedObject private var playbackControl = VideoPlaybackControl.shared
    private var builtInSkins: [BuiltInSkin] {
        BuiltInSkinCatalog.load().filter { $0.isAvailable }
    }

    init(windowManager: WindowManager, modelContext: ModelContext, isInitialized: Binding<Bool>) {
        self.windowManager = windowManager
        self.modelContext = modelContext
        self._isInitialized = isInitialized
        SecurityScopedBookmark.seedAccessContext(modelContext)
    }

    var body: some View {
        VStack {
            Button("新建 Dock") {
                windowManager.createNewDock()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("显示/隐藏 Dock") {
                windowManager.toggleAllDocksVisibility()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Menu("桌面壁纸") {
                Button("设置桌面壁纸...") {
                    WallpaperPickerWindow.shared.show(windowManager: windowManager, skins: builtInSkins)
                }

                Button("清除全部桌面壁纸") {
                    windowManager.clearDesktopWallpaper()
                }
                .disabled(!windowManager.isDesktopWallpaperActive)
            }

            Divider()

            if playbackControl.isVideoPlaybackAllowed {
                Button("暂停视频皮肤播放") {
                    playbackControl.disableVideoPlayback()
                }
            } else {
                Button("恢复视频皮肤播放") {
                    playbackControl.enableVideoPlayback()
                }
            }

            Divider()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .onAppear {
            if !isInitialized {
                windowManager.setContext(modelContext)
                isInitialized = true
            }
            SecurityScopedBookmark.refreshPersistedBookmarksIfNeeded()
        }
    }

    // 目前不需要快捷配置，统一使用壁纸设置面板
}
