# InAppDynamicIsland 使用指南

App 内绘制的模拟灵动岛组件。系统灵动岛渲染在所有 App 之上，App 画不上去，
这个组件的做法是**在挖孔坐标处画一个纯黑胶囊**，靠「黑对黑」和真实挖孔融为一体，
再把你的内容排在挖孔两侧和下方。

组件只负责岛体本身（形态、尺寸、动画、命中），**摆在屏幕什么位置由宿主决定**。

- 组件：`InAppDynamicIsland.swift`
- 用法示例：`InAppDynamicIslandView.swift`（Demo 页，做了个假的音乐播放器）

## 一分钟上手

```swift
struct MyPage: View {
    @State private var isExpanded = false
    private let metrics = IslandMetrics()

    var body: some View {
        ZStack(alignment: .top) {
            myContent

            // 岛体单独一层铺满全屏（含安全区），保证压在页面最上方
            VStack(spacing: 0) {
                InAppDynamicIsland(isExpanded: $isExpanded, metrics: metrics) {
                    Image(systemName: "phone.fill").foregroundStyle(.green)
                } trailing: {
                    Text("12:04").foregroundStyle(.green)
                } expanded: {
                    Text("通话中").foregroundStyle(.white).padding(20)
                }
                .padding(.top, metrics.topInset)

                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
        }
    }
}
```

三个视图区都有默认值 `EmptyView()`，可以只传需要的：

```swift
// 只要一个能展开的纯黑胶囊
InAppDynamicIsland(isExpanded: $isExpanded)

// 只要收起态的左右指示器
InAppDynamicIsland(isExpanded: $isExpanded) {
    Circle().fill(.green).frame(width: 20, height: 20)
} trailing: {
    Text("REC")
}
```

## 三个自定义视图区

```
收起态（胶囊宽 = 2 × 侧区宽 + notchWidth）
        ┌────────────────────────────────────┐
        │ [leading] ····挖孔留空···· [trailing] │
        └────────────────────────────────────┘
                     ↑ 真实挖孔恒在屏幕正中

展开态（宽 expandedWidth，高随主内容自适应）
   ┌──────────────────────────────────────────────┐
   │ [leading]      ····挖孔留空····     [trailing] │  ← 高 notchHeight
   │                                              │
   │  expanded：主内容区，岛体高度由它撑出            │
   └──────────────────────────────────────────────┘
```

| 区 | 收起态 | 展开态 |
| --- | --- | --- |
| `leading` | 贴挖孔左侧，在定宽盒子里居中 | 滑到岛体左上角，距边缘 `expandedSideInset` |
| `trailing` | 贴挖孔右侧，同上 | 滑到岛体右上角 |
| `expanded` | 不可见（`opacity` 0，被裁掉） | 挖孔行下方的主内容区，**决定岛体高度** |

收起 → 展开是同一个 `HStack` 的形变（保持视图 identity），左右内容会连贯地从「贴着挖孔」
滑到「贴着两侧边缘」，不是两套视图的淡入淡出。

## API

```swift
InAppDynamicIsland(
    isExpanded: Binding<Bool>,               // 形态由外部持有，也可以代码驱动展开
    metrics: IslandMetrics = IslandMetrics(),
    ringColor: Color? = nil,                 // 对齐挖孔用的调试描边，nil 不画
    animation: Animation = .spring(response: 0.42, dampingFraction: 0.72),
    leading: () -> Leading = { EmptyView() },
    trailing: () -> Trailing = { EmptyView() },
    expanded: () -> Expanded = { EmptyView() }
)
```

`IslandMetrics` 的字段全部可变，改一个值就能跑，也可以接滑块运行时微调：

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `notchWidth` | 126 | 挖孔宽度，收起态中间恒定留空的那一段 |
| `notchHeight` | 37.33 | 挖孔高度 = 收起态胶囊高度 |
| `topInset` | 13.5 | 距屏幕顶部的距离。**组件不消费，留给宿主定位** |
| `compactSideInset` | 10 | 收起态左右内容周围的留白（内容居中，两侧各一份） |
| `expandedSideInset` | 22 | 展开态左右内容与岛体边缘的留白 |
| `expandedWidth` | 371 | 展开态宽度 |
| `expandedMinHeight` | 120 | 展开态高度下限，实际取它与内容自适应值的较大者 |
| `expandedCornerRadius` | 44 | 展开态圆角（收起态恒为 `notchHeight / 2`） |
| `ringGap` / `ringWidth` | 3 / 2 | 调试描边与胶囊的间距、线宽 |
| `hitSlop` | 14 | 点击热区在描边之外再外扩的距离 |

