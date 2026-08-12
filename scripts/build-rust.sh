#!/bin/bash
#
# 把 Rust core 编译成当前 Xcode 平台/架构对应的静态库，并放到 BUILT_PRODUCTS_DIR。
# 由 Xcode 的「Build Rust Core」脚本阶段调用，也可以在命令行直接跑（make rust）。

set -euo pipefail

# Xcode 脚本阶段的 PATH 不包含 ~/.cargo/bin，必须自己补上。
export PATH="$HOME/.cargo/bin:$PATH"

# Xcode 注入的 SDKROOT 指向 App 的 SDK，会让 cargo 给 build script 选错 SDK。
unset SDKROOT

REPO_ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CRATE_DIR="$REPO_ROOT/rust/rustcore"

PLATFORM="${PLATFORM_NAME:-iphonesimulator}"
# ARCHS 可能是空格分隔的多个架构，取第一个即可（iOS 现在实际只有 arm64）。
ARCH="${ARCHS:-arm64}"
ARCH="${ARCH%% *}"

case "$PLATFORM/$ARCH" in
    iphonesimulator/arm64)  TARGET="aarch64-apple-ios-sim" ;;
    iphonesimulator/x86_64) TARGET="x86_64-apple-ios" ;;
    iphoneos/arm64)         TARGET="aarch64-apple-ios" ;;
    macosx/arm64)           TARGET="aarch64-apple-darwin" ;;
    macosx/x86_64)          TARGET="x86_64-apple-darwin" ;;
    *)
        echo "error: 尚未支持的平台/架构组合 $PLATFORM/$ARCH" >&2
        exit 1
        ;;
esac

if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
    PROFILE_DIR="release"
else
    PROFILE_DIR="debug"
fi

echo "note: building rustcore for $TARGET ($PROFILE_DIR)"
if [ "$PROFILE_DIR" = "release" ]; then
    cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --target "$TARGET" --release
else
    cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --target "$TARGET"
fi

ARTIFACT="$CRATE_DIR/target/$TARGET/$PROFILE_DIR/librustcore.a"
if [ ! -f "$ARTIFACT" ]; then
    echo "error: 未找到构建产物 $ARTIFACT" >&2
    exit 1
fi

# 命令行直接调用时没有 BUILT_PRODUCTS_DIR，编译完就够了。
if [ -n "${BUILT_PRODUCTS_DIR:-}" ]; then
    mkdir -p "$BUILT_PRODUCTS_DIR"
    cp "$ARTIFACT" "$BUILT_PRODUCTS_DIR/librustcore.a"
    echo "note: staged $BUILT_PRODUCTS_DIR/librustcore.a"
fi
