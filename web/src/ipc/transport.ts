// IPC 传输层（手写，非生成）。
//
// 对应 Raycast 架构里的 "platform message handlers"：WebView 侧只认识
// postMessage，至于对面是 WKWebView 还是 WebView2，由原生壳决定。
// 生成的 client 只依赖这里的 invoke()，换传输不影响契约。

interface RequestEnvelope {
  id: number;
  command: string;
  payload: unknown;
}

interface ResponseEnvelope {
  id: number;
  ok: boolean;
  payload?: unknown;
  error?: string;
}

interface PendingCall {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: Record<string, { postMessage(body: string): void }>;
    };
    /** 原生壳在 documentStart 注入的启动上下文。 */
    __rustcoreBootstrap?: { roots: string[] };
    /** 原生壳拿到 core 响应后回调这里。 */
    __rustcore: { __resolve(envelope: ResponseEnvelope): void };
  }
}

const pending = new Map<number, PendingCall>();
let nextID = 1;

window.__rustcore = {
  __resolve(envelope) {
    const call = pending.get(envelope.id);
    if (!call) return;
    pending.delete(envelope.id);

    if (envelope.ok) {
      call.resolve(envelope.payload);
    } else {
      call.reject(new Error(envelope.error ?? "rust core 返回了未知错误"));
    }
  },
};

/** 发起一次跨运行时调用。只应由生成的 client 使用。 */
export function invoke<Request, Response>(command: string, payload: Request): Promise<Response> {
  const handler = window.webkit?.messageHandlers?.rustcore;
  if (!handler) {
    return Promise.reject(new Error("原生壳缺席：当前不在 WKWebView 中运行"));
  }

  const id = nextID++;
  const envelope: RequestEnvelope = { id, command, payload };

  return new Promise<Response>((resolve, reject) => {
    pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
    handler.postMessage(JSON.stringify(envelope));
  });
}

/** 原生壳交给 UI 的待索引根目录。 */
export function bootstrapRoots(): string[] {
  return window.__rustcoreBootstrap?.roots ?? [];
}
