import Foundation
import SwiftData

enum ItemType: String, Codable {
    case file
    case folder
    case app
    case url
}

@Model
final class DockItem {
    var id: UUID
    var type: ItemType
    var urlString: String // Absolute path or URL
    var securityScopedBookmarkData: Data?
    var label: String
    var sortIndex: Int
    var customIconData: Data? // User-overridden icon

    @Relationship(inverse: \DockGroup.items)
    var group: DockGroup?

    @Relationship
    var category: DockCategory?

    init(type: ItemType, urlString: String, label: String, sortIndex: Int, bookmarkData: Data? = nil) {
        self.id = UUID()
        self.type = type
        self.urlString = urlString
        self.securityScopedBookmarkData = bookmarkData
        self.label = label
        self.sortIndex = sortIndex
    }

    var webURL: URL? {
        guard type == .url else { return nil }
        return URL(string: urlString)
    }

    @discardableResult
    func resolveFileURLAndRefreshBookmarkIfNeeded() -> URL? {
        guard type != .url else { return nil }
        guard let resolved = SecurityScopedBookmark.resolveFileURL(pathOrURLString: urlString, bookmarkData: securityScopedBookmarkData) else {
            return nil
        }

        if let refreshed = resolved.refreshedBookmarkData {
            securityScopedBookmarkData = refreshed
        } else if securityScopedBookmarkData == nil {
            securityScopedBookmarkData = SecurityScopedBookmark.createBookmarkData(for: resolved.url)
        }

        if urlString != resolved.url.absoluteString {
            urlString = resolved.url.absoluteString
        }

        return resolved.url
    }

    var displayURL: URL? {
        if type == .url {
            return webURL
        }
        return resolveFileURLAndRefreshBookmarkIfNeeded()
    }

    // 功能6：检查文件是否有效（URL类型始终返回true）
    var isValid: Bool {
        if type == .url { return webURL != nil }
        guard let url = resolveFileURLAndRefreshBookmarkIfNeeded() else { return false }
        return SecurityScopedBookmark.fileExists(at: url)
    }
}
