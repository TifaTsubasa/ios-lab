import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

// 产物必须是**单个** HTML：Xcode 的 file-system-synchronized group 会把嵌套目录
// 摊平，只有单文件资源才能稳定地被 Bundle.main.url(forResource:) 取到。
export default defineConfig({
  plugins: [react(), viteSingleFile()],
  build: {
    target: "safari18",
    assetsInlineLimit: 100_000_000,
    cssCodeSplit: false,
    reportCompressedSize: false,
  },
});
