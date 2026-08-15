# ios-lab

一个用于收集和展示各类 SwiftUI / iOS 实验 Demo 的示例项目。

## 项目作用

本项目作为一个 **Demo 合集**，提供统一的入口来浏览和体验各个独立的实验页面。

- **主页**是一个列表（`ContentView`），列出所有可用的 Demo。
- **点击列表项**即可导航进入对应的 Demo 详情页。

每个 Demo 都是自包含的 SwiftUI 视图，互不依赖，方便单独编写、预览与调试。

## 目录结构

```
ios-lab/                            # ← Xcode 同步组，放进来的文件自动纳入 target
├── ios_labApp.swift                # App 入口（公共）
├── ContentView.swift               # 主页：Demo 列表（公共）
├── Assets.xcassets/                # 资源（公共）
├── HolographicCard/                # Demo：镭射闪光卡片
│   ├── HolographicCardView.swift
│   └── HolographicFoil.metal
├── WindingSlotElements/            # Demo：卷带槽元素复刻
│   └── WindingSlotElementsView.swift
├── DynamicIsland/                  # Demo：App 内灵动岛
│   ├── InAppDynamicIslandView.swift # Demo 页
│   ├── InAppDynamicIsland.swift     # 可复用的岛体组件 + IslandMetrics
│   └── Usage.md                     # 组件使用指南（会被打进 bundle 根，见下）
└── RustCore/                       # Demo：RustCore 跨端架构
    ├── RustCoreLabView.swift
    ├── RustCoreWebHost.swift
    ├── RustCore.swift
    ├── RustCoreIPC.generated.swift # @generated
    ├── RustCoreUI.html             # @generated（web 构建产物）
    ├── rustcore.h
    └── ios-lab-Bridging-Header.h

ipc/  rust/  web/  scripts/         # RustCore Demo 专用，必须放在 ios-lab/ 之外
```

> `ios-lab/` 是 `PBXFileSystemSynchronizedRootGroup`：目录下的文件（含子目录）由
> Xcode 自动收编，新增 Demo 不需要改 `project.pbxproj`。子目录在打包时会被**摊平**，
> 所以资源（如 `RustCoreUI.html`）在 bundle 根目录即可被 `Bundle.main.url(forResource:)`
> 取到。反过来，`node_modules`、`target` 这类构建目录绝对不能放进去。

## 如何添加新的 Demo

1. 在 `ios-lab/` 下新建一个文件夹（如 `MyFeature/`），把该 Demo 的所有文件集中放进去。
2. 新建一个 SwiftUI 视图文件，例如 `MyFeatureView.swift`。
3. 在 `ContentView` 的 Demo 列表中登记一个条目（标题 + 目标视图）。
4. 实现该 Demo 视图的 `body`，并为其添加 `#Preview` 以便单独预览。

## 现有 Demo

| Demo | 文件夹 | 说明 |
| ---- | ------ | ---- |
| 镭射闪光卡片 | `HolographicCard/`（`HolographicCardView.swift` + `HolographicFoil.metal`） | 全息镭射卡片，Metal shader 渲染极光/银彩/虹箔箔面与闪粉星光，另有珠光全息收藏卡样式；跟随陀螺仪或拖拽流动，甩动可翻转 |
| 卷带槽元素复刻 | `WindingSlotElements/`（`WindingSlotElementsView.swift`） | 复刻参考图中卷带槽、滑块条、导向线等素材元素的静态外观 |
| RustCore 跨端架构 | `RustCore/`（`RustCoreLabView.swift` 等，见下节） | 对标 Raycast 2.0 的三层架构最小实践：SwiftUI 壳 → WKWebView(React) → Rust core，契约一处声明、三端生成 |
| App 内灵动岛 | `DynamicIsland/`（`InAppDynamicIsland.swift` + `InAppDynamicIslandView.swift`） | App 内绘制的模拟灵动岛组件，压在系统挖孔位置并描一圈红框；点灵动岛展开、点其他位置收起；页面开 `statusBarHidden(true)`，其他 App 的灵动岛会消失（见下节） |

### 灵动岛组件 `InAppDynamicIsland`

完整用法见 [ios-lab/DynamicIsland/Usage.md](ios-lab/DynamicIsland/Usage.md)。
注意子目录打包时会被摊平，这个 md 会以 `Usage.md` 落在 bundle 根目录——
别的 Demo 再放同名文件会撞车，要么换个名字，要么把文档挪到 `ios-lab/` 之外。

