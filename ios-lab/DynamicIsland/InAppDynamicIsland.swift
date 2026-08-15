//
//  InAppDynamicIsland.swift
//  ios-lab
//
//  可复用的「App 内灵动岛」组件。
//
//  系统灵动岛渲染在所有 App 之上，App 画不上去，只能在挖孔坐标处画一个纯黑胶囊，
//  靠「黑对黑」视觉上与挖孔融为一体。本组件只负责岛体本身（形态、尺寸、动画、命中），
//  摆在屏幕什么位置由宿主决定（`IslandMetrics.topInset` 是留给宿主定位用的）。
//
//  三个自定义视图区，对应真实灵动岛的 compact / expanded 布局：
//  - leading / trailing：收起态贴着挖孔两侧（胶囊随内容变宽），展开态滑到岛体左右边缘
//  - expanded：只在展开态出现的主内容区，岛体高度随它自适应
//

import SwiftUI

// MARK: - 组件

struct InAppDynamicIsland<Leading: View, Trailing: View, Expanded: View>: View {
    @Binding private var isExpanded: Bool

    private let metrics: IslandMetrics
    /// 对齐挖孔用的调试描边，描在黑胶囊外侧；nil 表示不画。
    private let ringColor: Color?
    private let animation: Animation

    private let leading: Leading
    private let trailing: Trailing
    private let expanded: Expanded

    /// 左右自定义区各自的自然宽度，由探针量出。
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    /// 展开态主内容区的自然高度，由探针量出。
    @State private var expandedContentHeight: CGFloat = 0

    init(isExpanded: Binding<Bool>,
         metrics: IslandMetrics = IslandMetrics(),
         ringColor: Color? = nil,
         animation: Animation = .spring(response: 0.42, dampingFraction: 0.72),
         @ViewBuilder leading: () -> Leading = { EmptyView() },
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder expanded: () -> Expanded = { EmptyView() }) {
        _isExpanded = isExpanded
        self.metrics = metrics
        self.ringColor = ringColor
        self.animation = animation
        self.leading = leading()
        self.trailing = trailing()
        self.expanded = expanded()
    }

    var body: some View {
        let radius = metrics.cornerRadius(isExpanded: isExpanded)
        let ringInset = metrics.ringGap + metrics.ringWidth
        let hitInset = ringInset + metrics.hitSlop
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let ringShape = RoundedRectangle(cornerRadius: radius + ringInset, style: .continuous)
        let hitShape = RoundedRectangle(cornerRadius: radius + hitInset, style: .continuous)

        return VStack(spacing: 0) {
            topRow(expanded: isExpanded)

            // 固定按展开宽度布局，收起时靠外层 frame 裁掉；否则动画途中文字会不断重排。
            expanded
                .frame(width: metrics.expandedWidth)
                .opacity(isExpanded ? 1 : 0)
        }
        .frame(width: currentWidth, height: currentHeight, alignment: .top)
        // 黑胶囊和描边都用真正的 Shape 视图 + 负 padding 外扩：半径走同一套 animatableData，
        // 尺寸直接来自胶囊动画后的实际布局，展开/收起过程中两者才不会错开。
        .background { shape.fill(Color.black) }
        .clipShape(shape)
        .background { probes }
        .overlay {
            if let ringColor {
                ringShape
                    .strokeBorder(ringColor, lineWidth: metrics.ringWidth)
                    .padding(-ringInset)
            }
        }
        // 点击热区比胶囊大一圈，手指落在边缘附近也能命中。
        // 注意热区盖在自定义区之上，自定义区里放 Button 是点不到的。
        .overlay {
            hitShape
                .fill(.clear)
                .contentShape(hitShape)
                .padding(-hitInset)
                .onTapGesture { isExpanded.toggle() }
        }
        .animation(animation, value: isExpanded)
    }

    // MARK: 布局

    /// 收起态与展开态共用同一个 HStack（保持视图 identity，形变才连贯）：
    /// 中间那块透明区收起时恰好是挖孔宽度、展开时撑满，于是左右内容自动从「贴着挖孔」
    /// 滑到「贴着两侧边缘」，正好对应真实灵动岛 compact → expanded 的行为。
    private func topRow(expanded isExpandedLayout: Bool) -> some View {
        HStack(spacing: 0) {
            side(leading, own: leadingWidth, expanded: isExpandedLayout)

            Color.clear
                .frame(minWidth: metrics.notchWidth,
                       maxWidth: isExpandedLayout ? .infinity : metrics.notchWidth)

            side(trailing, own: trailingWidth, expanded: isExpandedLayout)
        }
        .frame(height: metrics.notchHeight)
    }

    /// 左右区都装进一个定宽的透明盒子里居中。用 `Color.clear` 打底而不是直接给
    /// 自定义视图加 `.frame`，是因为某一侧传 `EmptyView` 时后者不一定会撑出宽度。
    private func side<Content: View>(_ content: Content, own: CGFloat, expanded isExpandedLayout: Bool) -> some View {
        Color.clear
            .frame(width: isExpandedLayout ? expandedSideWidth(own) : compactSideWidth,
                   height: metrics.notchHeight)
            .overlay { content }
    }

    /// 收起态两侧**必须等宽**：胶囊由宿主居中摆放，而真实挖孔恒定在屏幕正中，
    /// 两侧不等宽的话中间留空区就会整体偏移，挖孔会压住较宽那侧的内容。
    /// 真实灵动岛的 compact 形态同样是绕挖孔对称的。
    private var compactSideWidth: CGFloat {
        let content = max(leadingWidth, trailingWidth)
        // 两侧都为空时必须精确回到 0，否则收起态胶囊就对不上真实挖孔了。
        return content == 0 ? 0 : content + 2 * metrics.compactSideInset
    }

