.PHONY: all ipc rust web app test clean

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
SIMULATOR ?= iPhone 17 Pro

## 生成 + 构建全部三层
all: ipc rust web

## 由 ipc/schema.json 生成 TS / Swift / Rust 三端客户端
ipc:
	node ipc/codegen.mjs

## 编译 Rust core（默认 iOS 模拟器架构）
rust:
	./scripts/build-rust.sh

## 构建 React UI，并把单文件产物投递到 Xcode 同步组
web:
	cd web && npm install --silent && npm run build
	cp web/dist/index.html ios-lab/RustCore/RustCoreUI.html
	@echo "note: staged ios-lab/RustCore/RustCoreUI.html ($$(wc -c < ios-lab/RustCore/RustCoreUI.html) bytes)"

## Rust 单元测试
test:
	cargo test --manifest-path rust/rustcore/Cargo.toml

## 构建 iOS App（模拟器）
app:
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -project ios-lab.xcodeproj -scheme ios-lab \
		-sdk iphonesimulator -destination 'platform=iOS Simulator,name=$(SIMULATOR)' build

clean:
	cargo clean --manifest-path rust/rustcore/Cargo.toml
	rm -rf web/dist web/node_modules
