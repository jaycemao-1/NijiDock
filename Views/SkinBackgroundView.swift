import SwiftUI
import AppKit
import AVFoundation

struct SkinBackgroundView: NSViewRepresentable {
    let url: URL
    let type: SkinType
    let contentMode: SkinContentMode
    let scale: Double
    let offset: CGSize
    let isMuted: Bool
    let allowVideoPlayback: Bool
    let systemPlaybackEnabled: Bool
    let playerKey: String
    let previewURL: URL?

    func makeNSView(context: Context) -> BackgroundMediaView {
        let view = BackgroundMediaView()
        view.update(
            url: url,
            type: type,
            contentMode: contentMode,
            scale: scale,
            offset: offset,
            isMuted: isMuted,
            allowVideoPlayback: allowVideoPlayback,
            systemPlaybackEnabled: systemPlaybackEnabled,
            playerKey: playerKey,
            previewURL: previewURL
        )
        return view
    }

    func updateNSView(_ nsView: BackgroundMediaView, context: Context) {
        nsView.update(
            url: url,
            type: type,
            contentMode: contentMode,
            scale: scale,
            offset: offset,
            isMuted: isMuted,
            allowVideoPlayback: allowVideoPlayback,
            systemPlaybackEnabled: systemPlaybackEnabled,
            playerKey: playerKey,
            previewURL: previewURL
        )
    }
}

