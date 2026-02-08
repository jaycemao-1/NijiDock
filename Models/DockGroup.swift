import Foundation
import SwiftData
import AppKit

// MARK: - 背景模糊样式
enum BlurStyle: Int, CaseIterable {
    case sidebar = 0
    case menu = 1
    case popover = 2
    case hud = 3
    case titlebar = 4

    var title: String {
        switch self {
        case .sidebar: return "侧边栏"
        case .menu: return "菜单"
        case .popover: return "气泡"
        case .hud: return "HUD"
        case .titlebar: return "标题栏"
        }
    }

    var material: NSVisualEffectView.Material {
        switch self {
        case .sidebar: return .sidebar
        case .menu: return .menu
        case .popover: return .popover
        case .hud: return .hudWindow
        case .titlebar: return .titlebar
        }
    }
}

// MARK: - 皮肤类型
enum SkinType: Int, CaseIterable {
    case none = 0
    case image = 1
    case video = 2

    var title: String {
        switch self {
        case .none: return "无"
        case .image: return "图片/动图"
        case .video: return "视频"
        }
    }
}

// MARK: - 皮肤显示模式
enum SkinContentMode: Int, CaseIterable {
    case fit = 0
    case fill = 1

    var title: String {
        switch self {
        case .fit: return "适配"
        case .fill: return "填充"
        }
    }
}

// MARK: - 组件层级
enum WidgetLayer: Int, CaseIterable {
    case background = 0
    case foreground = 1

    var title: String {
        switch self {
        case .background: return "背景层"
        case .foreground: return "前景层"
        }
    }
}

// MARK: - 时钟格式
enum ClockFormat: Int, CaseIterable {
    case h24 = 0
    case h12 = 1

    var title: String {
        switch self {
        case .h24: return "24 小时"
        case .h12: return "12 小时"
        }
    }
}

// MARK: - 温度单位
enum TemperatureUnit: Int, CaseIterable {
    case celsius = 0
    case fahrenheit = 1

    var title: String {
        switch self {
        case .celsius: return "摄氏"
        case .fahrenheit: return "华氏"
        }
    }
}

// MARK: - 窗口比例锁定
enum AspectRatioLock: Int, CaseIterable {
    case none = 0
    case ratio1_1 = 1      // 1:1 正方形
    case ratio3_4 = 2      // 3:4 竖屏
    case ratio4_3 = 3      // 4:3 横屏
    case ratio16_10 = 4    // 16:10 横屏
    case ratio10_16 = 5    // 10:16 竖屏
    case ratio16_9 = 6     // 16:9 横屏
    case ratio9_16 = 7     // 9:16 竖屏

    var title: String {
        switch self {
        case .none: return "自由"
        case .ratio1_1: return "1:1"
        case .ratio3_4: return "3:4"
        case .ratio4_3: return "4:3"
        case .ratio16_10: return "16:10"
        case .ratio10_16: return "10:16"
        case .ratio16_9: return "16:9"
        case .ratio9_16: return "9:16"
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .none: return nil
        case .ratio1_1: return 1.0
        case .ratio3_4: return 3.0 / 4.0
        case .ratio4_3: return 4.0 / 3.0
        case .ratio16_10: return 16.0 / 10.0
        case .ratio10_16: return 10.0 / 16.0
        case .ratio16_9: return 16.0 / 9.0
        case .ratio9_16: return 9.0 / 16.0
        }
    }
}

@Model
final class DockGroup {
    var id: UUID
    var name: String

    @Relationship(deleteRule: .cascade)
    var items: [DockItem] = []
    
    @Relationship(deleteRule: .cascade)
    var categories: [DockCategory] = []

    // Window State Persistence
    var frameString: String // Stores NSRect as string "{{x, y}, {w, h}}"
    var isVisible: Bool

    // Appearance customization
    var opacity: Double
    var theme: String // "Dark", "Light", "System"

    // 主题色 - 存储为十六进制字符串
    var themeColorHex: String = "007AFF"
    var customTextColorEnabled: Bool = false
    var textColorHex: String = "FFFFFF"

    // 模糊样式
    var blurStyleRaw: Int = BlurStyle.sidebar.rawValue

