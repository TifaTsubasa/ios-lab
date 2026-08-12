//
//  RustCore.swift
//  ios-lab
//
//  Rust core 在 Swift 侧的句柄。
//

import Foundation

/// 跨过 C ABI 与 Rust core 通话。
///
/// 这里只负责搬运：把 `Encodable` 请求包成 JSON 信封递过去，再把 JSON 响应解成
/// 生成的 Response 类型。「有哪些命令、字段是什么」全部由
/// `RustCoreIPC.generated.swift` 决定，改契约不需要动这个文件。
/// 工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，而 core 必须能在后台
/// 线程上被调用，所以这里显式声明 `nonisolated`。
nonisolated final class RustCore: Sendable {
    static let shared = RustCore()

    enum Failure: LocalizedError {
        case core(String)
        case emptyPayload

        var errorDescription: String? {
            switch self {
            case .core(let message): "rust core: \(message)"
            case .emptyPayload: "rust core 返回了空 payload"
            }
        }
    }

    private init() {}

    /// 原样转发一条 JSON 信封。WebView 的请求走这条路——壳不解析内容，
    /// 也就不需要在每次增删命令时跟着改。
    ///
    /// 会阻塞当前线程直到 core 返回，调用方负责别在主线程上调它。
    nonisolated func dispatch(envelopeJSON: String) -> String {
        guard let raw = rustcore_dispatch(envelopeJSON) else {
            return #"{"id":0,"ok":false,"error":"rust core 未返回结果"}"#
        }
        defer { rustcore_string_free(raw) }
        return String(cString: raw)
    }

    /// 类型化通道，供生成的命令方法使用。
    nonisolated func call<Request: Encodable, Response: Decodable>(
        _ command: RustCoreIPC.Command,
        _ request: Request
    ) throws -> Response {
        let envelope = RequestEnvelope(
            id: UInt64.random(in: 1...UInt64.max),
            command: command.rawValue,
            payload: request
        )
        let requestJSON = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        let responseJSON = dispatch(envelopeJSON: requestJSON)

        let decoded = try JSONDecoder().decode(
            ResponseEnvelope<Response>.self,
            from: Data(responseJSON.utf8)
        )
        guard decoded.ok else { throw Failure.core(decoded.error ?? "未知错误") }
        guard let payload = decoded.payload else { throw Failure.emptyPayload }
        return payload
    }
}

/// 三端共用的信封格式，与 `ipc/codegen.mjs` 生成的 Rust/TS 侧保持一致。
private nonisolated struct RequestEnvelope<Payload: Encodable>: Encodable {
    var id: UInt64
    var command: String
    var payload: Payload
}

private nonisolated struct ResponseEnvelope<Payload: Decodable>: Decodable {
    var id: UInt64
    var ok: Bool
    var payload: Payload?
    var error: String?
}