final class BackgroundMediaView: NSView {
    private let imageView = NSImageView()
    private var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?
    private var mediaSize: CGSize = .zero
    private var isAnimatedImage = false
    private var currentURL: URL?
    private var currentType: SkinType = .none
    private var contentMode: SkinContentMode = .fill
    private var scale: Double = 1.0
    private var offset: CGSize = .zero
    private var isMuted: Bool = true
    private var isVisibleToUser = true
    private var isSleeping = false
    private var pendingWakeReload = false
    private var pendingWakeWorkItem: DispatchWorkItem?
    private var allowVideoPlayback = true
    private var systemPlaybackEnabled = true
    private var previewURL: URL?
    private var playerKey: String = ""
    private var usesPooledPlayer = false
    private var observers: [NSObjectProtocol] = []
    private var playbackObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var loadGeneration: Int = 0
    private var imageRetryCount: Int = 0
    private var videoRetryCount: Int = 0
    private var securityScopedURL: URL?
    private var isAccessingSecurityScope = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = []
        imageView.animates = false
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = []
        imageView.animates = false
        addSubview(imageView)
    }

    deinit {
        pendingWakeWorkItem?.cancel()
        releaseSecurityScopeAccessIfNeeded()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        playbackObservers.forEach { NotificationCenter.default.removeObserver($0) }
        playbackObservers.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()

        if let window = window {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                self?.updateVisibility()
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.updateVisibility()
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.updateVisibility()
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.updateVisibility()
            })
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        })
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        })

        updateVisibility()
    }

    func update(
        url: URL,
        type: SkinType,
        contentMode: SkinContentMode,
        scale: Double,
        offset: CGSize,
        isMuted: Bool,
        allowVideoPlayback: Bool,
        systemPlaybackEnabled: Bool,
        playerKey: String,
        previewURL: URL?
    ) {
        self.contentMode = contentMode
        self.scale = scale
        self.offset = offset
        self.isMuted = isMuted
        self.allowVideoPlayback = allowVideoPlayback
        self.systemPlaybackEnabled = systemPlaybackEnabled
        if self.playerKey != playerKey, currentType == .video {
            stopPlayback(releasePool: true)
        }
        self.playerKey = playerKey
        self.previewURL = previewURL

        let resolved = resolveEffectiveMedia(url: url, type: type)
        if currentURL != resolved.url || currentType != resolved.type {
            let previousURL = currentURL
            let previousType = currentType
            currentURL = resolved.url
            currentType = resolved.type
            if let resolvedURL = resolved.url {
                updateSecurityScopeAccess(for: resolvedURL)
                loadMedia(url: resolvedURL, type: resolved.type, previousURL: previousURL, previousType: previousType)
            } else {
                releaseSecurityScopeAccessIfNeeded()
                stopPlayback()
                imageView.image = nil
                mediaSize = .zero
                isAnimatedImage = false
            }
        }

        needsLayout = true
        updatePlayback()
    }

    private func updateSecurityScopeAccess(for url: URL) {
        guard url.isFileURL else {
            releaseSecurityScopeAccessIfNeeded()
            return
        }

        if securityScopedURL == url {
            return
        }

        releaseSecurityScopeAccessIfNeeded()
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
            isAccessingSecurityScope = true
        }
    }

    private func releaseSecurityScopeAccessIfNeeded() {
        guard isAccessingSecurityScope, let scopedURL = securityScopedURL else {
            securityScopedURL = nil
            isAccessingSecurityScope = false
            return
        }
        scopedURL.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        isAccessingSecurityScope = false
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        let targetSize = mediaSize == .zero ? bounds.size : mediaSize
        let fittedFrame = computeFrame(container: bounds.size, media: targetSize, mode: contentMode, scale: scale, offset: offset)

        if currentType == .video {
            playerLayer?.frame = fittedFrame
        } else {
            imageView.frame = fittedFrame
        }
    }

    private func loadMedia(url: URL, type: SkinType, previousURL: URL?, previousType: SkinType) {
        if type == .video, !playerKey.isEmpty, let cached = VideoPlayerPool.shared.cachedEntry(forKey: playerKey, url: url) {
            if cached.item.status == .failed || cached.item.error != nil || cached.player.error != nil {
                VideoPlayerPool.shared.remove(forKey: playerKey)
            } else {
                attachPlayer(entry: cached)
                return
            }
        }
        let shouldReleasePool = previousType == .video && previousURL != url
        stopPlayback(releasePool: shouldReleasePool)
        loadGeneration += 1
        imageRetryCount = 0
        videoRetryCount = 0
        let generation = loadGeneration
        DebugLog.log("loadMedia: type=\(type) url=\(url.path)")

        switch type {
        case .image:
            imageView.isHidden = false
            if let playerLayer = playerLayer {
                playerLayer.removeFromSuperlayer()
                self.playerLayer = nil
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if !SecurityScopedBookmark.fileExists(at: url) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        guard generation == self.loadGeneration, self.currentURL == url, self.currentType == .image else { return }
                        self.imageView.image = nil
                        self.mediaSize = .zero
                        self.isAnimatedImage = false
                        self.needsLayout = true
                    }
                    return
                }
                let image = NSImage(contentsOf: url)
                let size = image?.size ?? .zero
                let animated = self.isAnimated(image)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    guard generation == self.loadGeneration, self.currentURL == url, self.currentType == .image else { return }
                    if image == nil, self.imageRetryCount < 2 {
                        self.imageRetryCount += 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                            guard let self = self else { return }
                            guard generation == self.loadGeneration, self.currentURL == url, self.currentType == .image else { return }
                            self.loadMedia(url: url, type: .image, previousURL: url, previousType: .image)
                        }
                        return
                    }
                    if let image = image {
                        self.imageView.image = image
                        self.mediaSize = size
                        self.isAnimatedImage = animated
                        self.needsLayout = true
                        self.updatePlayback()
                    }
                }
            }
        case .video:
            imageView.isHidden = true
            mediaSize = .zero
            prepareVideo(url: url, generation: generation)
        case .none:
            imageView.image = nil
            mediaSize = .zero
        }
    }

    private func prepareVideo(url: URL, generation: Int) {
        if !SecurityScopedBookmark.fileExists(at: url) {
            return
        }
        if isSleeping {
            pendingWakeReload = true
            return
        }

        if !playerKey.isEmpty, let cached = VideoPlayerPool.shared.cachedEntry(forKey: playerKey, url: url) {
            attachPlayer(entry: cached)
            return
        }

        if !playerKey.isEmpty {
            VideoPlayerPool.shared.remove(forKey: playerKey)
        }

        let asset = AVURLAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["playable", "tracks"]) { [weak self] in
            guard let self = self else { return }
            var error: NSError?
            let playableStatus = asset.statusOfValue(forKey: "playable", error: &error)
            let tracksStatus = asset.statusOfValue(forKey: "tracks", error: &error)

            guard playableStatus == .loaded, tracksStatus == .loaded, asset.isPlayable else {
                self.scheduleVideoRetry(url: url, generation: generation)
                return
            }

            let track = asset.tracks(withMediaType: .video).first
            let size = track?.naturalSize.applying(track?.preferredTransform ?? .identity) ?? .zero

            VideoLoadGate.shared.scheduleOnMain { [weak self] in
                guard let self = self else { return }
                guard generation == self.loadGeneration, self.currentURL == url, self.currentType == .video else { return }
                guard !self.isSleeping else {
                    self.pendingWakeReload = true
                    return
                }
                guard self.isVisibleToUser, self.window != nil else {
                    self.pendingWakeReload = true
                    return
                }

                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                player.isMuted = self.isMuted
                player.actionAtItemEnd = .none
                let entry = VideoPlayerPool.Entry(
                    url: url,
                    player: player,
                    item: item,
                    size: CGSize(width: abs(size.width), height: abs(size.height))
                )
                if !self.playerKey.isEmpty {
                    VideoPlayerPool.shared.store(entry: entry, forKey: self.playerKey)
                }
                self.attachPlayer(entry: entry)
            }
        }
    }

    private func attachPlayer(entry: VideoPlayerPool.Entry) {
        playbackObservers.forEach { NotificationCenter.default.removeObserver($0) }
        playbackObservers.removeAll()
        usesPooledPlayer = !playerKey.isEmpty
        player = entry.player
        player?.isMuted = isMuted

        let layer = AVPlayerLayer(player: entry.player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor
        playerLayer = layer
        self.layer?.addSublayer(layer)
        mediaSize = entry.size
        needsLayout = true
        addPlayerEndObserver(item: entry.item)
        updatePlayback()
    }

    private func scheduleVideoRetry(url: URL, generation: Int) {
        guard !isSleeping else { return }
        guard videoRetryCount < 2 else { return }
        videoRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self else { return }
            guard generation == self.loadGeneration, self.currentURL == url, self.currentType == .video else { return }
            self.prepareVideo(url: url, generation: generation)
        }
    }

    private func computeFrame(container: CGSize, media: CGSize, mode: SkinContentMode, scale: Double, offset: CGSize) -> CGRect {
        let containerAspect = container.width / max(container.height, 1)
        let mediaAspect = media.width / max(media.height, 1)

        var width: CGFloat = container.width
        var height: CGFloat = container.height

        switch mode {
        case .fit:
            if mediaAspect > containerAspect {
                width = container.width
                height = width / mediaAspect
            } else {
                height = container.height
                width = height * mediaAspect
            }
        case .fill:
            if mediaAspect > containerAspect {
                height = container.height
                width = height * mediaAspect
            } else {
                width = container.width
                height = width / mediaAspect
            }
        }

        width *= CGFloat(scale)
        height *= CGFloat(scale)

        let originX = (container.width - width) / 2.0 + offset.width
        let originY = (container.height - height) / 2.0 + offset.height
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func isAnimated(_ image: NSImage?) -> Bool {
        guard let image = image else { return false }
        for rep in image.representations {
            if let bitmap = rep as? NSBitmapImageRep {
                let frames = bitmap.value(forProperty: .frameCount) as? Int ?? 1
                if frames > 1 { return true }
            }
        }
        return false
    }

    private func updateVisibility() {
        guard let window = window else {
            isVisibleToUser = false
            updatePlayback()
            return
        }
        let visible = window.isVisible && window.occlusionState.contains(.visible)
        isVisibleToUser = visible
        updatePlayback()
        if visible, pendingWakeReload, !isSleeping {
            scheduleWakeReload()
        }
    }

    private func handleSleep() {
        isSleeping = true
        isVisibleToUser = false
        pendingWakeReload = false
        pendingWakeWorkItem?.cancel()
        DebugLog.log("skin sleep: type=\(currentType)")
        if currentType == .video {
            player?.pause()
        }
    }

    private func handleWake() {
        isSleeping = false
        DebugLog.log("skin wake: type=\(currentType)")
        if currentType == .video {
            pendingWakeReload = true
            updateVisibility()
            return
        }
        pendingWakeReload = true
        scheduleWakeReload()
    }

    private func updatePlayback() {
        if currentType == .video {
            player?.isMuted = isMuted
            if isVisibleToUser && !isSleeping && systemPlaybackEnabled {
                player?.play()
            } else {
                player?.pause()
            }
        } else if currentType == .image, isAnimatedImage {
            imageView.animates = isVisibleToUser && systemPlaybackEnabled
        } else {
            imageView.animates = false
        }
    }

    private func stopPlayback(releasePool: Bool = false) {
        let oldPlayer = player
        player = nil
        playbackObservers.forEach { NotificationCenter.default.removeObserver($0) }
        playbackObservers.removeAll()
        if let layer = playerLayer {
            layer.player = nil
            layer.removeFromSuperlayer()
        }
        playerLayer = nil
        DebugLog.log("stopPlayback: type=\(currentType)")
        if usesPooledPlayer {
            if releasePool, !playerKey.isEmpty {
                VideoPlayerPool.shared.remove(forKey: playerKey)
            } else {
                oldPlayer?.pause()
            }
        } else if let player = oldPlayer {
            PlaybackReaper.shared.release(player)
        }
        usesPooledPlayer = false
    }

    private func addPlayerEndObserver(item: AVPlayerItem) {
        let obs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            guard self.currentType == .video else { return }
            item.seek(to: .zero) { [weak self] _ in
                guard let self = self else { return }
                if self.isVisibleToUser && !self.isSleeping {
                    self.player?.play()
                }
            }
        }
        playbackObservers.append(obs)
    }

    private func scheduleWakeReload() {
        pendingWakeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performWakeReloadIfNeeded()
        }
        pendingWakeWorkItem = item
        let jitterBucket = abs(ObjectIdentifier(self).hashValue) % 6
        let delay = 1.2 + Double(jitterBucket) * 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func performWakeReloadIfNeeded() {
        guard pendingWakeReload, !isSleeping else { return }
        guard let url = currentURL else { return }
        let type = currentType
        if type == .video {
            pendingWakeReload = false
            if shouldForceReloadVideoOnWake() {
                stopPlayback(releasePool: true)
                loadMedia(url: url, type: type, previousURL: url, previousType: type)
                needsLayout = true
            }
            updateVisibility()
            return
        }

        if type == .image, imageView.image != nil {
            pendingWakeReload = false
            updateVisibility()
            return
        }

        if window == nil {
            updateVisibility()
            return
        }

        pendingWakeReload = false
        if type == .video {
            stopPlayback()
        }
        loadMedia(url: url, type: type, previousURL: url, previousType: type)
        needsLayout = true
        updateVisibility()
    }

    private func shouldForceReloadVideoOnWake() -> Bool {
        if player == nil || playerLayer == nil {
            return true
        }
        if let item = player?.currentItem {
            if item.status == .failed {
                return true
            }
            if item.error != nil {
                return true
            }
        }
        if player?.error != nil {
            return true
        }
        return false
    }
}