    // 皮肤设置（每个窗口独立）
    var skinTypeRaw: Int = SkinType.none.rawValue
    var skinPath: String?
    var skinBookmarkData: Data?
    var skinScale: Double = 1.0
    var skinOffsetX: Double = 0
    var skinOffsetY: Double = 0
    var skinOpacity: Double = 1.0
    var skinContentModeRaw: Int = SkinContentMode.fill.rawValue
    var skinEditEnabled: Bool = false
    var skinSoundEnabled: Bool = false

    // 自动隐藏
    var autoHideEnabled: Bool = false
    var autoHideOpacity: Double = 0.25

    // 显示设置
    var viewModeRaw: Int = 0 // 0: Grid, 1: List
    var iconSize: Double = 52.0
    // 常驻桌面：点击桌面/显示桌面时不被系统“收起到边栏”
    // 说明：开启后窗口会固定在桌面层级（可能被其他应用窗口遮挡）
    var stayOnDesktopEnabled: Bool = true
    var headerBarAutoHideEnabled: Bool = false
    // 配置栏自动隐藏：悬停多少秒后显示
    var headerBarRevealDelaySeconds: Double = 2.0
    // 窗口缩放时图标等比缩放：默认开启（更符合直觉，避免小窗口裁切）
    var iconScaleWithWindowEnabled: Bool = true
    // 图标缩放基准：用于“窗口缩放时图标等比缩放”
    var iconScaleBaseWidth: Double = 0
    var iconScaleBaseHeight: Double = 0

    // 窗口比例锁定
    var aspectRatioLockRaw: Int = AspectRatioLock.none.rawValue

    var viewMode: ViewMode {
        get { ViewMode(rawValue: viewModeRaw) ?? .grid }
        set { viewModeRaw = newValue.rawValue }
    }

    var blurStyle: BlurStyle {
        get { BlurStyle(rawValue: blurStyleRaw) ?? .sidebar }
        set { blurStyleRaw = newValue.rawValue }
    }

    var aspectRatioLock: AspectRatioLock {
        get { AspectRatioLock(rawValue: aspectRatioLockRaw) ?? .none }
        set { aspectRatioLockRaw = newValue.rawValue }
    }

    var skinType: SkinType {
        get { SkinType(rawValue: skinTypeRaw) ?? .none }
        set { skinTypeRaw = newValue.rawValue }
    }

    var skinContentMode: SkinContentMode {
        get { SkinContentMode(rawValue: skinContentModeRaw) ?? .fill }
        set { skinContentModeRaw = newValue.rawValue }
    }

    // 动态时钟设置
    var clockEnabled: Bool = false
    var widgetLayerRaw: Int = WidgetLayer.background.rawValue
    var clockFormatRaw: Int = ClockFormat.h24.rawValue
    var clockShowDate: Bool = false
    var clockShowSeconds: Bool = false
    var clockFontSize: Double = 32
    var clockOpacity: Double = 0.9
    var clockColorHex: String = "FFFFFF"
    var clockOffsetX: Double = 0
    var clockOffsetY: Double = 0

    // 组件编辑模式
    var widgetEditEnabled: Bool = false

    // 其他组件开关
    var weatherEnabled: Bool = false
    var batteryEnabled: Bool = false
    var cpuEnabled: Bool = false
    var networkEnabled: Bool = false
    var memoryEnabled: Bool = false
    var diskEnabled: Bool = false

    // 天气配置
    var weatherLocationQuery: String = ""
    var weatherUnitRaw: Int = TemperatureUnit.celsius.rawValue

