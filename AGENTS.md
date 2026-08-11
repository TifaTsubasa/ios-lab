# ios-lab

一个用于收集和展示各类 SwiftUI / iOS 实验 Demo 的示例项目。

## 项目作用

本项目作为一个 **Demo 合集**，提供统一的入口来浏览和体验各个独立的实验页面。

- **主页**是一个列表（`ContentView`），列出所有可用的 Demo。
- **点击列表项**即可导航进入对应的 Demo 详情页。

每个 Demo 都是自包含的 SwiftUI 视图，互不依赖，方便单独编写、预览与调试。

## 目录结构

```
ios-lab/
├── ios_labApp.swift          # App 入口
├── ContentView.swift         # 主页：Demo 列表
└── <DemoName>View.swift      # 各个独立的 Demo 视图
```

## 如何添加新的 Demo

1. 新建一个 SwiftUI 视图文件，例如 `MyFeatureView.swift`。
2. 在 `ContentView` 的 Demo 列表中登记一个条目（标题 + 目标视图）。
3. 实现该 Demo 视图的 `body`，并为其添加 `#Preview` 以便单独预览。

## 现有 Demo

| Demo | 文件 | 说明 |
| ---- | ---- | ---- |
| 卷带槽元素复刻 | `WindingSlotElementsView.swift` | 复刻参考图中卷带槽、滑块条、导向线等素材元素的静态外观 |

## 开发约定

- 使用 **SwiftUI** 构建 UI。
- 每个 Demo 视图应保持自包含，避免相互耦合。
- 为每个 Demo 视图提供 `#Preview`，方便在 Xcode 中独立预览。
