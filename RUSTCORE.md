# RustCore 跨端架构实践

对标 [Raycast 2.0 的技术架构](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast)，在 iOS 上做的一个最小但结构忠实的实践。作为 `ios-lab` Demo 合集中的一个条目，入口在首页列表的「RustCore 跨端架构」。

---

## 一、功能：一个跑在 iOS 上的 Raycast 式文件搜索器

打开首页列表 →「RustCore 跨端架构」，会看到一个暗色的搜索界面。

### 启动时（自动三步）

1. 向 Rust core 要版本号 → 显示在导航栏右上角 `core v0.1.0`
2. 把 App 沙盒里的两个目录（`Bundle.main.bundlePath` 和 Documents）交给 Rust
3. Rust 递归扫描这些目录建立内存索引 → 底栏显示 `8 个文件 · 建索引 0 ms`

### 交互

- 输入框每次击键（60ms 防抖）触发一次搜索，结果实时重排
- 每条结果显示：文件名、所在目录（过长时保留尾部）、文件大小、**模糊匹配得分**
- 支持外接键盘 ↑↓ 选择，触摸点选
- 底栏实时刷新本次搜索耗时，单位是**微秒**

### 搜索算法（在 Rust 里）

不是简单的 `contains`，是子序列模糊匹配 + 加权打分：

| 规则 | 加分 |
| ---- | ---- |
| 命中在名字开头 | +10 |
| 命中在词首（`/ _ - . 空格` 之后） | +8 |
| 命中在 camelCase 边界 | +6 |
| 与上一次命中相邻（连续段） | +14 |
| 命中之间每跳过一个字符 | −0.3 |

所以搜 `info` 时，`Info.plist`（57.5，开头 + 连续四击）排在 `PkgInfo`（53.8，词中命中）前面；搜 `view` 时 `ContentView.swift` 压过 `v_i_e_w_notes.txt`。

### 这个 Demo 真正想演示的

功能本身只是载体。它要证明的是——UI 用 React 写、状态和计算在 Rust 里、壳是原生的，三者靠一份契约粘合，而且**契约改一处，三端同时编译报错**。

---

## 二、架构：三层 + 一份契约

### 分层

```
┌─────────────────────────────────────────────┐
│  SwiftUI 原生壳                              │  RustCoreLabView.swift
│  页面容器 / 导航栏 / 分层说明条                 │  RustCoreWebHost.swift
│  托管 WKWebView，注册 message handler         │  RustCore.swift
└─────────────────────────────────────────────┘
                    ↕  postMessage / evaluateJavaScript
┌─────────────────────────────────────────────┐
│  WKWebView 里的 React + TypeScript            │  web/src/App.tsx
│  全部 UI 逻辑：输入、列表、防抖、竞态处理         │  web/src/ipc/transport.ts
└─────────────────────────────────────────────┘
                    ↕  C ABI（2 个函数）
┌─────────────────────────────────────────────┐
│  Rust core（librustcore.a）                  │  rust/rustcore/src/index.rs
│  文件索引 + 模糊打分，持有全部状态               │  rust/rustcore/src/lib.rs
└─────────────────────────────────────────────┘
```

### 中枢：`ipc/schema.json`

3 条命令（`buildIndex` / `search` / `coreInfo`）、1 个共享类型（`Hit`）。`ipc/codegen.mjs` 从它生成三份文件：

| 产物 | 内容 |
| ---- | ---- |
| `web/src/ipc/generated.ts` | TS `interface` + `ipc.search(req): Promise<SearchResponse>` |
| `ios-lab/RustCore/RustCoreIPC.generated.swift` | `Codable` struct + `RustCore` 上的类型化方法 |
| `rust/rustcore/src/ipc_generated.rs` | serde struct + `trait CommandHandlers` + 路由 `dispatch()` |

三端共用同一套信封格式：

```jsonc
// 请求
{ "id": 7, "command": "search", "payload": { "query": "info", "limit": 50 } }
// 成功响应
{ "id": 7, "ok": true, "payload": { "hits": [/* … */], "elapsedMicros": 54 } }
// 失败响应
{ "id": 7, "ok": false, "error": "…" }
```

### 一次击键的完整数据流

用户输入 `info`，60ms 后：

