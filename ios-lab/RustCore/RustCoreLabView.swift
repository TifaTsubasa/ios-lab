//
//  RustCoreLabView.swift
//  ios-lab
//
//  Raycast 2.0 跨端架构在 iOS 上的最小实践。
//

import SwiftUI

/// 三层架构的入口页：SwiftUI 原生壳 → WKWebView 里的 React UI → Rust core。
///
/// Raycast 2.0 桌面端在 WebView 与 Rust 之间还有一层长驻 Node 进程，承担
/// 数据库、扩展运行时等业务逻辑；iOS 不允许 fork 子进程，所以那一层在这里
/// 缺席，UI 直接复用 Rust 的数据层——这也正是 Raycast 自家 iOS App 的做法。
struct RustCoreLabView: View {
    @State private var coreVersion: String?

    /// 交给 Rust 建索引的沙盒目录。
    private var indexRoots: [String] {
        var roots = [Bundle.main.bundlePath]
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        roots.append(contentsOf: documents.map(\.path))
        return roots
    }

    var body: some View {
        VStack(spacing: 0) {
            LayerLegend()
            Divider().overlay(Color.white.opacity(0.08))
            RustCoreWebHost(roots: indexRoots)
        }
        .background(.black)
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("RustCore")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(coreVersion.map { "core v\($0)" } ?? "…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadCoreVersion() }
    }

    /// 原生壳自己也调一次生成的 typed client——与 WebView 用的是同一份契约，
    /// 它并不只是个转发管道。
    private func loadCoreVersion() async {
        let version = try? await Task.detached(priority: .userInitiated) {
            try RustCore.shared.coreInfo(.init()).version
        }.value

        coreVersion = version ?? "?"
    }
}

/// 顶部的分层说明条，点明这个 Demo 到底在演示什么。
private struct LayerLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            layer("SwiftUI 壳", .orange)
            arrow
            layer("WKWebView · React", .cyan)
            arrow
            layer("Rust core", .pink)
        }
        .font(.system(size: 10, weight: .medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.black)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.tertiary)
    }

    private func layer(_ title: String, _ tint: Color) -> some View {
        Text(title)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

#Preview {
    NavigationStack {
        RustCoreLabView()
    }
}
