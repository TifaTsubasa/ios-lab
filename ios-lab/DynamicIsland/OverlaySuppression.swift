//
//  OverlaySuppression.swift
//  ios-lab
//
//  让**其他 App** 的 Live Activity 从灵动岛上消失。
//
//  这条路是实测出来的，不是文档写的。Apple DTS 那句「没有 API 能 disable 别家的 Live Activity」
//  字面上没错——你确实没法结束别人的活动；但你可以让系统在你处于前台时**不渲染**它。
//
//  IslandProbe 那个观察者 App 里跑的对照实验（ios-lab 持有活动，IslandProbe 在前台）：
//
//  | 前台 App 状态                              | 别家的岛 |
//  | ------------------------------------------ | -------- |
//  | 什么都不做                                  | 显示     |
//  | .statusBarHidden(true)                      | 消失     |
//  | .persistentSystemOverlays(.hidden)          | 消失     |
//  | 全部关掉（对照组）                          | 又回来   |
//
//  两者都有效，但 `.persistentSystemOverlays(.hidden)` 更合适：状态栏的时间/信号/电量
//  全部保留，只有灵动岛上的活动不渲染。活动本身没被结束，退出页面就恢复——
//  和「宿主 App 在前台时系统自动隐藏自家活动」是同一类渲染抑制。
//

import SwiftUI

/// 页面里的「隐藏其他 App 的灵动岛」区块。
struct OverlaySuppressionCard: View {
    @Binding var hideOverlays: Bool
    @Binding var hideStatusBar: Bool
    let foreground: Color

    private var accent: Color { Color(red: 0.98, green: 0.45, blue: 0.32) }
    private var isSuppressing: Bool { hideOverlays || hideStatusBar }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("隐藏其他 App 的灵动岛")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(foreground)
            } icon: {
                Image(systemName: isSuppressing ? "eye.slash.fill" : "eye")
                    .foregroundStyle(isSuppressing ? .green : .gray)
            }

            Text(isSuppressing
                 ? "已请求系统隐藏非必要覆盖层，别的 App 的 Live Activity 此刻不会渲染在岛上"
                 : "当前不抑制，别的 App 的 Live Activity 会正常显示在岛上")
                .font(.system(size: 12))
                .foregroundStyle(foreground.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $hideOverlays) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("隐藏系统持久覆盖层（推荐）")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(foreground)
                    Text("persistentSystemOverlays(.hidden) · 状态栏保留")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(foreground.opacity(0.4))
                }
            }
            .tint(accent)

            Toggle(isOn: $hideStatusBar) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("隐藏状态栏")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(foreground)
                    Text("statusBarHidden(true) · 时间信号电量一起没")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(foreground.opacity(0.4))
                }
            }
            .tint(accent)

            Text("活动没有被结束，只是你在前台时系统不渲染它——和「宿主 App 前台时自家活动被隐藏」是同一类抑制。退出页面自动恢复。")
                .font(.system(size: 12))
                .foregroundStyle(foreground.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)

            Text("对照实验在 IslandProbe target 里：ios-lab 持活动，IslandProbe 当前台逐项开关。")
                .font(.system(size: 11))
                .foregroundStyle(foreground.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(foreground.opacity(0.06))
        )
    }
}