    // 组件样式（除时钟外）
    var widgetFontSize: Double = 12
    var widgetOpacity: Double = 0.9
    var widgetMaskOpacity: Double = 0.2
    var widgetColorHex: String = "FFFFFF"
    var weatherFontSize: Double = 12
    var batteryFontSize: Double = 12
    var cpuFontSize: Double = 12
    var networkFontSize: Double = 12
    var weatherOpacity: Double = 0.9
    var weatherMaskOpacity: Double = 0.2
    var weatherColorHex: String = "FFFFFF"
    var batteryOpacity: Double = 0.9
    var batteryMaskOpacity: Double = 0.2
    var batteryColorHex: String = "FFFFFF"
    var cpuOpacity: Double = 0.9
    var cpuMaskOpacity: Double = 0.2
    var cpuColorHex: String = "FFFFFF"
    var networkOpacity: Double = 0.9
    var networkMaskOpacity: Double = 0.2
    var networkColorHex: String = "FFFFFF"
    var memoryFontSize: Double = 12
    var memoryOpacity: Double = 0.9
    var memoryMaskOpacity: Double = 0.2
    var memoryColorHex: String = "FFFFFF"
    var diskFontSize: Double = 12
    var diskOpacity: Double = 0.9
    var diskMaskOpacity: Double = 0.2
    var diskColorHex: String = "FFFFFF"
    var widgetStyleVersion: Int = 0

    // 组件位置
    var weatherOffsetX: Double = 0
    var weatherOffsetY: Double = 0
    var batteryOffsetX: Double = 0
    var batteryOffsetY: Double = 0
    var cpuOffsetX: Double = 0
    var cpuOffsetY: Double = 0
    var networkOffsetX: Double = 0
    var networkOffsetY: Double = 0
    var memoryOffsetX: Double = 0
    var memoryOffsetY: Double = 0
    var diskOffsetX: Double = 0
    var diskOffsetY: Double = 0

    @discardableResult
    func resolveSkinURLAndRefreshBookmarkIfNeeded() -> URL? {
        guard let path = skinPath, !path.isEmpty else { return nil }

        if path.hasPrefix("builtin://") {
            skinBookmarkData = nil
            return BuiltInSkinCatalog.resolveURL(from: path)
        }

        guard let resolved = SecurityScopedBookmark.resolveFileURL(pathOrURLString: path, bookmarkData: skinBookmarkData) else {
            return BuiltInSkinCatalog.resolveURL(from: path)
        }

        if let refreshed = resolved.refreshedBookmarkData {
            skinBookmarkData = refreshed
        } else if skinBookmarkData == nil {
            skinBookmarkData = SecurityScopedBookmark.createBookmarkData(for: resolved.url)
        }

        if skinPath != resolved.url.path {
            skinPath = resolved.url.path
        }

        if SecurityScopedBookmark.fileExists(at: resolved.url) {
            let bundlePath = Bundle.main.bundlePath
            if resolved.url.path.hasPrefix(bundlePath) {
                let filename = resolved.url.lastPathComponent
                skinPath = BuiltInSkinCatalog.builtinPath(for: filename)
                skinBookmarkData = nil
                return BuiltInSkinCatalog.resolveURL(from: skinPath ?? "")
            }
            return resolved.url
        }

        return BuiltInSkinCatalog.resolveURL(from: path)
    }

    var skinURL: URL? {
        resolveSkinURLAndRefreshBookmarkIfNeeded()
    }

    var widgetLayer: WidgetLayer {
        get { WidgetLayer(rawValue: widgetLayerRaw) ?? .background }
        set { widgetLayerRaw = newValue.rawValue }
    }

    var clockFormat: ClockFormat {
        get { ClockFormat(rawValue: clockFormatRaw) ?? .h24 }
        set { clockFormatRaw = newValue.rawValue }
    }

    var weatherUnit: TemperatureUnit {
        get { TemperatureUnit(rawValue: weatherUnitRaw) ?? .celsius }
        set { weatherUnitRaw = newValue.rawValue }
    }

