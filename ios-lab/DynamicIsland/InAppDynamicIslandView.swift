//
//  InAppDynamicIslandView.swift
//  ios-lab
//
//  App 内灵动岛：在挖孔坐标处画一个纯黑胶囊压住系统灵动岛，外圈描一圈红色边框。
//  系统灵动岛由系统在所有 App 之上的图层渲染，App 画不上去，只能靠「黑对黑」融为一体。
//
//  让**别的 App** 的 Live Activity 从岛上消失，靠的是 `.statusBarHidden(true)`——
//  实测有效，活动本身没被结束，只是本页面在前台时系统不渲染它，离开页面自动恢复。
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - 主视图

struct InAppDynamicIslandView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var phase: IslandPhase = .collapsed
    @State private var metrics = IslandMetrics()
    /// 默认白底：黑胶囊和真实挖孔在白色上对比最强，一眼能看出有没有对齐。
    @State private var useDarkBackground = false
    @State private var showTuning = false

    private var foreground: Color { useDarkBackground ? .white : Color(red: 0.11, green: 0.10, blue: 0.13) }

    var body: some View {
        ZStack(alignment: .top) {
            background

            infoScroll

            // 展开后铺满全屏的透明层：点岛体以外的任何位置都收起。
            if phase == .expanded {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { setPhase(.collapsed) }
            }

            islandLayer
        }
        // 让别的 App 的 Live Activity 从灵动岛上消失。作用范围仅限本页面，退出即恢复。
        .statusBarHidden(true)
        // 导航栏会画在岛体之上、返回按钮正好压住展开态，这里整条隐藏，改用页面内的返回按钮。
        .toolbar(.hidden, for: .navigationBar)
    }

    private var background: some View {
        Group {
            if useDarkBackground {
                Color(red: 0.05, green: 0.04, blue: 0.07)
            } else {
                Color.white
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 灵动岛图层

    /// 独立铺满全屏（含安全区）的一层，只承载岛体本身，保证它压在页面最上方。
    private var islandLayer: some View {
        ZStack(alignment: .top) {
            // 实测：屏幕顶部约 54pt（状态栏整条）收不到触摸，系统图层在 App 之上把点击吃掉了。
            // 岛体 13.5~50.8pt 整个落在这条死区里，怎么点都没反应，所以用一条从屏幕顶端
            // 向下延伸进活动区的带子接管「点击展开」。
            if phase == .collapsed {
                Color.clear
                    .frame(height: metrics.tapBandHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { setPhase(.expanded) }
            }

            VStack(spacing: 0) {
                island
                    .padding(.top, metrics.topInset)
                Spacer(minLength: 0)
            }
        }
        .ignoresSafeArea()
    }

    private var island: some View {
        let size = metrics.size(for: phase)
        let radius = metrics.cornerRadius(for: phase)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let ringInset = metrics.ringGap + metrics.ringWidth

        let hitInset = ringInset + metrics.hitSlop

        return expandedContent
            .opacity(phase == .expanded ? 1 : 0)
            .frame(width: size.width, height: size.height)
        .background(Color.black, in: shape)
        .clipShape(shape)
        .overlay {
            RoundedRectangle(cornerRadius: radius + ringInset, style: .continuous)
                .strokeBorder(Color.red, lineWidth: metrics.ringWidth)
                .frame(width: size.width + ringInset * 2,
                       height: size.height + ringInset * 2)
        }
        // 挖孔本身那一小块屏幕收不到触摸（系统状态栏图层在 App 之上），
        // 所以点击热区要比胶囊大一圈，让手指落在挖孔边缘也能命中。
        .overlay {
            RoundedRectangle(cornerRadius: radius + hitInset, style: .continuous)
                .fill(.clear)
                .contentShape(RoundedRectangle(cornerRadius: radius + hitInset, style: .continuous))
                .frame(width: size.width + hitInset * 2,
                       height: size.height + hitInset * 2)
                .onTapGesture { setPhase(phase == .collapsed ? .expanded : .collapsed) }
        }
    }

    /// 展开态：顶部整条留空，同时避开挖孔和系统状态栏（时间、信号、电量都画在 App 之上）。
    private var expandedContent: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: metrics.collapsedHeight)

            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color(red: 0.98, green: 0.45, blue: 0.32),
                                                Color(red: 0.62, green: 0.24, blue: 0.72)],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    )
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("App 内灵动岛")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("ios-lab · 正在播放")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer(minLength: 0)

                Image(systemName: "pause.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Text("1:12")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))

                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.white)
                                .frame(width: proxy.size.width * 0.34, height: 4)
                        }
                    }

                Text("3:40")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .frame(width: metrics.expandedWidth)
    }

    private func setPhase(_ next: IslandPhase) {
        guard next != phase else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
            phase = next
        }
    }

    // MARK: - 页面说明与控制

    private var infoScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                backButton

                if !DeviceProbe.hasDynamicIsland {
                    hintCard(symbol: "iphone.gen2",
                             text: "当前设备没有灵动岛，上方为模拟位置，仅供查看外观。")
                }

                usageCard

                explanationCard

                Toggle("深色背景", isOn: $useDarkBackground)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(foreground)
                    .tint(Color(red: 0.98, green: 0.45, blue: 0.32))
                    .padding(.horizontal, 4)

                tuningSection
            }
            .padding(.horizontal, 20)
            // 让出展开态灵动岛的高度，避免内容被压在下面。
            .padding(.top, 120)
            .padding(.bottom, 40)
        }
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Label("ios-lab", systemImage: "chevron.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(foreground.opacity(0.75))
        }
        .buttonStyle(.plain)
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(phase == .collapsed ? "点一下上方的灵动岛展开" : "点击岛体以外的任何位置收起")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(foreground)
                    .contentTransition(.opacity)
            } icon: {
                Image(systemName: phase == .collapsed ? "hand.tap" : "arrow.down.right.and.arrow.up.left")
                    .foregroundStyle(Color(red: 0.98, green: 0.45, blue: 0.32))
            }

            if phase == .collapsed {
                Text("屏幕顶部约 54pt 是系统触摸死区，岛体整个落在里面、点不到，所以热区向下延伸到了死区之外。")
                    .font(.system(size: 12))
                    .foregroundStyle(foreground.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(foreground.opacity(0.06))
        )
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这个岛是 App 画的")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foreground)

            Text("系统灵动岛渲染在所有 App 之上，App 无法真正盖住它。这里在挖孔坐标处画了一个纯黑胶囊，黑对黑视觉上与挖孔融为一体，红框描在胶囊外侧，真实挖孔正好落在红框里面。")
                .font(.system(size: 12))
                .foregroundStyle(foreground.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            Text("本页面开了 statusBarHidden(true)，所以其他 App 的 Live Activity 此刻不会渲染在岛上——活动没被结束，退出页面就恢复。")
                .font(.system(size: 12))
                .foregroundStyle(foreground.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(foreground.opacity(0.06))
        )
    }

    private var tuningSection: some View {
        DisclosureGroup(isExpanded: $showTuning) {
            VStack(spacing: 14) {
                tuningSlider(title: "宽度", value: $metrics.collapsedWidth, range: 100...160)
                tuningSlider(title: "高度", value: $metrics.collapsedHeight, range: 28...50)
                tuningSlider(title: "顶部距离", value: $metrics.topInset, range: 0...30)
                tuningSlider(title: "红框间距", value: $metrics.ringGap, range: 0...12)

                Button("恢复默认") {
                    withAnimation(.snappy) { metrics = IslandMetrics() }
                }
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)
        } label: {
            Text("微调（对齐挖孔）")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(foreground)
        }
        .tint(foreground.opacity(0.6))
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(foreground.opacity(0.06))
        )
    }

    private func tuningSlider(title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.6))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(foreground.opacity(0.4))
            }

            Slider(value: value, in: range)
                .tint(Color(red: 0.98, green: 0.45, blue: 0.32))
        }
    }

    private func hintCard(symbol: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(foreground.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

// MARK: - 形态

/// 模拟灵动岛的两种形态：收起、展开。
private enum IslandPhase {
    case collapsed, expanded
}

// MARK: - 尺寸

/// 灵动岛几何没有公开 API 可取，这里用 iPhone 14 Pro 之后机型的实测值，并允许运行时微调。
private struct IslandMetrics {
    var collapsedWidth: CGFloat = 126
    var collapsedHeight: CGFloat = 37.33
    /// 在 iPhone 17 Pro 模拟器上量出来的实际值，比常见的 11 略低；不同机型可用下方微调对齐。
    var topInset: CGFloat = 13.5
    var ringGap: CGFloat = 3
    var ringWidth: CGFloat = 2
    /// 点击热区在红框之外再外扩的距离。
    var hitSlop: CGFloat = 14
    /// 收起态「点击展开」的热区高度，从屏幕顶端算起，必须越过约 54pt 的状态栏触摸死区。
    var tapBandHeight: CGFloat = 140

    var expandedWidth: CGFloat = 371
    var expandedHeight: CGFloat = 160
    var expandedCornerRadius: CGFloat = 44

    func size(for phase: IslandPhase) -> CGSize {
        switch phase {
        case .collapsed: return CGSize(width: collapsedWidth, height: collapsedHeight)
        case .expanded: return CGSize(width: expandedWidth, height: expandedHeight)
        }
    }

    func cornerRadius(for phase: IslandPhase) -> CGFloat {
        switch phase {
        case .collapsed: return collapsedHeight / 2
        case .expanded: return expandedCornerRadius
        }
    }
}

// MARK: - 设备探测

private enum DeviceProbe {
    /// 用安全区顶部高度粗略判断当前 iPhone 是否带灵动岛。
    static var hasDynamicIsland: Bool {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let top = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .compactMap { $0.keyWindow?.safeAreaInsets.top }
            .max() ?? 0
        return top >= 51
        #else
        return false
        #endif
    }
}

#Preview("App 内灵动岛") {
    NavigationStack {
        InAppDynamicIslandView()
    }
}
