//
//  RustCoreWebHost.swift
//  ios-lab
//
//  原生壳：托管系统 WebView，并在它与 Rust core 之间转发消息。
//

import SwiftUI
import WebKit

/// 承载 React UI 的 `WKWebView`，同时充当它通往 Rust core 的唯一通道。
///
/// 对应 Raycast 的做法：UI 用 web 技术写，但窗口、生命周期、以及所有需要
/// 系统能力的事情都留在原生这一侧。
struct RustCoreWebHost: UIViewRepresentable {
    /// 交给 Rust 去建索引的根目录。
    let roots: [String]

    /// JS 侧的 message handler 名字，需与 `transport.ts` 中一致。
    private static let channelName = "rustcore"

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: Self.channelName)
        configuration.userContentController.addUserScript(bootstrapScript())

        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        // 打开后可在 Mac 的 Safari「开发」菜单里挂上 Web Inspector 调试这个 WebView。
        // 只在 Debug 生效，Release 包不应该允许外部审查页面。
        webView.isInspectable = true
        #endif
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // 列表滚动由 WebView 内部负责，关掉整页回弹以免露出底色。
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView

        if let page = Bundle.main.url(forResource: "RustCoreUI", withExtension: "html") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            assertionFailure("RustCoreUI.html 未被打包，请先执行 make web")
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: channelName)
    }

    /// 在 documentStart 注入启动上下文，UI 一挂载就知道该索引哪些目录。
    private func bootstrapScript() -> WKUserScript {
        let json = (try? JSONSerialization.data(withJSONObject: ["roots": roots]))
            .map { String(decoding: $0, as: UTF8.self) } ?? #"{"roots":[]}"#

        return WKUserScript(
            source: "window.__rustcoreBootstrap = \(json);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// WebView → Rust core → WebView 的往返。
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let envelope = message.body as? String else { return }

            // 建索引会扫上万个文件，必须离开主线程，否则输入框会卡住。
            Task.detached(priority: .userInitiated) { [weak self] in
                let response = RustCore.shared.dispatch(envelopeJSON: envelope)
                await self?.deliver(response)
            }
        }

        private func deliver(_ responseJSON: String) {
            // JSON 允许裸的 U+2028/U+2029，JavaScript 源码不允许——转义掉。
            let literal = responseJSON
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

            webView?.evaluateJavaScript("window.__rustcore.__resolve(\(literal))")
        }
    }
}
