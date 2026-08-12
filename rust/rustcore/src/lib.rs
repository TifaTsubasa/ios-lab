//! RustCore —— 对标 Raycast 2.0 架构里的 Rust core 层。
//!
//! 它持有全部状态（文件索引），并通过一份由 `ipc/schema.json` 生成的命令契约
//! 对外服务。上层不论是 WebView 里的 React UI 还是原生 Swift 壳，走的都是
//! 同一套生成代码，因此不存在「两端字段对不上」的可能。

mod ffi;
mod index;
mod ipc_generated;

pub use ipc_generated::*;

use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// core 版本号，随 crate 版本走。
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// 进程内唯一的 core 状态。
#[derive(Default)]
pub struct Core {
    entries: Vec<index::Entry>,
}

impl CommandHandlers for Core {
    fn build_index(&mut self, request: BuildIndexRequest) -> Result<BuildIndexResponse, String> {
        if request.roots.is_empty() {
            return Err("roots 不能为空".to_string());
        }

        let started = Instant::now();
        self.entries = index::scan(&request.roots);

        Ok(BuildIndexResponse {
            file_count: self.entries.len() as u32,
            elapsed_ms: started.elapsed().as_millis() as u32,
        })
    }

    fn search(&mut self, request: SearchRequest) -> Result<SearchResponse, String> {
        let started = Instant::now();
        let limit = request.limit.clamp(1, 200) as usize;

        let mut scored: Vec<(f32, &index::Entry)> = self
            .entries
            .iter()
            .filter_map(|entry| index::score(&request.query, &entry.name).map(|s| (s, entry)))
            .collect();

        scored.sort_by(|a, b| b.0.total_cmp(&a.0));
        scored.truncate(limit);

        let hits = scored
            .into_iter()
            .map(|(score, entry)| Hit {
                name: entry.name.clone(),
                path: entry.path.clone(),
                score,
                size_bytes: entry.size_bytes,
            })
            .collect();

        Ok(SearchResponse {
            hits,
            elapsed_micros: started.elapsed().as_micros() as u32,
        })
    }

    fn core_info(&mut self, _request: CoreInfoRequest) -> Result<CoreInfoResponse, String> {
        Ok(CoreInfoResponse {
            version: VERSION.to_string(),
            indexed_files: self.entries.len() as u32,
        })
    }
}

fn core() -> &'static Mutex<Core> {
    static CORE: OnceLock<Mutex<Core>> = OnceLock::new();
    CORE.get_or_init(|| Mutex::new(Core::default()))
}

/// 处理一条 JSON 信封。这是 core 唯一的入口，FFI 与测试都走它。
pub fn handle(envelope_json: &str) -> String {
    // 某条命令 panic 过也不该让后续请求全部失效，所以中毒锁直接取回内部值。
    let mut guard = core().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    ipc_generated::dispatch(&mut *guard, envelope_json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dispatches_core_info() {
        let response = handle(r#"{"id":1,"command":"coreInfo","payload":{}}"#);
        let value: serde_json::Value = serde_json::from_str(&response).unwrap();

        assert_eq!(value["id"], 1);
        assert_eq!(value["ok"], true);
        assert_eq!(value["payload"]["version"], VERSION);
    }

    #[test]
    fn reports_unknown_command() {
        let response = handle(r#"{"id":2,"command":"nope","payload":{}}"#);
        let value: serde_json::Value = serde_json::from_str(&response).unwrap();

        assert_eq!(value["ok"], false);
        assert!(value["error"].as_str().unwrap().contains("nope"));
    }

    #[test]
    fn reports_malformed_payload() {
        let response = handle(r#"{"id":3,"command":"search","payload":{"query":42}}"#);
        let value: serde_json::Value = serde_json::from_str(&response).unwrap();

        assert_eq!(value["ok"], false);
        assert_eq!(value["id"], 3);
    }

    #[test]
    fn indexes_and_searches_a_real_directory() {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/src").to_string();
        let mut core = Core::default();

        let indexed = core
            .build_index(BuildIndexRequest { roots: vec![root] })
            .unwrap();
        assert!(indexed.file_count >= 4, "扫描到 {} 个文件", indexed.file_count);

        let found = core
            .search(SearchRequest {
                query: "index".to_string(),
                limit: 10,
            })
            .unwrap();
        assert_eq!(found.hits.first().map(|hit| hit.name.as_str()), Some("index.rs"));
    }
}