    /// 展开态两侧各自按自身宽度算，中间的弹性透明区把它们推向岛体左右边缘。
    /// 单侧宽度超过 `(expandedWidth - notchWidth) / 2` 就会盖住挖孔，注意别撑太宽。
    private func expandedSideWidth(_ own: CGFloat) -> CGFloat {
        own == 0 ? 0 : own + 2 * metrics.expandedSideInset
    }

    private var currentWidth: CGFloat {
        isExpanded ? metrics.expandedWidth : metrics.notchWidth + 2 * compactSideWidth
    }

    private var currentHeight: CGFloat {
        guard isExpanded else { return metrics.notchHeight }
        return max(metrics.expandedMinHeight, metrics.notchHeight + expandedContentHeight)
    }

    private var hasLeading: Bool { Leading.self != EmptyView.self }
    private var hasTrailing: Bool { Trailing.self != EmptyView.self }

    // MARK: 尺寸探针

    /// `currentWidth` / `currentHeight` 必须始终是具体数值：在 nil（内在尺寸）和定值之间
    /// 切换不会补间，只会跳变。所以把三个自定义区各渲染一份隐藏副本量出自然尺寸。
    /// 放在 `.background` 里所以不占主布局；`.fixedSize()` 不能省，
    /// 否则副本会被约束成宿主的尺寸，量出来的就是宿主自己的大小。
    private var probes: some View {
        ZStack {
            if hasLeading {
                leading
                    .fixedSize()
                    .background { SizeReader { leadingWidth = $0.width } }
            }

            if hasTrailing {
                trailing
                    .fixedSize()
                    .background { SizeReader { trailingWidth = $0.width } }
            }

            expanded
                .frame(width: metrics.expandedWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background { SizeReader { expandedContentHeight = $0.height } }
        }
        .hidden()
        .allowsHitTesting(false)
    }
}

// MARK: - 尺寸

/// 灵动岛几何没有公开 API 可取，这里用 iPhone 14 Pro 之后机型的实测值，并允许运行时微调。
struct IslandMetrics {
    /// 挖孔宽度：收起态中间恒定留空的那一段，左右自定义区排在它两侧。
    var notchWidth: CGFloat = 126
    /// 挖孔高度，也就是收起态胶囊的高度。
    var notchHeight: CGFloat = 37.33
    /// 距屏幕顶部的距离。组件本身不消费，留给宿主定位岛体。
    /// 在 iPhone 17 Pro 模拟器上量出来的实际值，比常见的 11 略低。
    var topInset: CGFloat = 13.5

    /// 收起态左右内容周围的留白（内容居中，两侧各一份）：既是与挖孔之间的空隙，
    /// 也是与胶囊边缘之间的空隙。该侧为空时不生效。
    var compactSideInset: CGFloat = 10
    /// 展开态左右内容与岛体边缘之间的留白。
    var expandedSideInset: CGFloat = 22

    var expandedWidth: CGFloat = 371
    /// 展开态高度下限；实际高度取主内容自适应后的值与它的较大者。
    var expandedMinHeight: CGFloat = 120
    var expandedCornerRadius: CGFloat = 44

    /// 描边与胶囊之间的间距、描边线宽。
    var ringGap: CGFloat = 3
    var ringWidth: CGFloat = 2
    /// 点击热区在描边之外再外扩的距离。
    var hitSlop: CGFloat = 14

    func cornerRadius(isExpanded: Bool) -> CGFloat {
        isExpanded ? expandedCornerRadius : notchHeight / 2
    }
}

// MARK: - 工具

/// 读出宿主视图自然尺寸的探针，自身不参与布局（放进 `.background`）。
private struct SizeReader: View {
    let onChange: (CGSize) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size, initial: true) { _, size in onChange(size) }
        }
    }
}

// MARK: - 预览

#Preview("三区全空") {
    // 胶囊必须恰好是 126 × 37.33，红框严丝合缝套住挖孔。
    IslandPreviewStage {
        InAppDynamicIsland(isExpanded: $0, ringColor: .red)
    }
}

#Preview("只有左右区") {
    IslandPreviewStage { isExpanded in
        InAppDynamicIsland(isExpanded: isExpanded, ringColor: .red) {
            Circle()
                .fill(.green)
                .frame(width: 20, height: 20)
        } trailing: {
            Text("12:04")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.green)
        }
    }
}

#Preview("三区齐全") {
    IslandPreviewStage { isExpanded in
        InAppDynamicIsland(isExpanded: isExpanded, ringColor: .red) {
            Image(systemName: "phone.fill")
                .font(.system(size: 15))
                .foregroundStyle(.green)
        } trailing: {
            Image(systemName: "waveform")
                .font(.system(size: 15))
                .foregroundStyle(.green)
        } expanded: {
            VStack(spacing: 6) {
                Text("主内容区高度自适应")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("换成更高或更矮的内容，岛体跟着变")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
    }
}

/// 预览用的台子：白底 + 顶部定位，点岛体展开/收起。
private struct IslandPreviewStage<Island: View>: View {
    @ViewBuilder let island: (Binding<Bool>) -> Island
    @State private var isExpanded = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                island($isExpanded)
                    .padding(.top, IslandMetrics().topInset)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
        }
        .statusBarHidden(true)
    }
}
