# NixOS 双版本验收：2026-10-20

源码版本：**Chromium 154.0.8037.97**，ungoogled/portablelinux + 224 个 Chromix 补丁，
再应用 `nix/patches/` 的本地 Nix overlay。LLVM 21.1.8 / Rust 1.98.1。

## 已完成的实际产物

| 版本 | Nix store 产物 | 完整构建完成时间（UTC） |
| --- | --- | --- |
| 通用版 | `/nix/store/7akwq4jmy4xxqimy0srbrj2jgn9rj03p-chromix-154.0.8037.97` | 2026-10-19 05:37:58 |
| x86-64-v3 | `/nix/store/lmal1cc1f6b7nd9v0cbqb50ax0pzchq6-chromix-avx2-154.0.8037.97` | 2026-10-19 08:42:00 |

两版 Nix 构建和整批任务均退出 0；2026-10-20 对相同产物重新执行了包结构、浏览器运行、
新增功能和 `nix-store --verify-path` 检查。这里归档的是复测的真实 JSON 输出，没有占位结果。

| 检查 | 通用版 | x86-64-v3 |
| --- | --- | --- |
| 三个 x86_64 ELF、资源、字体、ICD、许可证 | 通过 | 通过 |
| 版本 / JavaScript / DOM | 通过 | 通过 |
| 复测基础运行 stderr | 空 | 空 |
| 默认目录派生的 `chromix-headless/scoped_dir*` | 通过 | 通过 |
| HEVC Main 软件解码：WebCodecs + HTML video | 通过 | 通过 |
| HEVC Main10 软件解码：WebCodecs + HTML video | 通过 | 通过 |
| 解码图像红色像素及 MediaCapabilities | 通过 | 通过 |
| `--uxr-codec-hevc=disabled` 的能力限制 | 通过 | 通过 |
| 不传 `--no-sandbox`，禁用硬件视频解码 | 已确认 | 已确认 |

报告：

- [通用版：ELF 哈希与基础运行](portable-package.json)
- [通用版：默认目录与真实 HEVC 解码](portable-features.json)
- [性能版：ELF 哈希与基础运行](avx2-package.json)
- [性能版：默认目录与真实 HEVC 解码](avx2-features.json)

验收范围是包结构、基本执行及新增的目录/HEVC 功能，不代表全部 224 个 persona 补丁的
完整行为验收，也没有测量或宣称 AVX2 版的性能提升。上面的 store 地址是本机产物身份，
不是远程下载地址。本次 Git 推送仅包含源码、补丁、文档、验证器和小型合成测试视频。

复测入口见 [nix/README.md](../../../nix/README.md)。Oct18 旧基线仍保留在
`chromix-result`，没有自动替换用户的启动入口。
