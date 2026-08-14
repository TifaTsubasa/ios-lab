//
//  IslandProbeApp.swift
//  IslandProbe
//
//  灵动岛对照实验的「观察者」App。
//
//  为什么需要第二个 App：宿主 App 在前台时系统本来就不渲染自家的 Live Activity，
//  所以 ios-lab 自己没法观察自己的岛。这个 App 只干一件事——作为前台 App，
//  逐个打开各种「沉浸/全屏」开关，看 ios-lab 那条 Live Activity 的岛还在不在。
//
//  用法：先在 ios-lab 的「App 内灵动岛」页点「开始实时活动」，再切到这个 App 逐项试。
//

import SwiftUI

@main
struct IslandProbeApp: App {
    var body: some Scene {
        WindowGroup {
            IslandProbeView()
        }
    }
}

struct IslandProbeView: View {
    @State private var hideStatusBar = false
    @State private var hidePersistentOverlays = false
    @State private var blackFullScreen = false

    var body: some View {
        ZStack {
            (blackFullScreen ? Color.black : Color(white: 0.97))
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("灵动岛观察者")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(blackFullScreen ? .white : .black)

                    Text("先去 ios-lab 启动实时活动，再回到这里逐项开关，看顶部那条岛有没有消失。")
                        .font(.system(size: 13))
                        .foregroundStyle(blackFullScreen ? .white.opacity(0.6) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    probe("隐藏状态栏", detail: "statusBarHidden(true)", isOn: $hideStatusBar)
                    probe("隐藏系统持久覆盖层", detail: "persistentSystemOverlays(.hidden)", isOn: $hidePersistentOverlays)
                    probe("纯黑全屏铺满", detail: "黑色 + ignoresSafeArea()", isOn: $blackFullScreen)

                    Text("三个都打开就是一个 App 能做到的最「沉浸」的状态。如果岛还在，说明 App 层面没有任何办法赶走它。")
                        .font(.system(size: 12))
                        .foregroundStyle(blackFullScreen ? .white.opacity(0.45) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .padding(20)
                .padding(.top, 60)
            }
        }
        .statusBarHidden(hideStatusBar)
        .persistentSystemOverlays(hidePersistentOverlays ? .hidden : .automatic)
    }

    private func probe(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(blackFullScreen ? .white : .black)
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(blackFullScreen ? .white.opacity(0.45) : .secondary)
            }
        }
        .tint(Color(red: 0.98, green: 0.45, blue: 0.32))
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(blackFullScreen ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
        )
    }
}

#Preview {
    IslandProbeView()
}
