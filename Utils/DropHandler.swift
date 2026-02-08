import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DropHandler {
    private static let dockItemTypeIdentifier = "com.jaycemao.nijidock.dock-item"

    static func handleDrop(providers: [NSItemProvider], group: DockGroup, category: DockCategory?, context: ModelContext) -> Bool {
        for provider in providers {
            let hasDockItem = provider.hasItemConformingToTypeIdentifier(dockItemTypeIdentifier)
            let hasPlainText = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            let hasURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            DebugLog.log("拖拽接收: types=\(provider.registeredTypeIdentifiers) hasDockItem=\(hasDockItem) hasPlainText=\(hasPlainText) hasURL=\(hasURL)")

            if hasDockItem {
                provider.loadItem(forTypeIdentifier: dockItemTypeIdentifier, options: nil) { (item, error) in
                    if let error = error {
                        DebugLog.log("拖拽接收: dockItem 加载失败 error=\(error.localizedDescription)")
                        return
                    }
                    if let data = item as? Data, let string = String(data: data, encoding: .utf8), string.hasPrefix("dock-item:") {
                        let uuidString = String(string.dropFirst(10))
                        if let uuid = UUID(uuidString: uuidString) {
                            DebugLog.log("拖拽接收: dockItem id=\(uuid)")
                            Task { @MainActor in
                                handleCrossDockDrop(itemId: uuid, targetGroup: group, targetCategory: category, context: context)
                                DockDragContext.shared.clear()
                            }
                            return
                        }
                    }
                    DebugLog.log("拖拽接收: dockItem 数据无效")
                }
                continue
            }

            if hasPlainText {
                // 内部拖拽优先：仅当检测到自定义标识时处理
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { (item, error) in
                    if let error = error {
                        DebugLog.log("拖拽接收: plainText 加载失败 error=\(error.localizedDescription)")
                        return
                    }
                    if error == nil,
                       let data = item as? Data,
                       let string = String(data: data, encoding: .utf8),
                       string.hasPrefix("dock-item:") {
                        let uuidString = String(string.dropFirst(10))
                        if let uuid = UUID(uuidString: uuidString) {
                            DebugLog.log("拖拽接收: internal id=\(uuid)")
                            Task { @MainActor in
                                handleCrossDockDrop(itemId: uuid, targetGroup: group, targetCategory: category, context: context)
                                DockDragContext.shared.clear()
                            }
                        }
                        return
                    }

                    if let string = item as? String {
                        DebugLog.log("拖拽接收: plainText 非内部标识 length=\(string.count)")
                    } else if let data = item as? Data {
                        DebugLog.log("拖拽接收: plainText Data 非内部标识 length=\(data.count)")
                    } else if item != nil {
                        DebugLog.log("拖拽接收: plainText 非内部标识 type=\(String(describing: type(of: item)))")
                    } else {
                        DebugLog.log("拖拽接收: plainText 空数据")
                    }

                    // 非内部拖拽，尝试按 URL 处理（避免 SwiftUI 文件系统项加载路径）
                    if hasURL {
                        DebugLog.log("拖拽接收: plainText 非内部标识，转 URL 处理")
                        loadURLItem(provider: provider, group: group, category: category, context: context)
                    } else {
                        Task { @MainActor in
                            if let fallback = DockDragContext.shared.consumeIfActive() {
                                DebugLog.log("拖拽接收: fallback internal id=\(fallback.itemId)")
                                handleCrossDockDrop(itemId: fallback.itemId, targetGroup: group, targetCategory: category, context: context)
                            } else {
                                // 处理特殊类型（如 public.python-script）只有文件表示，没有 URL
                                DebugLog.log("拖拽接收: plainText 非内部标识，尝试文件表示加载")
                                loadFileItem(provider: provider, group: group, category: category, context: context)
                            }
                        }
                        return
                    }
                }
            } else if hasURL {
                DebugLog.log("拖拽接收: 仅 URL 处理")
                loadURLItem(provider: provider, group: group, category: category, context: context)
            } else {
                Task { @MainActor in
                    if let fallback = DockDragContext.shared.consumeIfActive() {
                        DebugLog.log("拖拽接收: fallback internal id=\(fallback.itemId)")
                        handleCrossDockDrop(itemId: fallback.itemId, targetGroup: group, targetCategory: category, context: context)
                    } else {
                        DebugLog.log("拖拽接收: 无 URL，尝试文件表示加载")
                        loadFileItem(provider: provider, group: group, category: category, context: context)
                    }
                }
                continue
            }
        }
        return true
    }

    private static func loadURLItem(provider: NSItemProvider, group: DockGroup, category: DockCategory?, context: ModelContext) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { (item, error) in
            if let error = error {
                DebugLog.log("拖拽接收: URL 加载失败 error=\(error.localizedDescription)")
                return
            }

            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                DebugLog.log("拖拽接收: URL Data url=\(url.absoluteString)")
                Task { @MainActor in
                    createItem(from: url, group: group, category: category, context: context, isWeb: !url.isFileURL)
                }
            } else if let url = item as? URL {
                DebugLog.log("拖拽接收: URL url=\(url.absoluteString)")
                Task { @MainActor in
                    createItem(from: url, group: group, category: category, context: context, isWeb: !url.isFileURL)
                }
            } else if item != nil {
                DebugLog.log("拖拽接收: URL 非法类型 type=\(String(describing: type(of: item)))")
            } else {
                DebugLog.log("拖拽接收: URL 空数据")
            }
        }
    }

    private static func loadFileItem(provider: NSItemProvider, group: DockGroup, category: DockCategory?, context: ModelContext) {
        let typeIds = provider.registeredTypeIdentifiers
        guard !typeIds.isEmpty else {
            DebugLog.log("拖拽接收: 文件表示加载失败，无可用类型")
            return
        }

        func tryLoad(index: Int) {
            guard index < typeIds.count else {
                DebugLog.log("拖拽接收: 文件表示加载失败，全部类型尝试完毕")
                return
            }
            let typeId = typeIds[index]
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeId) { url, inPlace, error in
                if let url = url {
                    DebugLog.log("拖拽接收: 文件表示加载成功 url=\(url.path) inPlace=\(inPlace) type=\(typeId)")
                    Task { @MainActor in
                        createItem(from: url, group: group, category: category, context: context, isWeb: false)
                    }
                    return
                }
                if let error = error {
                    DebugLog.log("拖拽接收: inPlace 文件表示加载失败 type=\(typeId) error=\(error.localizedDescription)")
                }
                provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, error in
                    if let url = url {
                        DebugLog.log("拖拽接收: 文件表示加载成功(非 inPlace) url=\(url.path) type=\(typeId)")
                        Task { @MainActor in
                            createItem(from: url, group: group, category: category, context: context, isWeb: false)
                        }
                        return
                    }
                    if let error = error {
                        DebugLog.log("拖拽接收: 文件表示加载失败 type=\(typeId) error=\(error.localizedDescription)")
                    }
                    tryLoad(index: index + 1)
                }
            }
        }

        tryLoad(index: 0)
    }

    // 处理跨Dock拖拽
    @MainActor
    private static func handleCrossDockDrop(itemId: UUID, targetGroup: DockGroup, targetCategory: DockCategory?, context: ModelContext) {
        // 优化：直接查找 Item，而不是遍历所有 Group
        // 之前的 O(N*M) 遍历会导致大量数据加载和性能问题

        let descriptor = FetchDescriptor<DockItem>(predicate: #Predicate<DockItem> { item in
            item.id == itemId
        })

        guard let items = try? context.fetch(descriptor),
              let item = items.first,
              let sourceGroup = item.group else {
            return
        }

        // 如果是同一个group，不处理（由DockItemDropDelegate处理内部排序）
        if sourceGroup.id == targetGroup.id { return }

        // 跨Dock移动：从源group删除，添加到目标group
        // 注意：SwiftData 的关系管理会自动处理 inverse relationship
        // 即设置 item.group = targetGroup 会自动从 sourceGroup.items 移除并添加到 targetGroup.items

        // 手动处理数组以确保 UI 立即更新 (虽然 SwiftData 会同步，但显式操作数组更安全且符合当前逻辑)
        if let index = sourceGroup.items.firstIndex(where: { $0.id == itemId }) {
            sourceGroup.items.remove(at: index)
        }

        targetGroup.items.append(item)
        item.group = targetGroup
        item.category = targetCategory
        item.sortIndex = targetGroup.items.count - 1

        try? context.save()
    }

    @MainActor
    private static func createItem(from url: URL, group: DockGroup, category: DockCategory?, context: ModelContext, isWeb: Bool = false) {
        let normalizedURL = (!isWeb && !url.isFileURL) ? URL(fileURLWithPath: url.path) : url
        let type: ItemType
        if isWeb {
            type = .url
        } else if normalizedURL.pathExtension.lowercased() == "app" {
            type = .app
        } else if normalizedURL.hasDirectoryPath {
            type = .folder
        } else {
            type = .file
        }
        DebugLog.log("拖拽接收: createItem url=\(normalizedURL.absoluteString) type=\(type)")

        let name = isWeb ? (normalizedURL.host ?? "Link") : normalizedURL.lastPathComponent
        let bookmarkData = isWeb ? nil : SecurityScopedBookmark.createBookmarkData(for: normalizedURL)

        let newItem = DockItem(
            type: type,
            urlString: normalizedURL.absoluteString,
            label: name,
            sortIndex: group.items.count,
            bookmarkData: bookmarkData
        )
        newItem.group = group

        // 如果当前有选中的分类，则分配给该分类
        // 如果没有选中分类（显示全部），则尝试自动归类（可选优化，目前先分配给第一个匹配类型的分类或保持nil）
        if let category = category {
            newItem.category = category
        } else {
            // 尝试自动归类到默认分类中
            if let targetCategory = group.categories.first(where: { cat in
                (cat.name == "Apps" && type == .app) ||
                (cat.name == "Files" && (type == .file || type == .folder)) ||
                (cat.name == "Web" && type == .url)
            }) {
                newItem.category = targetCategory
            }
        }

        group.items.append(newItem)

        // Explicitly save to ensure persistence
        try? context.save()
    }
}
