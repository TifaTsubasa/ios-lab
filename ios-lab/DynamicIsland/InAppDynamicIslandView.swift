//
//  InAppDynamicIslandView.swift
//  ios-lab
//
//  App 内灵动岛 Demo：把 `InAppDynamicIsland` 组件摆在挖孔坐标处，外圈描一圈红色边框对齐。
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

    @State private var isExpanded = false
    @State private var metrics = IslandMetrics()
    /// 默认白底：黑胶囊和真实挖孔在白色上对比最强，一眼能看出有没有对齐。
    @State private var useDarkBackground = false
    @State private var showTuning = false

    private var foreground: Color { useDarkBackground ? .white : Color(red: 0.11, green: 0.10, blue: 0.13) }
    private let accent = Color(red: 0.98, green: 0.45, blue: 0.32)

    var body: some View {
        ZStack(alignment: .top) {
            background

            infoScroll

            // 展开后铺满全屏的透明层：点岛体以外的任何位置都收起。
            if isExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { isExpanded = false }
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
        VStack(spacing: 0) {
            InAppDynamicIsland(isExpanded: $isExpanded, metrics: metrics, ringColor: .red) {
                artwork
            } trailing: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            } expanded: {
                nowPlaying
            }
            .padding(.top, metrics.topInset)

            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
    }

    /// 收起态贴在挖孔左侧的封面，展开后滑到岛体左上角。
    private var artwork: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(colors: [accent, Color(red: 0.62, green: 0.24, blue: 0.72)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            )
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    /// 展开态的主内容区：曲目信息 + 进度条。高度由它决定，岛体自适应。
    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("App 内灵动岛")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                Text("ios-lab · 正在播放")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 18)
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
                    .tint(accent)
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
        Label {
            Text(isExpanded ? "点击岛体以外的任何位置收起" : "点一下上方的灵动岛展开")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(foreground)
                .contentTransition(.opacity)
        } icon: {
            Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "hand.tap")
                .foregroundStyle(accent)
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

            Text("岛体是通用组件 InAppDynamicIsland：封面、暂停键、下方的曲目信息都是外部传进来的自定义视图，收起态胶囊随左右内容变宽，展开态高度随主内容自适应。")
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
                tuningSlider(title: "挖孔宽度", value: $metrics.notchWidth, range: 100...160)
                tuningSlider(title: "挖孔高度", value: $metrics.notchHeight, range: 28...50)
                tuningSlider(title: "顶部距离", value: $metrics.topInset, range: 0...30)
                tuningSlider(title: "红框间距", value: $metrics.ringGap, range: 0...12)
                tuningSlider(title: "收起留白", value: $metrics.compactSideInset, range: 0...24)

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
                .tint(accent)
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