岛体本身是通用组件，只负责形态、尺寸、动画和命中，摆在屏幕什么位置由宿主决定：

```swift
InAppDynamicIsland(isExpanded: $isExpanded, metrics: metrics, ringColor: .red) {
    artwork          // leading：收起态贴挖孔左侧，展开态滑到岛体左上角
} trailing: {
    pauseButton      // trailing：同上，右侧
} expanded: {
    nowPlaying       // 只在展开态出现的主内容区，岛体高度随它自适应
}
```

三个区都有默认值 `EmptyView()`，可以只传需要的。尺寸走 `IslandMetrics`（挖孔宽高、两侧留白、
展开宽度与高度下限、描边、命中外扩），全部可运行时微调。

两处不能想当然的地方：

- **收起态左右必须等宽**。胶囊由宿主居中摆放，而真实挖孔恒定在屏幕正中，两侧不等宽的话
  中间留空区会整体偏移，挖孔就会压住较宽那侧的内容（实测偏了 5.8pt）。真实灵动岛的
  compact 形态同样绕挖孔对称。
- **宽高必须是具体数值**，不能在 `nil`（内在尺寸）和定值之间切换——那样不会补间只会跳变。
  所以三个自定义区各有一份隐藏副本当探针量自然尺寸，副本必须带 `.fixedSize()`，
  否则会被 `.background` 约束成宿主的尺寸。

### 灵动岛：怎么让**别的 App** 的岛消失

```swift
.statusBarHidden(true)
```

实测有效：本 App 在前台且状态栏隐藏时，其他 App 的 Live Activity 不会渲染在灵动岛上。

这是**渲染抑制**，不是结束活动——和「宿主 App 前台时系统自动隐藏自家活动」同一类机制，
离开页面自动恢复。代价是状态栏的时间/信号/电量一起没了。

Apple DTS 说的「没有 API 能 disable 别家的 Live Activity」字面上没错：你确实结束不了别人的活动，
但可以让系统在你前台时不画它。别被那句话劝退。

## RustCore 跨端架构实践

复刻 Raycast 2.0 的架构主张——**不是套原生壳的 web app，而是用 web 技术做 UI 的原生 app**。
完整介绍（功能、数据流、设计取舍、验证记录）见 [RUSTCORE.md](RUSTCORE.md)。

| 层 | 位置 | 职责 |
| -- | ---- | ---- |
| 原生壳 | `ios-lab/RustCore/RustCoreLabView.swift`、`RustCoreWebHost.swift`、`RustCore.swift` | 页面容器、WKWebView 托管、message handler 转发、C ABI 调用 |
| Web UI | `web/src/` → 构建成单文件 `ios-lab/RustCore/RustCoreUI.html` | React + TypeScript 写的搜索器，全部 UI 逻辑 |
| Rust core | `rust/rustcore/` → `librustcore.a` | 文件索引、模糊打分，持有全部状态 |
| **IPC 契约** | `ipc/schema.json` + `ipc/codegen.mjs` | 一处声明，生成 TS / Swift / Rust 三端类型化 client |

Raycast 桌面端在 WebView 与 Rust 之间还有一层长驻 **Node 进程**（数据库、扩展运行时）。
iOS 不允许 fork 子进程，那一层在这里缺席，UI 直接复用 Rust 数据层——这也是 Raycast
自家 iOS App 的做法。

改契约只需要动 `ipc/schema.json`，然后 `make ipc`；字段对不上时三端会同时编译报错。
生成物（`ios-lab/RustCore/RustCoreIPC.generated.swift`、`ios-lab/RustCore/RustCoreUI.html` 等）已提交进
仓库，只用 Xcode 打开也能直接编译。

```bash
make all     # codegen → cargo → vite，并把产物投递进 ios-lab/
make test    # Rust 单元测试
make app     # xcodebuild 模拟器构建
```

首次构建前需要 `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`。

## 开发约定

- 使用 **SwiftUI** 构建 UI。
- 每个 Demo 视图应保持自包含，避免相互耦合。
- 为每个 Demo 视图提供 `#Preview`，方便在 Xcode 中独立预览。
- 不要手改带 `@generated` 标记的文件，改 `ipc/schema.json` 后重新生成。
