import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WallpaperPickerSheet: View {
    @ObservedObject var windowManager: WindowManager
    let skins: [BuiltInSkin]

    @Environment(\.dismiss) private var dismiss
    @State private var screens: [NSScreen] = NSScreen.screens
    @State private var selectedScreenId: String = ""

    var body: some View {
        VStack(spacing: 12) {
            header

            Divider()

            if !screenItems.isEmpty {
                Picker("", selection: $selectedScreenId) {
                    ForEach(screenItems, id: \.id) { item in
                        Text(item.title).tag(item.id)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
            }

            ScrollView {
                BuiltInSkinPickerView(
                    skins: skins,
                    onSelect: { skin in
                        applyBuiltInWallpaper(skin)
                    },
                    showsText: false,
                    showsCategoryTitles: false,
                    selectedFilename: selectedFilename
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { refreshScreens() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshScreens()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("桌面壁纸")
                .font(.headline)
            Spacer()

            Button {
                pickLocalWallpaper()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
            .help("选择本地文件")

            Button {
                toggleSound()
            } label: {
                Image(systemName: isMuted ? "speaker.slash" : "speaker.2")
            }
            .buttonStyle(.bordered)
            .disabled(!hasConfig)
            .help("壁纸声音")

            Button(role: .destructive) {
                windowManager.clearDesktopWallpaper(for: selectedScreenId)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(!hasConfig)
            .help("清除当前屏幕壁纸")

            Button("关闭") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var screenItems: [(id: String, title: String)] {
        screens.enumerated().map { index, screen in
            let id = WallpaperManager.screenId(for: screen)
            let title = "屏幕 \(index + 1)"
            return (id: id, title: title)
        }
    }

    private var selectedFilename: String? {
        windowManager.currentWallpaperConfig(for: selectedScreenId)?.url.lastPathComponent
    }

    private var hasConfig: Bool {
        windowManager.currentWallpaperConfig(for: selectedScreenId) != nil
    }

    private var isMuted: Bool {
        windowManager.currentWallpaperConfig(for: selectedScreenId)?.isMuted ?? true
    }

    private func refreshScreens() {
        screens = NSScreen.screens
        if selectedScreenId.isEmpty, let first = screens.first {
            selectedScreenId = WallpaperManager.screenId(for: first)
        }
        if !screens.contains(where: { WallpaperManager.screenId(for: $0) == selectedScreenId }),
           let first = screens.first {
            selectedScreenId = WallpaperManager.screenId(for: first)
        }
    }

    private func applyBuiltInWallpaper(_ skin: BuiltInSkin) {
        guard let url = skin.fileURL else { return }
        let muted = windowManager.currentWallpaperConfig(for: selectedScreenId)?.isMuted ?? true
        let config = WallpaperConfig(
            url: url,
            type: skin.skinType,
            contentMode: .fill,
            scale: 1.0,
            offset: .zero,
            opacity: 1.0,
            isMuted: muted,
            securityScopedBookmarkData: nil
        )
        windowManager.applyDesktopWallpaper(config: config, screenId: selectedScreenId)
    }

    private func pickLocalWallpaper() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]

        if panel.runModal() == .OK, let url = panel.url {
            let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
            let type: SkinType
            if let contentType = UTType(filenameExtension: fileURL.pathExtension),
               contentType.conforms(to: .movie) {
                type = .video
            } else {
                type = .image
            }
            let muted = windowManager.currentWallpaperConfig(for: selectedScreenId)?.isMuted ?? true
            let config = WallpaperConfig(
                url: fileURL,
                type: type,
                contentMode: .fill,
                scale: 1.0,
                offset: .zero,
                opacity: 1.0,
                isMuted: muted,
                securityScopedBookmarkData: SecurityScopedBookmark.createBookmarkData(for: fileURL)
            )
            windowManager.applyDesktopWallpaper(config: config, screenId: selectedScreenId)
        }
    }

    private func toggleSound() {
        let nextMuted = !isMuted
        windowManager.updateDesktopWallpaperSound(isMuted: nextMuted, for: selectedScreenId)
    }
}
