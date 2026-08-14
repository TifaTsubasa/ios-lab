//
//  IslandActivityWidget.swift
//  IslandWidget
//
//  真实 Live Activity 的 UI。存在的意义是给 Demo 提供一个可观察对象：
//  只有装了这个 ActivityConfiguration，App 里的 Activity.request 才能成功、
//  系统灵动岛上才会真的出现东西，进而验证「宿主 App 回到前台时系统自动隐藏它」。
//
//  截图注意：`xcrun simctl io <udid> screenshot` 不合成灵动岛这一层，拍出来只有一圈空轮廓。
//  要看岛上的内容，直接截 Simulator 窗口（例如 `screencapture -R<x>,<y>,<w>,<h>`）。
//

import ActivityKit
import SwiftUI
import WidgetKit

/// 与 App 内模拟岛同一个红色，方便截图并排对照。
private let islandAccent = Color(red: 1.0, green: 0.23, blue: 0.19)

struct IslandActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InAppIslandActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(islandAccent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已运行")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(context.state.startedAt, style: .timer)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("回前台")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(context.state.foregroundReturns) 次")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(islandAccent)
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Text("切回 ios-lab，这个岛会被系统隐藏，但活动仍在运行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(islandAccent)
            } compactTrailing: {
                Text("\(context.state.foregroundReturns)")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(islandAccent)
            } minimal: {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(islandAccent)
            }
            .keylineTint(islandAccent)
        }
    }

    /// 锁屏 / 不带灵动岛机型上的横幅样式。
    private func lockScreenView(context: ActivityViewContext<InAppIslandActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(islandAccent)
                Text(context.attributes.demoTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(context.state.startedAt, style: .timer)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: 64, alignment: .trailing)
            }

            Text("App 回到前台 \(context.state.foregroundReturns) 次")
                .font(.system(size: 12))
                .foregroundStyle(islandAccent)

            Text("宿主 App 在前台时系统不渲染这条活动，但它没有结束。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}
