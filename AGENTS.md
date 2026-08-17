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
├── Shatter/                        # Demo：视图碎裂（两种风格 × 两条渲染路线）
│   ├── Shared/                      # 两条路线共用，改这里两边一起变
│   │   ├── ShatterCore.h            #   着色核心：形态 + 配色（.metal 用相对路径 include）
│   │   ├── ShatterConfig.swift      #   风格枚举 + 参数 + ShatterConfig
│   │   └── ShatterModel.swift       #   时间线、破裂点与行程、液滴分布、Color 小工具
│   ├── SwiftUI/
│   │   ├── ShatterModifier.swift    #   .shatter() 修饰器 + Canvas 液滴
│   │   ├── SoapFilm.metal           #   stitchable 入口：肥皂泡膜
│   │   ├── InkSplat.metal           #   stitchable 入口：斯普拉遁式墨水喷射
│   │   └── ShatterView.swift        #   Demo 页
│   └── UIKit/
│       ├── UIKitShatter.swift       #   快照 + CAMetalLayer + UIView.shatter()
│       ├── UIKitShatterKernels.metal #  全屏三角形 + 实例化液滴
│       └── UIKitShatterView.swift   #   Demo 页
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
| 视图碎裂（SwiftUI） | `Shatter/SwiftUI/` | 点哪儿从哪儿碎，两种风格可切换：皂膜（薄膜干涉 + 孔洞扩张）和墨水（斯普拉遁式喷射）；见下节 |
| 视图碎裂（UIKit） | `Shatter/UIKit/` | 同样两种风格，但作用在**真的 UIKit 控件**上。SwiftUI 那条路对 UIKit 是失效的，必须另起一套；见下节 |

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

### 碎裂组件 `.shatter()`

```swift
card
    .clipShape(RoundedRectangle(cornerRadius: 26))   // 圆角要和 config.cornerRadius 对上
    .shatterOnTap(isShattered: $gone, config: config)  // 从手指点到的那一点开始崩解
    // 或 .shatter(isShattered:config:onFinished:)     // 程序触发，起点按 seed 随机
```

视图**不会先变形**：它保持自己的形状，起手 → 前沿扫过 → 喷溅，一气呵成。
`ShatterConfig.style` 切换风格，通用参数（时长、液滴数、重力）在顶层，
风格专属参数分别在 `.film` 和 `.ink` 里。

| 风格 | 形态 |
| ---- | ---- |
| `.soapFilm` | 视图是一层皂膜，穿孔后孔洞沿膜面扩张，卷边退缩，喷出近白的水光 |
| `.inkSplat` | 一道有机的墨线扫过视图，糊上不透明的墨，整块消失，喷出圆疙瘩状墨点 |

两种风格共用同一套时间线、破裂点和液滴系统，只有逐像素的形态和液滴的画法不同。
液滴永远画在一层覆盖层上 —— 它们要飞出视图边界，主 shader 画不了。

**皂膜**几个不能想当然的点：

- **膜不是平板**。由圆角矩形 SDF 生成一圈球冠高度场（`h = sqrt(1-s²)`，`s` 由到边缘的
  归一化距离得来），只在靠边 `domeDepth` 的一圈里弯，中间保持全平、内容不失真。
  掠射角在那一圈迅速抬高，菲涅尔和高光才有地方落。
- **膜厚驱动一切颜色**。反射强度 ∝ sin²(π·2nd·cosθ/λ)，三个波长采样即可。
  卷边处厚度乘 4.5 倍，那道亮环是白送的。
- **膜厚在空间上的跨度必须压在一个干涉周期以内**（Δd = λ/2n ≈ 166 nm）。这一条是踩了坑
  才知道的：跨度大了等厚线会密集成干涉条纹，而膜中间是平的、厚度又是 y 的线性斜坡，
  等厚线于是恰好是**笔直的轴对齐直线**，看起来就像画错了一个矩形。它是真实的干涉条纹，
  不是数值 bug，查了半天 SDF、噪声、`maxSampleOffset` 全是白查。
  排查手法记一下：把中间量（`turb` / 掠射角 / 厚度）直接当颜色输出，再逐像素扫二阶差分，
  比盯着截图猜快得多。

