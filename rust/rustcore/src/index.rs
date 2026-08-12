//! 文件索引与模糊打分。
//!
//! 对应 Raycast 2.0 里由 Rust 承担的 indexer 角色：扫描目录、常驻内存索引、
//! 在没有 GC 停顿的前提下做高频打分排序。

use std::fs;
use std::path::Path;

/// 索引中的一条记录。
#[derive(Debug, Clone)]
pub struct Entry {
    pub name: String,
    pub path: String,
    pub size_bytes: u32,
}

/// 递归深度上限，防止沙盒里出现异常深的目录树把索引撑爆。
const MAX_DEPTH: usize = 8;
/// 条目上限，保证 Demo 的内存占用可预期。
const MAX_ENTRIES: usize = 20_000;

/// 命中位于名字开头的加分。
const BONUS_HEAD: f32 = 10.0;
/// 命中位于分隔符之后（词首）的加分。
const BONUS_WORD_BOUNDARY: f32 = 8.0;
/// 命中位于 camelCase 边界的加分。
const BONUS_CAMEL_BOUNDARY: f32 = 6.0;
/// 与上一次命中相邻的加分。连续命中是最强信号，必须显著压过散落命中。
const BONUS_CONSECUTIVE: f32 = 14.0;
/// 两次命中之间每跳过一个字符的扣分。
const PENALTY_PER_GAP: f32 = 0.3;

/// 扫描给定根目录，返回扁平化的文件索引。
pub fn scan(roots: &[String]) -> Vec<Entry> {
    let mut entries = Vec::new();
    for root in roots {
        walk(Path::new(root), 0, &mut entries);
    }
    entries
}

fn walk(dir: &Path, depth: usize, out: &mut Vec<Entry>) {
    if depth > MAX_DEPTH || out.len() >= MAX_ENTRIES {
        return;
    }

    let Ok(children) = fs::read_dir(dir) else {
        return; // 权限不足或路径不存在时静默跳过，索引尽力而为
    };

    for child in children.flatten() {
        if out.len() >= MAX_ENTRIES {
            return;
        }

        // 用 symlink_metadata 判定，避免跟随符号链接走进目录环。
        let path = child.path();
        let Ok(meta) = fs::symlink_metadata(&path) else {
            continue;
        };

        if meta.is_dir() {
            walk(&path, depth + 1, out);
        } else if meta.is_file() {
            out.push(Entry {
                name: child.file_name().to_string_lossy().into_owned(),
                path: path.to_string_lossy().into_owned(),
                size_bytes: meta.len().min(u32::MAX as u64) as u32,
            });
        }
    }
}

/// 子序列模糊匹配打分，返回 `None` 表示 query 不是 candidate 的子序列。
///
/// 加权规则：命中开头、命中词首、命中 camelCase 边界、以及与上一次命中相邻
/// 都会加分；命中之间的跳跃距离扣分；同分时更短的名字略微占优。
pub fn score(query: &str, candidate: &str) -> Option<f32> {
    let needle: Vec<char> = query.chars().map(|c| c.to_ascii_lowercase()).collect();
    if needle.is_empty() {
        return Some(0.0);
    }

    let chars: Vec<char> = candidate.chars().collect();
    let lowered: Vec<char> = chars.iter().map(|c| c.to_ascii_lowercase()).collect();

    let mut total = 0.0_f32;
    let mut matched = 0_usize;
    let mut previous: Option<usize> = None;

    for (i, ch) in lowered.iter().enumerate() {
        if matched >= needle.len() {
            break;
        }
        if *ch != needle[matched] {
            continue;
        }

        let mut bonus = 1.0_f32;
        if i == 0 {
            bonus += BONUS_HEAD;
        } else {
            let prev_char = chars[i - 1];
            if matches!(prev_char, '/' | '_' | '-' | '.' | ' ') {
                bonus += BONUS_WORD_BOUNDARY;
            } else if prev_char.is_lowercase() && chars[i].is_uppercase() {
                bonus += BONUS_CAMEL_BOUNDARY;
            }
        }

        if let Some(previous_index) = previous {
            if previous_index + 1 == i {
                bonus += BONUS_CONSECUTIVE;
            } else {
                total -= (i - previous_index - 1) as f32 * PENALTY_PER_GAP;
            }
        }

        total += bonus;
        previous = Some(i);
        matched += 1;
    }

    if matched < needle.len() {
        return None;
    }

    // 同样命中的情况下，更短的名字更可能是用户想要的那个。
    total += 30.0 / (chars.len() as f32 + 10.0);
    Some(total.max(0.0))
}

#[cfg(test)]
mod tests {
    use super::score;

    fn ranked<'a>(query: &str, candidates: &[&'a str]) -> Vec<&'a str> {
        let mut scored: Vec<(&str, f32)> = candidates
            .iter()
            .filter_map(|candidate| score(query, candidate).map(|s| (*candidate, s)))
            .collect();
        scored.sort_by(|a, b| b.1.total_cmp(&a.1));
        scored.into_iter().map(|(candidate, _)| candidate).collect()
    }

    #[test]
    fn rejects_non_subsequence() {
        assert!(score("zzz", "ContentView.swift").is_none());
    }

    #[test]
    fn matching_is_case_insensitive() {
        assert!(score("CONTENT", "ContentView.swift").is_some());
    }

    #[test]
    fn empty_query_matches_everything() {
        assert_eq!(score("", "anything"), Some(0.0));
    }

    #[test]
    fn consecutive_run_beats_scattered_match() {
        let result = ranked("view", &["v_i_e_w_notes.txt", "ContentView.swift"]);
        assert_eq!(result.first(), Some(&"ContentView.swift"));
    }

    #[test]
    fn shorter_name_wins_on_equal_match() {
        let short = score("core", "core.rs").unwrap();
        let long = score("core", "core_with_a_very_long_suffix.rs").unwrap();
        assert!(short > long, "short={short} long={long}");
    }

    #[test]
    fn word_boundary_beats_mid_word() {
        let boundary = score("v", "content_view.swift").unwrap();
        let mid_word = score("v", "having.swift").unwrap();
        assert!(boundary > mid_word, "boundary={boundary} mid_word={mid_word}");
    }
}