    init(name: String, frameString: String = "{{100, 300}, {320, 400}}") {
        self.id = UUID()
        self.name = name
        self.frameString = frameString
        self.isVisible = true
        self.opacity = 0.85
        self.theme = "System"
        self.themeColorHex = "007AFF" // 默认蓝色
        self.customTextColorEnabled = false
        self.textColorHex = "FFFFFF"
        self.blurStyleRaw = BlurStyle.sidebar.rawValue
        self.skinTypeRaw = SkinType.none.rawValue
        self.skinPath = nil
        self.skinBookmarkData = nil
        self.skinScale = 1.0
        self.skinOffsetX = 0
        self.skinOffsetY = 0
        self.skinOpacity = 1.0
        self.skinContentModeRaw = SkinContentMode.fill.rawValue
        self.skinEditEnabled = false
        self.skinSoundEnabled = false
        self.clockEnabled = false
        self.widgetLayerRaw = WidgetLayer.background.rawValue
        self.clockFormatRaw = ClockFormat.h24.rawValue
        self.clockShowDate = false
        self.clockShowSeconds = false
        self.clockFontSize = 32
        self.clockOpacity = 0.9
        self.clockColorHex = "FFFFFF"
        self.clockOffsetX = 0
        self.clockOffsetY = 0
        self.widgetEditEnabled = false
        self.weatherEnabled = false
        self.batteryEnabled = false
        self.cpuEnabled = false
        self.networkEnabled = false
        self.memoryEnabled = false
        self.diskEnabled = false
        self.weatherLocationQuery = ""
        self.weatherUnitRaw = TemperatureUnit.celsius.rawValue
        self.widgetFontSize = 12
        self.widgetOpacity = 0.9
        self.widgetMaskOpacity = 0.2
        self.widgetColorHex = "FFFFFF"
        self.weatherFontSize = 12
        self.batteryFontSize = 12
        self.cpuFontSize = 12
        self.networkFontSize = 12
        self.weatherOpacity = 0.9
        self.weatherMaskOpacity = 0.2
        self.weatherColorHex = "FFFFFF"
        self.batteryOpacity = 0.9
        self.batteryMaskOpacity = 0.2
        self.batteryColorHex = "FFFFFF"
        self.cpuOpacity = 0.9
        self.cpuMaskOpacity = 0.2
        self.cpuColorHex = "FFFFFF"
        self.networkOpacity = 0.9
        self.networkMaskOpacity = 0.2
        self.networkColorHex = "FFFFFF"
        self.memoryFontSize = 12
        self.memoryOpacity = 0.9
        self.memoryMaskOpacity = 0.2
        self.memoryColorHex = "FFFFFF"
        self.diskFontSize = 12
        self.diskOpacity = 0.9
        self.diskMaskOpacity = 0.2
        self.diskColorHex = "FFFFFF"
        self.widgetStyleVersion = 0
        self.weatherOffsetX = 0
        self.weatherOffsetY = 0
        self.batteryOffsetX = 0
        self.batteryOffsetY = 0
        self.cpuOffsetX = 0
        self.cpuOffsetY = 0
        self.networkOffsetX = 0
        self.networkOffsetY = 0
        self.memoryOffsetX = 0
        self.memoryOffsetY = 0
        self.diskOffsetX = 0
        self.diskOffsetY = 0
        self.autoHideEnabled = false
        self.autoHideOpacity = 0.25
        self.viewModeRaw = 0
        self.iconSize = 52.0
        self.stayOnDesktopEnabled = true
        self.headerBarAutoHideEnabled = false
        self.headerBarRevealDelaySeconds = 2.0
        self.iconScaleWithWindowEnabled = true
        let rect = NSRectFromString(frameString)
        self.iconScaleBaseWidth = rect.width > 0 ? Double(rect.width) : 0
        self.iconScaleBaseHeight = rect.height > 0 ? Double(rect.height) : 0
        self.aspectRatioLockRaw = AspectRatioLock.none.rawValue
    }
}

enum ViewMode: Int, Codable, CaseIterable {
    case grid = 0
    case list = 1

    var title: String {
        switch self {
        case .grid: return "网格"
        case .list: return "列表"
        }
    }

    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

@Model
final class DockCategory {
    var id: UUID
    var name: String
    var sortIndex: Int
    var isDefault: Bool // 是否为默认分类
    var colorHex: String? // 分类专属颜色 (可选)

    @Relationship(inverse: \DockGroup.categories)
    var group: DockGroup?

    @Relationship(inverse: \DockItem.category)
    var items: [DockItem] = []

    init(name: String, sortIndex: Int, isDefault: Bool = false, colorHex: String? = nil) {
        self.id = UUID()
        self.name = name
        self.sortIndex = sortIndex
        self.isDefault = isDefault
        self.colorHex = colorHex
    }
}
