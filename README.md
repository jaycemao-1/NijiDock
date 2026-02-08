# 次元坞 (NijiDock)

当前版本：2.0

次元坞 (NijiDock) 是一款主打二次元动态壁纸和皮肤更换的 macOS 菜单栏工具，用于创建可自定义的「浮动 Dock」窗口，并支持桌面动态壁纸（图片/视频）。

## 系统要求

- macOS 14.0+（项目使用 SwiftData）
- 可选：联网（天气组件需要访问 Open-Meteo API）

## 功能概览

### 1) 浮动 Dock

- 支持创建多个 Dock 窗口，位置/大小/可见性会自动保存
- 支持网格 / 列表显示模式，图标大小可调
- 支持拖拽添加：应用（`.app`）、文件、文件夹、网页链接
- 支持搜索（`⌘F`），分类切换（`⌘⌥←/→`）
- 支持排序与归类：
  - 窗口内拖拽重排
  - 跨 Dock 拖拽移动
  - 拖拽到顶部分类标签可快速移动到该分类
- 右键菜单：
  - Dock 窗口背景：重命名 Dock / 管理分类 / 删除 Dock
  - 单个图标：打开 / 在 Finder 中显示 / 打开所在文件夹 / 重命名 / 移动到分类 / 删除
- 文件夹「栈」预览：双击文件夹图标弹出文件网格，点击可直接打开

### 2) 窗口皮肤（背景）

- 支持内置皮肤库 + 本地图片/动图/视频
- 支持显示模式（适配/填充）、缩放、透明度、偏移
- 皮肤编辑模式：拖动调整位置、滚轮缩放、双击重置
- 视频皮肤支持“播放皮肤声音”
- 菜单栏支持一键暂停/恢复所有视频皮肤播放（桌面壁纸也会受影响）

### 3) 组件（小部件）

- 可开启：时钟 / 天气 / 电量 / CPU / 网速 / 内存 / 磁盘
- 组件支持：背景层/前景层、拖拽摆放（组件编辑模式）、右键进入设置
- 时钟：12/24 小时、日期/秒、字号/颜色/透明度、位置
- 天气：城市搜索或使用系统定位（需授权）、摄氏/华氏；默认每 15 分钟刷新（Open-Meteo）
- 电量：电量百分比与充电状态（无电池设备会显示“无电池”）
- CPU：CPU 使用率
- 网速：上/下行速度
- 内存：已用比例与容量
- 磁盘：剩余容量与比例

### 4) 桌面壁纸

- 菜单栏 → “桌面壁纸”：
  - 按屏幕分别设置内置/本地图片或视频作为桌面壁纸
  - 壁纸声音开关（视频）
  - 清除当前屏幕壁纸 / 清除全部桌面壁纸
- 自动处理屏幕变化与睡眠唤醒

## 使用方式

1. 从菜单栏图标打开：
   - 新建 Dock
   - 显示/隐藏 Dock
   - 桌面壁纸设置 / 清除全部桌面壁纸
   - 暂停/恢复视频皮肤播放
2. 在 Dock 窗口中：
   - 拖拽文件/应用/文件夹/链接到窗口添加
   - 右键窗口背景或图标进行更多操作

## ⚠️ 为什么运行后 Dock 里还有图标？

NijiDock 是“菜单栏常驻工具”，正常情况下**不会在系统程序坞（Dock）里显示图标**。

如果你在 Dock 里仍看到图标，请检查两点：

1) `NijiDock/Info.plist` 是否包含：
- `LSUIElement = YES`

2) `NijiDock/NijiDockApp.swift` 是否设置了：
- `NSApplication.shared.setActivationPolicy(.accessory)`

只要上述任一项生效，就不会在 Dock 中显示图标（仍可从菜单栏使用）。

> 备注：如果你曾经把 NijiDock 手动拖到系统 Dock 里“固定”，它仍会作为固定项显示；从 Dock 里右键移除即可。

## 开发与构建

- 打开 `NijiDock.xcodeproj`，选择 scheme `NijiDock` 运行。
- 工程使用显式 `Info.plist`（`NijiDock/Info.plist`），版本号来自：
  - `MARKETING_VERSION`（例如 2.0）
  - `CURRENT_PROJECT_VERSION`（构建号）

## 一键编译 DMG（签名 + 公证）

脚本位置：`Scripts/build_dmg.sh`

### 方式一：使用 notarytool keychain profile（推荐）

```bash
export SIGN_IDENTITY="Developer ID Application: 你的公司名 (TEAMID)"
export NOTARY_PROFILE="notary-profile-name"
bash "Scripts/build_dmg.sh"
```

### 方式二：使用 Apple ID + App 专用密码

```bash
export SIGN_IDENTITY="Developer ID Application: 你的公司名 (TEAMID)"
export APPLE_ID="your@appleid.com"
export APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export TEAM_ID="YOURTEAMID"
bash "Scripts/build_dmg.sh"
```

### 输出位置

- `build/NijiDock-2.0-arm64.dmg`
- `build/NijiDock-2.0-x86_64.dmg`

### 可选参数

- `APP_VERSION`：覆盖版本号（默认读取 Xcode 的 `MARKETING_VERSION`）
- `SIGN_IDENTITY`：Developer ID Application 证书
- `NOTARY_PROFILE`：notarytool keychain profile 名称
- `APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD` / `TEAM_ID`：Apple 公证参数

## 内置皮肤资源（开发者）

- 清单：`Resources/Skins/skin_manifest.json`（包含 `name/category/type/filename/sourceUrl`）
- 文件目录：`Resources/Skins`
- 批量下载 Pixabay 视频到内置皮肤目录：

```bash
python3 "Scripts/fetch_pixabay_skins.py" --api-key "YOUR_API_KEY"
```

参数说明：

- `--force`：覆盖已存在的文件

## 隐私说明

- 天气组件：会将你输入的城市关键词发送到 Open-Meteo 的地理编码与天气接口以获取数据。
- 天气定位：当你点击“使用定位”时，会向系统请求定位权限，并使用 Apple 的反向地理编码服务将当前位置解析为城市名。
- 其他数据：Dock 配置使用 SwiftData 本地存储；桌面壁纸配置使用本地 `UserDefaults` 保存。
- 文件访问：应用遵循 App Sandbox，仅访问系统允许范围与用户主动选择的文件/文件夹。
- 授权持久化：对用户主动选择的本地文件，应用使用 `security-scoped bookmarks` 保存访问授权，避免重启后失效。