**墨水**（斯普拉遁）抓形全在「边界不能是圆」：

- **角向瓣**。轮廓上叠 3/5/7 次低频正弦，出来才是几团圆疙瘩粘在一起，不是光滑的圆。
- **提前甩出去的散墨**。抖动网格上藏一颗颗墨点，前沿逼近到 `speckleLead` 以内就「啪」地出现。
  少了这一步，边界再有机也只像是「擦除」，不像「喷射」。
- **边缘必须硬**。皂膜靠柔和渐变出效果，墨正相反：卡通墨迹是实心色块 + 干脆轮廓，
  过渡给 1px 就够，一软立刻变成烟雾。液滴同理 —— 不透明、不叠加混合、快到寿命尽头才收缩。
- **墨点的拖尾要短**。皂膜靠长拖尾做运动模糊，墨点拖长了就成一根根胶囊，
  必须是圆疙瘩带一点点尾巴，再挂一两颗卫星小点。

两边都适用：

- **前沿的行程按起点到最远那个角来算**，shader 和液滴 Canvas 必须用同一个公式（`frontReach`），
  否则液滴的出生时刻和前沿的位置对不上。半径随时间线性增长（皂膜那边对应 Taylor–Culick）。
- **液滴尺寸要走幂律**，均匀分布会让喷溅看起来像撒了一把药丸。
- **别放进会裁剪的容器**（ScrollView / List / `.clipped()`），液滴会被切掉。UIKit 版同理，
  特效层是插进 `superview` 的，宿主链上任何 `clipsToBounds` 都会切掉喷溅。

### UIKit 版：`UIView.shatter()`

```swift
let point = gesture.location(in: card)
card.shatter(config: config, at: point) {
    card.isHidden = false     // 回调时自己仍是 isHidden = true，要复原自行置回
}
```

**SwiftUI 那套对 UIKit 是直接失效的，不是效果差一点。** `layerEffect` 要把宿主
光栅化成纹理，而 UIKit 托管的图层由系统单独合成，SwiftUI 栅格不到：给
`UIViewRepresentable` 套上 `.shatter()` 之后，UIKit 内容会被替换成黄底 🚫
「无法渲染」占位符 —— **而且 `isEnabled: false` 也一样**，挂上去就废，
没法「平时挂着、需要时才启用」。

所以 UIKit 走自己的一条渲染路线：`drawHierarchy` 截图 → 传成 MTLTexture →
在目标上方盖一层 `CAMetalLayer`，`CADisplayLink` 驱动。液滴不再逐帧 CPU 画，
而是实例化四边形，参数一次性传上 GPU，之后每帧只更新一个时间标量。

两条路线**共用 `Shared/`**：`ShatterCore.h` 里逐像素的形态与配色只有一份，各自的入口
只负责「参数怎么传」和「内容从哪儿采样」；`ShatterConfig.swift` / `ShatterModel.swift`
里的参数、时间线、破裂点、液滴分布也是同一份，所以两边观感一致。

`.metal` 跨目录用相对路径包含共用头（`#include "../Shared/ShatterCore.h"`），
不需要给 target 配 header search path。

UIKit 这条路踩到的两个坑：

- **`UIGraphicsImageRendererFormat.preferred()` 在广色域设备上给的是 16 位扩展范围位图**，
  那种 CGImage 喂不进纹理，整条链路**静默失败**，表现就是「点了没反应」。
  要么锁 `format.preferredRange = .standard`，要么像现在这样自己画进
  rgba8/预乘/deviceRGB 的位图再上传，别让 `MTKTextureLoader` 去猜格式。
- **别给 CGBitmapContext 加翻转**。它的用户坐标系原点虽然在左下，但内存里第 0 行本来
  就对应图像顶部，直接 `draw` 出来就是 Metal 要的左上原点。多翻一次的结果是整张快照
  上下颠倒 —— 内容一眼能看出来，但很容易先怀疑到 uv 上去。

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
