import Foundation
import OSLog
import SwiftData

enum DebugLog {
    private static let logger = Logger(subsystem: "com.jaycemao.NijiDock", category: "Debug")

    static var isEnabled: Bool {
        true
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        print("[NijiDockDebug] \(message)")
        logger.info("\(message, privacy: .public)")
    }
}

enum SecurityScopedBookmark {
    @MainActor private static weak var accessContext: ModelContext?

    struct ResolvedFile {
        let url: URL
        let refreshedBookmarkData: Data?
    }

    static func createBookmarkData(for url: URL) -> Data? {
        guard url.isFileURL else { return nil }
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            DebugLog.log("创建安全作用域书签失败: path=\(url.path) error=\(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    static func seedAccessContext(_ context: ModelContext) {
        accessContext = context
    }

    static func resolveFileURL(pathOrURLString: String, bookmarkData: Data?) -> ResolvedFile? {
        if let bookmarkData,
           let resolved = resolveBookmarkURL(bookmarkData) {
            return resolved
        }

        guard let url = parseFileURL(from: pathOrURLString) else { return nil }
        return ResolvedFile(url: url, refreshedBookmarkData: nil)
    }

    static func fileExists(at url: URL) -> Bool {
        withAccess(to: url) { scopedURL in
            FileManager.default.fileExists(atPath: scopedURL.path)
        }
    }

    static func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]) throws -> [URL] {
        try withAccess(to: url) { scopedURL in
            try FileManager.default.contentsOfDirectory(at: scopedURL, includingPropertiesForKeys: keys)
        }
    }

    @discardableResult
    static func withAccess<T>(to url: URL, _ action: (URL) throws -> T) rethrows -> T {
        guard url.isFileURL else {
            return try action(url)
        }

        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try action(url)
    }

    @MainActor
    static func refreshPersistedBookmarksIfNeeded() {
        guard let context = accessContext else { return }
        var didChange = false

        do {
            let itemDescriptor = FetchDescriptor<DockItem>()
            let items = try context.fetch(itemDescriptor)
            for item in items where item.type != .url {
                let before = item.securityScopedBookmarkData
                _ = item.resolveFileURLAndRefreshBookmarkIfNeeded()
                if before != item.securityScopedBookmarkData {
                    didChange = true
                }
            }

            let groupDescriptor = FetchDescriptor<DockGroup>()
            let groups = try context.fetch(groupDescriptor)
            for group in groups {
                let beforePath = group.skinPath
                let beforeBookmark = group.skinBookmarkData
                _ = group.resolveSkinURLAndRefreshBookmarkIfNeeded()
                if beforePath != group.skinPath || beforeBookmark != group.skinBookmarkData {
                    didChange = true
                }
            }

            if didChange {
                try? context.save()
            }
        } catch {
            DebugLog.log("刷新安全书签失败: \(error.localizedDescription)")
        }
    }

    private static func resolveBookmarkURL(_ bookmarkData: Data) -> ResolvedFile? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let refreshedData = isStale ? createBookmarkData(for: url) : nil
            return ResolvedFile(url: url, refreshedBookmarkData: refreshedData)
        } catch {
            DebugLog.log("解析安全作用域书签失败: error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func parseFileURL(from pathOrURLString: String) -> URL? {
        let trimmed = pathOrURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed) {
            if url.isFileURL {
                return url
            }

            if url.scheme == nil {
                return URL(fileURLWithPath: trimmed)
            }

            return nil
        }

        return URL(fileURLWithPath: trimmed)
    }
}
