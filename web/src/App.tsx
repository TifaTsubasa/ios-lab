import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent } from "react";
import { ipc, type Hit } from "./ipc/generated";
import { bootstrapRoots } from "./ipc/transport";

const SEARCH_DEBOUNCE_MS = 60;
const RESULT_LIMIT = 50;

interface CoreStatus {
  version: string;
  fileCount: number;
  indexElapsedMs: number;
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function parentDirectory(path: string): string {
  const cut = path.lastIndexOf("/");
  return cut <= 0 ? "/" : path.slice(0, cut);
}

export function App() {
  const [status, setStatus] = useState<CoreStatus | null>(null);
  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<Hit[]>([]);
  const [searchMicros, setSearchMicros] = useState(0);
  const [selected, setSelected] = useState(0);
  const [error, setError] = useState<string | null>(null);

  // 只保留最后一次搜索的结果，避免慢响应覆盖快响应。
  const latestSearch = useRef(0);

  const runSearch = useCallback(async (text: string) => {
    const ticket = ++latestSearch.current;
    try {
      const response = await ipc.search({ query: text, limit: RESULT_LIMIT });
      if (ticket !== latestSearch.current) return;
      setHits(response.hits);
      setSearchMicros(response.elapsedMicros);
      setSelected(0);
    } catch (cause) {
      setError(String(cause));
    }
  }, []);

  // 启动：先问 core 版本，再让 Rust 把原生壳给的根目录扫成索引。
  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        const info = await ipc.coreInfo({});
        const indexed = await ipc.buildIndex({ roots: bootstrapRoots() });
        if (cancelled) return;

        setStatus({
          version: info.version,
          fileCount: indexed.fileCount,
          indexElapsedMs: indexed.elapsedMs,
        });
        await runSearch("");
      } catch (cause) {
        if (!cancelled) setError(String(cause));
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [runSearch]);

  // 输入防抖，模拟 Raycast 每次击键都重排结果的手感。
  useEffect(() => {
    if (!status) return;
    const timer = window.setTimeout(() => void runSearch(query), SEARCH_DEBOUNCE_MS);
    return () => window.clearTimeout(timer);
  }, [query, status, runSearch]);

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setSelected((current) => Math.min(current + 1, hits.length - 1));
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setSelected((current) => Math.max(current - 1, 0));
    }
  };

  const footer = useMemo(() => {
    if (error) return error;
    if (!status) return "正在唤醒 Rust core…";
    return [
      `${status.fileCount.toLocaleString()} 个文件`,
      `建索引 ${status.indexElapsedMs} ms`,
      `搜索 ${searchMicros.toLocaleString()} µs`,
      `core v${status.version}`,
    ].join("  ·  ");
  }, [error, status, searchMicros]);

  return (
    <div className="shell">
      <div className="searchbar">
        <span className="glyph" aria-hidden="true">
          ⌕
        </span>
        <input
          className="input"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={onKeyDown}
          placeholder="搜索索引里的文件…"
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="off"
          spellCheck={false}
          disabled={!status}
        />
        {hits.length > 0 && <span className="count">{hits.length}</span>}
      </div>

      <div className="results">
        {status && hits.length === 0 && <div className="empty">没有匹配的文件</div>}
        {hits.map((hit, position) => (
          <button
            key={hit.path}
            type="button"
            className={position === selected ? "row selected" : "row"}
            onClick={() => setSelected(position)}
          >
            <span className="badge">{hit.name.split(".").pop()?.slice(0, 4) ?? "?"}</span>
            <span className="text">
              <span className="name">{hit.name}</span>
              <span className="path">{parentDirectory(hit.path)}</span>
            </span>
            <span className="meta">
              <span className="size">{formatSize(hit.sizeBytes)}</span>
              <span className="score">{hit.score.toFixed(1)}</span>
            </span>
          </button>
        ))}
      </div>

      <div className={error ? "statusbar failed" : "statusbar"}>{footer}</div>
    </div>
  );
}