1. **React** 调 `ipc.search({ query: "info", limit: 50 })` —— 生成的 client
2. **transport.ts** 分配 id，包成信封，`window.webkit.messageHandlers.rustcore.postMessage(...)`
3. **Swift Coordinator** 收到字符串，**丢到后台线程**（索引可能扫上万文件，占主线程输入框会卡）
4. **`RustCore.dispatch()`** 把 JSON 递过 C ABI：`rustcore_dispatch(const char*)`
5. **Rust** `dispatch()` 按 `command` 字段路由到 `Core::search()`，打分排序，编码成响应信封
6. 返回的 `CString` 交出所有权，**Swift 侧 `defer` 调 `rustcore_string_free`** 释放
7. 跳回主线程 `evaluateJavaScript("window.__rustcore.__resolve({...})")`
8. **transport.ts** 按 id 找到 pending Promise 并 resolve → React 重渲染

---

## 三、三个关键设计取舍

### FFI 面刻意只有两个函数

```c
char *rustcore_dispatch(const char *request_json);
void  rustcore_string_free(char *ptr);
```

类型安全完全交给生成的 IPC，C ABI 只搬运 JSON 字节。结果是：schema 里增删命令，**永远不需要碰 Xcode 工程和头文件**。

### Node 层是缺席的，而且是有意的

Raycast 桌面端在 WebView 和 Rust 之间有一层长驻 **Node 进程**（数据库、扩展运行时）。iOS 不允许 fork 子进程，那层搬不过来 —— 所以这里 UI 直接复用 Rust 数据层，这恰好也是 Raycast 自家 iOS App 的做法。

### 「原生 App 用 web 做 UI」，而不是反过来

壳负责所有需要系统能力的事（窗口、导航栏、生命周期、后台线程调度），WebView 只画 UI。CSS 里刻意不写 `cursor: pointer`、关掉整页回弹——这些是 web 默认行为，不是原生手感。

---

## 四、构建接线

`ios-lab/` 是 Xcode 的 `PBXFileSystemSynchronizedRootGroup`，放进去的文件自动纳入 target。RustCore Demo 的 Swift 壳、桥接头、C ABI 头文件、以及生成物（`RustCoreIPC.generated.swift`、单文件 `RustCoreUI.html`）统一放在 `ios-lab/RustCore/` 并提交进仓库（子目录在打包时会被摊平，资源照样能被 `Bundle.main.url(forResource:)` 取到）—— **只用 Xcode 打开也能编译，不需要装 Rust 和 Node**。

而 `ipc/` `rust/` `web/` `scripts/` 必须放在 `ios-lab/` 外面，否则 `node_modules` 和 `target` 会被打进 App。

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim   # 首次
make all     # codegen → cargo → vite，并把产物投递进 ios-lab/
make test    # Rust 单元测试
make app     # xcodebuild 模拟器构建
```

### 踩过的坑

| 坑 | 处理 |
| -- | ---- |
| `ENABLE_USER_SCRIPT_SANDBOXING = YES` 直接拒掉 cargo 写 `target/` | 工程配置改为 `NO` |
| `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 会把契约类型的 `Codable` conformance 绑到主 actor，后台线程编解码在 Swift 6 模式下是编译错误 | codegen 统一 emit `nonisolated` |
| Xcode 脚本阶段的 `PATH` 不含 `~/.cargo/bin`；注入的 `SDKROOT` 会干扰 cargo 选 SDK | `build-rust.sh` 里补 PATH、`unset SDKROOT` |
| 本机 `xcode-select` 指向 CommandLineTools | 所有 `xcodebuild` 带 `DEVELOPER_DIR`，已封进 `make app` |

---

## 五、验证

| 项目 | 结果 |
| ---- | ---- |
| Rust 单元测试 | 10/10 通过（打分排序、信封路由、真实目录索引） |
| `xcodebuild` 模拟器构建 | 零 error 零 warning |
| 导航栏 `core v0.1.0` | 由 **Swift 侧**生成的 client 调 `coreInfo()` 取回，证明原生壳不只是转发管道 |
| 底栏 `8 个文件 · 建索引 0 ms · 搜索 54 µs` | Rust 真实扫描了 iOS 沙盒 |
| 搜 `info` 的排序 | `Info.plist` 57.5 > `PkgInfo` 53.8，模糊打分符合预期 |

### 契约一致性实测

把 `ipc/schema.json` 里的 `version` 字段改成 `semver`、重新生成后，三端同时编译失败：

| 运行时 | 报错 |
| ------ | ---- |
| Rust | ``struct `CoreInfoResponse` has no field named `version` `` |
| TypeScript | `TS2339: Property 'version' does not exist on type 'CoreInfoResponse'` |
| Swift | `value of type 'RustCoreIPC.CoreInfoResponse' has no member 'version'` |

这是整套架构的核心价值：接口只声明一次，任何一端漏改都会在编译期而不是运行期暴露。