## 宿主要做的三件事

```swift
ZStack(alignment: .top) {
    pageContent

    // ① 展开后铺满全屏的透明层：点岛体以外任何位置收起
    if isExpanded {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .onTapGesture { isExpanded = false }
    }

    islandLayer   // ② 岛体层放在最后，压在最上方
}
.statusBarHidden(true)                      // ③ 见下
.toolbar(.hidden, for: .navigationBar)      // 导航栏会画在岛体之上，整条隐藏
```

**② 岛体必须单独成层**：`VStack { island; Spacer() }.ignoresSafeArea()`，
否则会被安全区推下去、或者被页面内容盖住。

**③ `.statusBarHidden(true)`**：本 App 前台且状态栏隐藏时，**其他 App 的 Live Activity
不会渲染在灵动岛上**。这是渲染抑制不是结束活动，离开页面自动恢复。
代价是状态栏的时间/信号/电量一起没了。想让自己画的岛干净地占住挖孔，基本得开。

## 必须知道的约束

**收起态左右强制等宽。** 胶囊由宿主居中摆放，而真实挖孔恒定在屏幕正中；两侧不等宽的话，
中间留空区会整体偏移，挖孔就会压住较宽那侧的内容（实测偏过 5.8pt）。
所以两侧统一取 `max(leadingWidth, trailingWidth)`——真实灵动岛的 compact 形态也是绕挖孔对称的。
副作用：一侧内容明显更宽时，另一侧看起来会「留白偏多」，这是正确行为。

**展开态单侧别超过 `(expandedWidth - notchWidth) / 2`**（默认 122.5pt），否则会盖住挖孔。

**自定义区里的 Button 点不到。** 点击热区是盖在整个岛体之上的一层，任何位置的点击都被它
接走用来切换形态。需要区内独立交互得自己改造热区。

**自定义区会被渲染两份。** 组件用隐藏副本当探针量自然尺寸（见下），所以别在区里放
带副作用、或者开销很大的视图。

**两侧都为空时胶囊精确等于 `notchWidth × notchHeight`**，这是校准基准：
传 `ringColor: .red` 打开描边，真实挖孔应该严丝合缝落在红框里面。

## 为什么要用隐藏探针量尺寸

组件的宽高必须**始终是具体数值**——在 `nil`（内在尺寸）和定值之间切换不会补间、只会跳变，
展开动画就废了。所以三个自定义区各渲染一份隐藏副本放在 `.background` 里量自然尺寸：

- 副本必须带 `.fixedSize()`，否则会被 `.background` 约束成宿主的尺寸，量到的是宿主自己的大小
- 部署目标 iOS 17.6，用不了 iOS 18 的 `onGeometryChange`，走的是 `GeometryReader` + `onChange(initial:)`

改这块代码时留意这两点，很容易改出「首帧闪一下」或「展开时高度跳变」。

## 对齐不同机型的挖孔

灵动岛几何没有公开 API，默认值是 iPhone 17 Pro 模拟器上量出来的。换机型如果对不齐，
调 `topInset` 和 `notchWidth` / `notchHeight`——Demo 页的「微调（对齐挖孔）」折叠区
就是几个绑到 `IslandMetrics` 的滑块，照抄即可。

判断当前设备有没有灵动岛可以用安全区顶部高度粗判（`safeAreaInsets.top >= 51`），
Demo 页的 `DeviceProbe` 是现成实现。

## 实测数据（iPhone 17 Pro 模拟器，默认参数 + 26pt 封面 / 14.3pt 暂停键）

| | 收起态 | 展开态 |
| --- | --- | --- |
| 尺寸 | 218 × 37.00pt（126 + 2×46） | 370.33 × 125.67pt |
| 水平中心 | 201.00pt（屏幕中心 201.00pt） | 201.17pt |
| 顶部 | 13.67pt | 13.67pt |
| 内容位置 | 两侧 46pt 盒子内居中，挖孔区 138→264 全空 | 封面距左缘 21.7pt |

展开高度是主内容撑出来的，换内容会跟着变；点岛外收起精确回到 218 × 37。
