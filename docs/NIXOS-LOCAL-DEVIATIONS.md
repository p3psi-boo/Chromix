# 对 Chromix 克隆做的本地改动

## 1. `build/prepare-ungoogled.sh` — ARM64 patch guard 改成 arch-aware

原代码：

```bash
if [ "$PLATFORM" = linux ]; then
  # Recovery payloads are bound to exact pins and independently checked bytes.
```

它检查 `fix-compiling-on-arm64.patch` 的字节哈希是否在白名单里，而白名单只列了
152 和 153 两个 pin。结果是 **154.0.8037.97 的冷准备被无条件拒绝**，尽管这个
patch repair 与 x64 构建毫无关系（guard 忘了检查 `$ARCH`）。

改成：

```bash
if [ "$PLATFORM" = linux ] && [ "${ARCH:-x64}" != "x64" ]; then
```

**影响范围**：仅让 x64 冷准备能继续；arm64 路径的行为完全不变。
原始文件备份在 `/tmp/prepare-ungoogled.sh.orig`。

## 2. 构建环境（不在 Chromix 仓库内）

`~/rev-egolite/build-fhs.nix` 是自建的 buildFHSEnv，用于在 NixOS 上编译 Chromix。
它不是对 Chromix 的改动，只是构建环境。当前阻塞在 C 库头文件注入，见 `BUILD-STATUS.md`。

## 3. `devtools-frontend` 的 `tsc` 路径

构建时 ninja 报：

```
ninja: error: '../../../../../../usr/bin/tsc', needed by
  'gen/third_party/devtools-frontend/src/inspector_overlay/common.js',
  missing and no known rule to make it
```

根因：补丁集把 devtools-frontend 里"从 `node_modules` 解析 tsc"的逻辑
换成了**硬编码**：

```
third_party/devtools-frontend/src/scripts/build/typescript/typescript_vars.gni:9:  tsc_binary = "/usr/bin/tsc"
third_party/devtools-frontend/src/third_party/typescript/typescript.py:13:    return "/usr/bin/tsc"
```

而 FHS 里 `/usr/bin` 是只读的符号链接农场，且不暴露 `typescript` 包。
本地改为指向 nix 的 `typescript`（原文件备份在 `/tmp/typescript_vars.gni.orig`、`/tmp/typescript.py.orig`）。

## 4. clang 驱动包装（在 `third_party/llvm-build/Release+Asserts/bin/`）

`clang.real` 是原二进制；`clang` 被换成脚本（`clang++` 仍是指向 `clang` 的符号链接）。
脚本做三件 Nix 专属的事：

1. `--gcc-install-dir=<合成 GCC 布局>`：nix 没有 clang 能自动识别的 GCC 安装布局，
   且把 gcc 的 outputs 拆开了，导致驱动输出裸 `crtbeginS.o`（`ld` 的 `-L` 只对 `-l` 生效）。
2. `-Wl,--no-as-needed -L... -lstdc++`：因为上一条，驱动**完全不链接 C++ 运行时**。
3. `-I<GCC 13 头文件>`：FHS 通过 CPATH 注入 GCC 16 的头，对 clang 24 太新，会触发
   Chromium 的 `-Werror`。命令行 `-I` 优先于 CPATH。
   （另加 `-Wno-undef`：libstdc++ 的 `<math.h>` 用 `#if __STDCPP_WANT_MATH_SPEC_FUNCS__`。）

链接参数只在真正链接时注入，否则 Chromium 的 `-Werror,-Wunused-command-line-argument` 会拒。

## 5. `devtools-frontend` 的 `esbuild` 路径（同 tsc，就地修掉）

```
third_party/devtools-frontend/src/scripts/build/ninja/bundle.gni:38:      _esbuild = "/usr/bin/esbuild"
third_party/devtools-frontend/src/scripts/build/typescript/typescript.gni:193:  _esbuild = "/usr/bin/esbuild"
```

同一类问题（硬编码宿主机路径）。已改为 nix 的 `esbuild`。
全树扫描确认这是 devtools-frontend 里**最后两处**这类硬编码
（其余 `/usr/bin/` 命中都在 `build/linux/unbundle/*`（未启用的 unbundle 配置）、
python sysroot、installer、chromeos 测试里，与本构建无关）。

## 6. 第十二轮：原生 Nix 派生和构建记录（2026-10-18 归档）

- `nix/chromix.nix`：LLVM stdenv / unbundle / use_sysroot=false 的原生 Nix 构建，
  包含已准备源码过滤、工具路径修复、匹配版本的 esbuild 包装及配置验证模式。
- `docs/NIXOS-BUILD-STATUS.md`：完整构建过程及已验证的错误与修复记录。
- 本文件归档为 `docs/NIXOS-LOCAL-DEVIATIONS.md`。
- 工作区原路径 `chromix.nix`、`BUILD-STATUS.md`、`Chromix-local-deviations.md`
  均保留为指向上述仓库内文件的符号链接，后续修改只有一份。
- 前述 FHS 与 clang wrapper 仅为历史记录；当前 Nix 派生不使用它们。
- 已有 `build/args.gn` 和 `build/prepare-ungoogled.sh` 改动保持原样，不包含在本次新增文件提交中。

### 原生 Nix 后续修复

- 2026-10-18：`nix/chromix.nix` 的 preBuild 为 Dawn 的 Go 子进程配置
  `$TMPDIR/go-cache` / `$TMPDIR/go`，不使用不可写的 `/homeless-shelter`，保持离线依赖策略。
- 2026-10-18：`nix/chromix.nix` 增加独立运行时包装层，补齐 Vulkan loader / SwiftShader
  ICD、dlopen RPATH、字体和许可证，并设置产物 installCheck；原编译派生作为 unwrapped
  暴露，实测 drvPath 未变化，因此不触发 Chromium 重编。根目录别名保持为符号链接。
- 2026-10-18：补齐原生 Nix postPatch 的全树 patchShebangs（解决 protoc 直接执行 Python
  插件的 /usr/bin/env 缺失），增加带输入一致性校验的可选原生 checkpoint；默认干净构建不变。
  新增 `nix/build-local.sh` 保存真实后台构建命令，状态及入口检查都在脚本内；旧 FHS 不参与。
- 2026-10-18：新增 `nix/verify-package.py`，按 Nix store 产物结构检查三个 ELF、资源与
  运行时文件，再运行版本及 JavaScript/DOM 冒烟测试；不会将预检或占位结果记成最终成功。
- 2026-10-18：`nix/chromix.nix` 内联局部 GN 补丁，为 Linux OpenXR 的公开头文件和
  组件目标补上 Vulkan headers 的 public_deps；沿用已准备源码内的官方 headers 目标，
  不关闭功能，也不改变其他模块的全局 Nix include 环境。
- 2026-10-18：原生派生安装 chrome_sandbox 改为普通可执行权限（755），与官方 Nix
  构建阶段不设置 setuid 的方式一致；不在不可变 store 中通过 sudo 人工修补权限。
