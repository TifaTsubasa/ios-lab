//! C ABI 边界。
//!
//! 这层刻意只暴露两个函数：类型安全由生成的 IPC 契约负责，C ABI 只搬运
//! JSON 字节。命令增删不会改变 FFI 面，也就不需要反复动 Xcode 工程。

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{self, AssertUnwindSafe};

/// 把一条 JSON 信封交给 core 处理，返回新分配的 JSON 字符串。
///
/// 调用方拿到所有权，必须用 [`rustcore_string_free`] 释放。
///
/// # Safety
/// `request_json` 必须是有效的、以 NUL 结尾的 UTF-8 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn rustcore_dispatch(request_json: *const c_char) -> *mut c_char {
    let response = panic::catch_unwind(AssertUnwindSafe(|| {
        if request_json.is_null() {
            return error_envelope("request_json 为空指针");
        }
        match CStr::from_ptr(request_json).to_str() {
            Ok(text) => crate::handle(text),
            Err(_) => error_envelope("request_json 不是合法 UTF-8"),
        }
    }))
    .unwrap_or_else(|_| error_envelope("rust core 内部 panic"));

    // 响应里可能含有文件名，理论上不会带内嵌 NUL；真出现就退化成错误信封。
    CString::new(response)
        .unwrap_or_else(|_| CString::new(error_envelope("响应包含内嵌 NUL")).unwrap())
        .into_raw()
}

/// 释放 [`rustcore_dispatch`] 返回的字符串。
///
/// # Safety
/// `ptr` 必须来自 [`rustcore_dispatch`]，且只能释放一次。
#[no_mangle]
pub unsafe extern "C" fn rustcore_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

fn error_envelope(message: &str) -> String {
    serde_json::json!({ "id": 0, "ok": false, "error": message }).to_string()
}