private extension BackgroundMediaView {
    func resolveEffectiveMedia(url: URL, type: SkinType) -> (url: URL?, type: SkinType) {
        guard type == .video, !allowVideoPlayback else {
            return (url, type)
        }

        let preview = previewURL ?? VideoPreviewStore.shared.previewURL(for: url)
        if let preview = preview {
            return (preview, .image)
        }
        return (nil, .none)
    }
}

private final class VideoLoadGate {
    static let shared = VideoLoadGate()
    private let queue = DispatchQueue(label: "dockthings.video.load.gate")
    private var nextTime: DispatchTime = .now()
    private let spacing: DispatchTimeInterval = .milliseconds(180)

    func scheduleOnMain(_ block: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let now = DispatchTime.now()
            let scheduled = max(self.nextTime, now)
            self.nextTime = scheduled + self.spacing
            DispatchQueue.main.asyncAfter(deadline: scheduled, execute: block)
        }
    }
}

private final class PlaybackReaper {
    static let shared = PlaybackReaper()
    private let queue = DispatchQueue(label: "dockthings.playback.reaper", qos: .utility)

    func release(_ player: AVPlayer) {
        queue.async {
            autoreleasepool {
                player.pause()
                player.replaceCurrentItem(with: nil)
                _ = player
            }
        }
    }
}
