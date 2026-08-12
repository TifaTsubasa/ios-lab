//
//  rustcore.h
//  ios-lab
//
//  Rust core 的 C ABI 声明。手写维护——FFI 面只有两个函数，
//  命令的增删由 ipc/schema.json 驱动，不会波及这里。
//

#ifndef RUSTCORE_H
#define RUSTCORE_H

/// 把一条 JSON 信封交给 Rust core 处理，返回新分配的 JSON 字符串。
/// 调用方获得所有权，必须用 rustcore_string_free 释放。
char *rustcore_dispatch(const char *request_json);

/// 释放 rustcore_dispatch 返回的字符串。
void rustcore_string_free(char *ptr);

#endif /* RUSTCORE_H */
