# Chromix 内核构建：状态与续做说明

## 已完成（可复现）

| 步骤 | 产物 | 状态 |
|---|---|---|
| 源码准备 | `~/.chromix-build/src`（9.9GB，Chromium 154.0.8037.97 + ungoogled + portablelinux + **224 个 Chromix 补丁全部干净应用**） | ✅ |
| 构建 FHS 环境 | `~/rev-egolite/build-fhs.nix` → `build-fhs-result`（构造成功） | ✅ |
| LLVM 工具链 | `src/third_party/llvm-build/Release+Asserts/bin/clang++`（Chromium 自带的 clang 24） | ✅ |
| Rust 工具链 | `tools/rust/update_rust.py` 已跑 | ✅ |
| gn 自举 | 进行中 | ⚠️ |

## 当前阻塞点：gn bootstrap 找不到 C 库头文件

```
src/gn/command_gen.o: .../lib/clang/24/include/inttypes.h:24:15:
  fatal error: 'inttypes.h' file not found        ← clang 自己的头文件 #include_next 到 glibc
src/gn/command_format.o: 'string' file not found   ← libstdc++ 头文件
```

原因（已诊断确认）：

1. **FHS 里 `/usr/include/stdio.h` 不存在**。`targetPkgs` 里加了 `glibc`，但
   `lib.getDev glibc` 没有把 glibc 头文件放进 FHS 的 `/usr/include`。
2. **没有 C++ 标准库头文件**。Chromium 自带的 clang 不捆绑 libc++，
   而 clang 的搜索路径只有 `<clang-resource>/include` 和 `/usr/include`
   （实测 `clang++ -v -x c++ -E -` 的输出）。
   nix 的 libstdc++ 头文件在 `/nix/store/...-gcc-16.2.0/include/c++/16.2.0`。
3. `extraBuildCommands` 里加的 `cp -rs .../include/c++/16.2.0` 没有生效
   （实测 `/usr/include/c++/*/string` 不存在）—— 需要确认 buildFHSEnv 里
   `extraBuildCommands` 的写法（`$out` 指向、执行时机）。

## 下一步（按优先级）

1. **修好头文件**（二选一）：
   - a) 在 `build-fhs.nix` 里正确注入 glibc + libstdc++ 头文件到 `/usr/include`
     （`extraBuildCommands` 或 `profile` 里设 `CPLUS_INCLUDE_PATH` /
     `C_INCLUDE_PATH` / `CPATH`，后者最省事且不需要动 `/usr/include`）。
     clang 认 `CPATH` / `CPLUS_INCLUDE_PATH`。
   - b) 给 gn bootstrap 传 `CXXFLAGS`/`CPPFLAGS`（gn 的 `build/gen.py` 会读）。
   - 建议先试 a 的**环境变量**路线（最小改动、不需要重建 FHS）。
2. 头文件通了之后，`build/build.sh` 会继续：安装 sysroot → `gn gen` → `ninja`。
   `CHROMIX_BUILD_PROFILE=fast` 可以缩短首次编译时间。
3. 基线编译通过后，再写原生补丁（见 `Chromix-元素树实现设计.md` 第 4 节）：
   - 低风险高价值：**原生检测真实用户输入**（覆盖 `WebContentsDelegate::PreHandleMouseEvent/PreHandleKeyboardEvent`）
     → 自动 handoff，这是 CDP 做不到的。
   - 中风险：原生光标浮层（新的 Views 层 + `BrowserView` 挂载 + `content→chrome` 委托间接层，
     照 `WebContentsDelegate::GetAIPageContent` 的模式）。
   - 低优先：`SnapshotSubtree`（只影响大页面性能）。

## 复现命令

```bash
cd ~/rev-egolite
nix-build build-fhs.nix -o build-fhs-result
./build-fhs-result/bin/chromix-build-fhs -c \
  'cd ~/rev-egolite/Chromix && CHROMIX_SKIP_DEPS=1 CHROMIX_BUILD_PROFILE=fast ./build/build.sh ~/.chromix-build x64'
```

日志：`~/.chromix-build/prepare.log`（源码准备）、`~/.chromix-build/build.log`（构建）。

## 本地改动（见 `Chromix-local-deviations.md`）

`build/prepare-ungoogled.sh` 里 ARM64 patch guard 改成 arch-aware，
否则 x64 冷准备被无条件拒绝。

---

# 第二轮进展（头文件与链接器已定位）

## 新增已解决

| 问题 | 原因 | 修法 |
|---|---|---|
| `'string' file not found` | Chromium 自带 clang **不捆绑 libc++**，只搜 `<resource>/include` 和 `/usr/include` | `CPATH` 指向 libstdc++ 目录 |
| `'stdlib.h' file not found`（来自 `cstdlib` 的 `#include_next`） | **搜索顺序**：glibc 在 CPATH 里排在 C++ 目录**前面**，而 `#include_next` 只能往后走 | `CPATH=<libstdc++ 目录>`，glibc 放 `C_INCLUDE_PATH`/`CPLUS_INCLUDE_PATH`（排在后面） |
| `libz.so.1` 缺失 | 少 zlib | targetPkgs 加 `zlib` |
| `/usr/include/stdio.h` 不存在 | 需要显式加 `glibc` 进 targetPkgs | 已生效 |

## 当前唯一阻塞：clang 找不到 GCC 安装位置 → crtbeginS.o

链接行实测输出：

```
clang -v t.c
 ... /lib/../lib64/Scrt1.o /lib/../lib64/crti.o crtbeginS.o -L... -o t x.o ...
 ld.bfd: cannot find crtbeginS.o: No such file or directory
```

关键：**`crtbeginS.o` 是不带路径的裸文件名**，说明 clang 的 `GCCInstallationDetector` 没找到 GCC 安装，
于是前缀为空。而 **`ld` 的 `-L` 只用于 `-l` 查找，不用于裸文件参数**，所以 `-L<gcc 目录>` 也救不了。

已验证的解法：

```
clang --gcc-install-dir=/nix/store/5q6bdxkp7lc70gn9mnf4yiybrx8ry5xq-gcc-16.2.0/lib/gcc/x86_64-unknown-linux-gnu/16.2.0 t.c
→ LINK OK
```

## 下一步（确定的修法）

`buildFHSEnv` 的 `$out` **只有 `bin/`**（现代 buildFHSEnv 在运行时构造 chroot），
所以 `extraBuildCommands` 里写 `$out/usr/...` 不生效。正确做法是**做一个 targetPkgs 派生**：

```nix
gccLayout = pkgs.runCommand "chromix-gcc-layout" {} ''
  mkdir -p $out/lib/gcc/x86_64-unknown-linux-gnu/${pkgs.gcc.cc.version}
  for f in ${pkgs.gcc.cc}/lib/gcc/x86_64-unknown-linux-gnu/${pkgs.gcc.cc.version}/*; do
    ln -s "$f" $out/lib/gcc/x86_64-unknown-linux-gnu/${pkgs.gcc.cc.version}/
  done
'';
```

加进 `targetPkgs`，FHS 的运行时软链治理会把 `lib/gcc` 链到 `/usr/lib/gcc`，
clang 的检测器就会认出这个 GCC 安装。

之后顺序：gn 自举 → `gn gen` → `ninja`（数小时）→ 写原生补丁 → 再编译 → 测试。
预计 `gn gen` 和 `ninja` 还会暴露更多宿主机依赖缺失，属于同一类问题的重复迭代。

---

# 第三轮进展：crut 问题已解决，C 已能链接运行

## 已解决

| 问题 | 修法 | 验证 |
|---|---|---|
| clang 找不到 GCC 安装 → 裸 `crtbeginS.o` | 在 `third_party/llvm-build/Release+Asserts/bin/` 把 `clang` 换成包装脚本：`exec clang.real --gcc-install-dir=<nix gcc>/lib/gcc/x86_64-unknown-linux-gnu/16.2.0 "$@"`；`clang++` 仍是指向 `clang` 的符号链接 | **C 编译+链接+运行 OK**（输出 `c-ok`） |

坑：`clang++` 是 **指向 `clang` 的符号链接**，直接往 `clang++` 写包装会顺着链接覆盖 `clang`。
必须先 `cp clang clang.real`，再改写 `clang`，最后 `ln -sf clang clang++`。
（`--gcc-install-dir` 由于不受 buildFHSEnv 影响，是比修 `/usr/lib/gcc` 更可靠的落点；
`buildFHSEnv` 的 `$out` 只有 `bin/`，且其运行时软链治理不会链 `lib/gcc`。）

## 当前唯一剩余阻塞：C++ 链接缺 libstdc++ 符号

```
clang++ t.cc -o tcc
 ld.bfd: t.cc:(.text...basic_string...): undefined reference to
         `std::__throw_logic_error(char const*)'
```

不是 "cannot find -lstdc++"，而是**符号未定义** —— 说明链上的 libstdc++ 不对
（可能命中了 FHS `/usr/lib` 里的旧 libstdc++，而不是 `${pkgs.gcc.cc}/lib` 的那份）。

**下一步（很小的修法）**：在包装脚本里显式钉住 C++ 标准库，例如
`--gcc-install-dir=... -stdlib=libstdc++`，并确认 `LIBRARY_PATH` 的首项是
`${pkgs.gcc.cc}/lib`（现在首项是 `.../lib/gcc/.../16.2.0`，libstdc++.so 在上一级 `lib/`）。

改完这一步，gn 自举应当能完成，然后进入 `gn gen` → `ninja`（数小时）。

---

# 第四轮：编译已通，只剩头文件版本问题

## 现在能做什么

```
clang -c t.c          → compile-only OK
clang t.c && ./tc     → c-ok
clang++ t.cc && ./tcc → cpp-ok 1
```

**gn bootstrap 的头文件错误全部消失，代码真的开始编译了。**

## 本轮解决的四个问题

| 症状 | 根因 | 修法 |
|---|---|---|
| 链接行里完全没有 `-lstdc++` | clang 检查 `<gcc-install>/../../lib/libstdc++.so`，而 **nix 把 gcc 的 outputs 拆开了**，install dir 边上没有 libstdc++ | 合成布局：`~/.chromix-build/gccroot/{lib,lib/gcc/...}`，wrapper 里 `-L$R/lib -lstdc++` |
| `crtbeginS.o` 裸文件名 | 驱动没找到 GCC 安装 → 前缀为空；`ld` 的 `-L` 只对 `-l` 生效 | `--gcc-install-dir=$R/lib/gcc/.../16.2.0` |
| `-Wl,...`/`-l...` 在 `-c` 编译时被 `-Werror,-Wunused-command-line-argument` 拒 | wrapper 无脑注入链接参数 | wrapper 检查 `-c/-S/-E/-M*/-fsyntax-only`，只在链接时注入 |
| `clang++` 包装覆盖了 `clang` | `clang++` 是指向 `clang` 的**符号链接** | 先 `cp clang clang.real`，改写 `clang`，再 `ln -sf clang clang++` |

## 当前唯一阻塞：GCC 16 的 libstdc++ 头文件对 clang 24 太新

```
bits/version.h:1780: '__cpp_lib_expected' is not defined [-Werror,-Wundef]
ext/numeric_traits.h:72: keyword '__is_signed' ... [-Werror,-Wkeyword-compat]
new:140: unknown attribute '__externally_visible__' [-Werror,-Wunknown-attributes]
bits/basic_string.h:5060: user-defined literal suffixes not starting with '_' [-Werror,-Wuser-defined-literals]
bits/stl_vector.h:2231: variable '__n' set but not used [-Werror,-Wunused-but-set-variable]
```

全是 **GCC 16 头文件自己**触发的警告，被 Chromium 的 `-Werror` 变成错误。
加 `-Wno-*` 是打地鼠（每轮冒一个新的），**不是正解**。

## 正解：换用 GCC 13 的头文件

`nixpkgs` 里有 `gcc13`（13.5.0）。步骤：

```bash
nix build nixpkgs#gcc13        # 注意：路径还没落盘，必须先 build
```

然后 `gccroot` 改用 gcc13 的 `include/c++/13.5.0`（含 `x86_64-unknown-linux-gnu` 子目录）
和 `libstdc++.so`，wrapper 的 `--gcc-install-dir` 改成对应版本目录，
`build-fhs.nix` 的 `CPATH` 也指向 gcc13 的头。

（`gcc12` 在 nixpkgs 里已不可用；`gcc14` 也可作备选。）

CLI 上取的 `/nix/store/...-gcc-13.5.0` **当时并不在 store 里**，所以 glob 全空——
这是上一轮失败的直接原因：`nix eval` 只算路径，不下载。

## 之后的路线（不变）

gn 自举 → `gn gen` → `ninja`（数小时）→ 写原生补丁（光标浮层 / 自动接管检测 / 输入法）
→ 再编译 → 测试。

---

# 第五轮：GN 自举成功，进入真正的 Chromium 编译

## 重大进展

```
Done. Made 35119 targets from 4989 files in 5566ms
ninja: Entering directory `/home/bubu/.chromix-build/src/out/Chromix'
```

**gn 自举完成，`gn gen` 生成 35119 个目标，ninja 开始真正编译。**

## 本轮解决

| 症状 | 根因 | 修法 |
|---|---|---|
| **gn 自举头文件错误** | FHS 通过 CPATH 注入 **GCC 16** 头文件，对 clang 24 太新，触发 `-Werror` | 命令行 `-I` 强制 **GCC 13** 头（`-I` 优先于 CPATH）。GCC 16 头会连续触发 `-Wundef`/`-Wkeyword-compat`/`-Wunknown-attributes`/`-Wuser-defined-literals`/`-Wunused-but-set-variable` 五类告警，是打地鼠；换 GCC 13 后只剩 `-Wundef` 一类，加 `-Wno-undef` 即可 |
| `RunNode` 找不到 node | 无（node 是有的） | — |
| `` missing and no known rule: /usr/bin/tsc `` | 补丁集把"从 node_modules 解析"换成**硬编码** `tsc_binary = "/usr/bin/tsc"` | 改指向 nix `typescript` |
| 同上 `/usr/bin/esbuild` | 同样硬编码，两处 | 改指向 nix `esbuild` |

**关键实现细节**：`buildFHSEnv` 的 `profile` **不会被 `-c` 执行的命令 source**
（这就是为什么 profile 里的 `CPATH` 一直没生效、`/usr/bin` 的软链也没建）。
所以环境变量的注入必须放在 `-c` 的命令里，或者走编译器包装脚本。
另外 FHS 里 `/usr/bin` 是**只读**的，`ln -s` 到那里会失败。

## 当前阻塞：devtools-frontend 的 esbuild 平台包被裁剪

```
Failed to run esbuild: Error: The package "@esbuild/linux-x64" could not be found
```

- `third_party/devtools-frontend/src/node_modules/esbuild` 版本 = **0.25.1**
- `node_modules/@esbuild/` **不存在**（可选的平台二进制被 ungoogled 的 prune / lite tarball 裁掉了）
- nix 的 esbuild 是 0.27.2，**版本不匹配**，不能直接塞进去

正在尝试：`ESBUILD_BINARY_PATH=<nix esbuild>`（esbuild 的 JS 支持这个环境变量，
会跳过平台包解析）。若版本检查仍拦，则退回到下载 `@esbuild/linux-x64@0.25.1` 放进
`node_modules/@esbuild/linux-x64`。

## 第六轮：esbuild 通了，暴露真正的根因（两套 libstdc++ 混用）

`ESBUILD_BINARY_PATH` 生效，esbuild 报错消失。随即出现：

```
gcc-13.5.0/include/c++/13.5.0/type_traits:161: error: reference to '__enable_if_t' is ambiguous
```

**这是混用两套 libstdc++ 的典型症状**：`-I` 把 GCC 13 排在前面，但 FHS 的 `CPATH`
里还留着 GCC 16，于是包含链会跨版本回落，两套头文件的内部符号互相冲突。

**修法**：在 `-c` 的命令里**覆盖**（不是追加）`CPATH`，把 GCC 16 彻底踢出去：

```bash
export CPATH="$G13/include/c++/$V13:$G13/include/c++/$V13/x86_64-unknown-linux-gnu"
```

这也解释了前面为什么 `-I` 方案只是"看起来"成功——头文件错误一度消失，但仍埋着混用隐患。

### 修正：不能把 glibc 也一起清掉

上一版把 `C_INCLUDE_PATH`/`CPLUS_INCLUDE_PATH` 清空，导致 glibc 头文件丢失，
报出 `explicit specialization of undeclared template struct 'numeric_limits'`
并让 clang **段错误**。正确做法是**一个 CPATH 里按顺序排好**：

```bash
export CPATH="$G13/include/c++/$V13:$G13/include/c++/$V13/x86_64-unknown-linux-gnu:<glibc-dev>/include"
```

即：**libstdc++（只一套，GCC 13）在前，glibc 在后**。
`#include_next` 只能往后走，所以这个顺序是必需的。

## 第七轮结论：这条路走到头了，建议换编译器

GCC 13 头文件下仍然失败，且**不是缺 flag**：

```
gcc-13.5.0/include/c++/13.5.0/limits:797: error:
  explicit specialization of undeclared template struct 'numeric_limits'
clang: error: clang frontend command failed due to signal
clang: error: unable to execute command: Segmentation fault (core dumped)
```

`numeric_limits` 的主模板"未声明"＋**clang 自己段错误**，说明这是
**clang 24 与宿主 libstdc++ 的深层不兼容**，不是 CPATH/顺序/`-Wno-*` 能解决的。
补上 glibc 后错误一字不变，也证明与 glibc 无关。

**推荐的下一步（换掉编译器，绕开整个问题）**：

不要用 Chromium 自带的 clang + 宿主 libstdc++，改用 **nixpkgs 的 clang + 它配套的 libc++**：

```nix
# 在 build-fhs.nix 的 targetPkgs 里加
pkgs.llvmPackages.clang
pkgs.llvmPackages.libcxx
pkgs.llvmPackages.libcxxabi
```

然后让构建用 `pkgs.llvmPackages.clang`（配套 libc++ 是同一个编译器的标准库，
不存在版本错配），并相应设置 `CPLUS_INCLUDE_PATH` / `-stdlib=libc++`。

**但要注意**：Chromium 的 gn 默认按 libstdc++ 配置，切到 libc++ 需要同时在 gn args 里
调整（`use_custom_libcxx` 等），属于中等改动。所以更稳的另一条路是：
**继续用 Chromium 自带的 clang，但把 libstdc++ 换成与它匹配的版本**
（clang 24 对应 GCC 15 时代的 libstdc++，`nixpkgs` 里 `gcc15` 已有）。
即把上面所有 `gcc13` 换成 `gcc15` 再试一次——这是**最小改动**的下一步。

## 已经确认可用的部分（与内核构建无关，不受影响）

```
node test/verify.mjs       输入层    7/7
node test/verify-apc.mjs   元素树   19/19
node test/verify-ego.mjs   ego 层   16/16
```

## 第八轮：定位到真正的根因——libc++ 和 libstdc++ 同时在场

把 libstdc++ 从 GCC 13 换成 GCC 15（clang 24 的同代版本），错误**一字不变**：

```
gcc-15.3.0/include/c++/15.3.0/tuple:384: error: reference to '__enable_if_t' is ambiguous
gcc-15.3.0/include/c++/15.3.0/tuple:2405: error: reference to 'integral_constant' is ambiguous
```

**所以根本不是 libstdc++ 版本问题。**

`__enable_if_t` 和 `integral_constant` 这两个名字**libstdc++ 和 libc++ 都定义**
（libc++ 在 `__type_traits/enable_if.h` 里有 `__enable_if_t`）。
两套头文件同时在包含路径里 → 名字冲突 → ambiguous。

**为什么会混进来**：Chromium 默认使用**自己捆绑的 libc++**，位于
`buildtools/third_party/libc++/src/include`。而**这个目录在 lite tarball 里根本不存在**
（第一轮就记过：`src` 里缺 `buildtools/`）。于是：

- Chromium 的 gn 仍然按 libc++ 加包含路径（但指向空目录）
- 我的 CPATH 又把宿主 libstdc++ 塞了进来
- 某些包含链解析到 libc++、某些解析到 libstdc++ → 混用

**正确的下一步（一行 gn 参数）**：在 `Chromix/build/args.gn` 里加上

```
use_custom_libcxx = false
```

让 Chromium 使用系统 libstdc++、**不再添加任何 libc++ 包含路径**。
这是 Chromium 官方支持的配置，能一次性消除混用。

配套：clang 包装脚本里**不要**再用 `-I` 强推 C++ 头（那是投机取巧，掩盖了真正的冲突），
只保留两件真正的驱动修复——`--gcc-install-dir`（定位 crt）和 `-lstdc++`（链接 C++ 运行时），
C++ 头交给 gn + CPATH 决定。

## 九轮迭代的净结论

**已经确认可复现的**：

| 阶段 | 状态 |
|---|---|
| 源码准备（Chromium 154.0.8037.97 + 224 个 Chromix 补丁） | ✅ 干净应用 |
| LLVM（clang 24）/ Rust 工具链 | ✅ |
| FHS 构建环境（含全部运行时与开发依赖） | ✅ |
| **GN 自举** | ✅ **`Done. Made 35119 targets`** |
| **`gn gen`** | ✅ **生成 35119 个目标** |
| devtools 的 `tsc` / `esbuild` 缺失 | ✅ 已修 |
| ninja 真正开始编译 | ✅ 已进入 |
| C++ 头文件混用（libc++/libstdc++） | ❌ **当前阻塞，结论明确、修法明确** |

**这个剩余问题已完全定性**，不是"不知道怎么办"，而是一个已知的 gn 配置项。

## 第九轮：`use_custom_libcxx=false` 生效了，但每个宿主 libstdc++ 都有各自的不兼容

加上 `use_custom_libcxx = false` 后：
- ✅ **libc++/libstdc++ 混用的 `__enable_if_t is ambiguous` 彻底消失**
- ⚠️ 触发 `//v8/BUILD.gn:853` 断言：`The sandbox requires libc++ hardening`
  → 配套加 `v8_enable_sandbox = false`（官方支持的组合）
- ⚠️ 继续编译后，在 gcc15 的 `<format>` 里出现新的错误（492 条警告 + 编译失败）

**三种宿主 libstdc++ 各有各的不兼容**（都不是缺 flag）：

| 版本 | 症状 |
|---|---|
| GCC 16 | 五类警告级联（`-Wundef`/`-Wkeyword-compat`/`-Wunknown-attributes`/…），`-Werror` 放大 |
| GCC 13 | `numeric_limits` 主模板"未声明" + **clang 段错误** |
| GCC 15 | `<format>` 相关编译错误 |

**结论：不该在宿主 libstdc++ 上继续试。** 真正的解法是**用 Chromium 自己捆绑的 libc++**，
即把 lite tarball 里缺失的 `buildtools/` 补齐。

## 确定的下一步

`buildtools` 是**独立的 git 仓库**（不是 chromium/src 的一部分），lite tarball 没带它。
Chromium 默认（`use_custom_libcxx = true`）需要：

```
buildtools/third_party/libc++/src/include
buildtools/third_party/libc++abi/src/include
```

补齐方式（Chromium 的 DEPS 里就有 `buildtools` 的 pin）：

```bash
cd ~/.chromix-build/src
git clone --depth 1 https://chromium.googlesource.com/chromium/src/buildtools
# 再按 DEPS 取 libc++ / libc++abi：
#   https://chromium.googlesource.com/external/github.com/llvm/llvm-project
# 放到 buildtools/third_party/libc++/src 与 buildtools/third_party/libc++abi/src
```

然后**撤掉**两处本地 gn 覆盖（删掉 `use_custom_libcxx = false` 与
`v8_enable_sandbox = false`，恢复默认），编译器的 C++ 运行时就是
与 clang 24 配套的那一套，内部自洽——这正是正常 Chromium 构建的形态。

**这一步之后，clang 包装脚本里也可以去掉 `-I` 强推宿主 C++ 头**，
只保留 `--gcc-install-dir` 和 `-lstdc++` 这两处真正的驱动修复
（或改用 libc++ 后连 `-lstdc++` 都不需要）。

### 确认：libc++ 的"胶水"在，源文件不在

```
buildtools/third_party/libc++/
  BUILD.gn                  ← Chromium 自己的构建定义
  libcxx_headers.gni        ← 头文件清单
  __config_site             ← 配置
  __assertion_handler
  generate_libcxx_headers.py
     （没有 src/include —— 真正的 libc++ 源文件）
```

即：**Chromium 侧的接线在，llvm-project 侧的源码被 lite tarball 省掉了。**
而 `buildtools/DEPS` 里也没有对应的 pin（这一层 pin 在 chromium/src 的 DEPS 里）。

所以只需补两处源码即可回到官方默认配置：

```
buildtools/third_party/libc++/src      ← llvm-project 的 libcxx/
buildtools/third_party/libc++abi/src   ← llvm-project 的 libcxxabi/
```

版本从 `chromium/src/DEPS` 里 `third_party/libc++/src`、`third_party/libc++abi/src`
两个条目的 revision 取（和当前 154.0.8037.97 的 pin 一致）。

补上之后：
1. 删掉 `Chromix/build/args.gn` 里我加的两条（`use_custom_libcxx = false`、`v8_enable_sandbox = false`），恢复默认
2. clang 包装脚本可以去掉 `-I` 强推宿主 C++ 头
3. 剩下的就只有那两处真正的驱动修复：`--gcc-install-dir`（定位 crt）和链接 C++ 运行时

---

# 第十轮：编译推进到 2054/55743，剩最后一个链接问题

## 重大进展

```
[2054/55743] CXX obj/third_party/harfbuzz/harfbuzz/hb-ot-layout.o
```

**从第 64 个目标推进到第 2054 个**（共 55743），编译顺序已进入 harfbuzz、
libc++、libc++abi、Rust 标准库等真实 Chromium 组件。

## 本轮的关键修复（`use_sysroot = false` 是正确的方向）

| 问题 | 根因 | 修法 |
|---|---|---|
| `__enable_if_t is ambiguous`（libc++/libstdc++ 混用） | FHS 通过 **CPATH 注入 GCC 16 的 C++ 头**；Chromium 用自己的 libc++ | **`unset CPATH`**（必须显式清空，profile 不生效） |
| `__isoc23_strtoull` / `fcntl64` | 编译用 nix glibc 2.44 头、链接用 sysroot 的 glibc 2.31 库 | 加 `use_sysroot = false`，让头/库版本一致 |
| `v8_enable_sandbox` 断言 | `use_custom_libcxx=false` 后 V8 sandbox 要求 libc++ hardening | 不需要了（默认走 Chromium 自带 libc++） |
| devtools 的 `/usr/bin/tsc`、`/usr/bin/esbuild` | 补丁集把"从 node_modules 解析"换成硬编码 | 改指向 nix 包（tsc）；esbuild 装 `@esbuild/linux-x64@0.25.1` 到 node_modules |
| `Package zlib/nspr/gbm/dri not found` | FHS 的 pkgconfig 农场不全；`use_sysroot=false` 后也不再搜 sysroot | **`PKG_CONFIG_PATH` 合并三处**：<br>① sysroot 的 `usr/lib/pkgconfig` + `usr/share/pkgconfig`<br>② 17 个 nix 包的 dev pkgconfig 目录（脚本生成）<br>③ FHS 的 `/usr/lib64/pkgconfig` + `/usr/share/pkgconfig` |
| `sys/cdefs.h` 缺失 | FHS 的 `/usr/include` 不完整（无 `sys/`） | `C_INCLUDE_PATH` / `CPLUS_INCLUDE_PATH` = nix glibc-dev 的 include（2.44，与 FHS libc 2.44 一致） |

## 当前阻塞：宿主工具链接缺 libm 符号

```
ld.lld: error: undefined symbol: rint
ld.lld: error: undefined symbol: nan
ld.lld: error: undefined symbol: log2
```

出错的都是 **host tool**（`cppgen_plugin` 之类，运行时用）。
这类目标**不带 `--sysroot`**，所以 clang 包装脚本会给它们
`--gcc-install-dir=<nix gcc15>`，于是引入了与 FHS libc 2.44 不完全匹配的
libgcc/libm 组合。

**下一步（明确的修法）**：在 clang 包装脚本里对**不带 `--sysroot` 的链接**
补 `-L${pkgs.glibc}/lib -lm`（或干脆去掉 `--gcc-install-dir` 的 host 分支，
直接依赖 FHS 的 `/usr/lib`）。因为 `use_sysroot=false` 下头/库都应是 FHS 的
glibc 2.44，不该再引入 nix gcc 的 libgcc。

## 本轮新增的本地改动（第 6 项）

`Chromix/build/args.gn` 增加 `use_sysroot = false`（带注释说明理由）。
其余仍为前五轮记录的改动。

## 复现命令（当前完整版本）

```bash
cd ~/rev-egolite
SR=~/.chromix-build/src/build/linux/debian_bullseye_amd64-sysroot
GLIBC=$(ls -d /nix/store/*glibc-2.44-25-dev)/include
PCP=$SR/usr/lib/pkgconfig:$SR/usr/share/pkgconfig:\
/nix/store/sp8nbh3r8vgaj5lxv0j0awp02kcwxfj2-nspr-4.40-dev/lib/pkgconfig:\
$(paste -sd: /tmp/pcdirs.txt):/usr/lib64/pkgconfig:/usr/share/pkgconfig

./build-fhs-result/bin/chromix-build-fhs -c "
unset CPATH
export C_INCLUDE_PATH=$GLIBC CPLUS_INCLUDE_PATH=$GLIBC PKG_CONFIG_PATH=$PCP
cd ~/rev-egolite/Chromix && CHROMIX_SKIP_DEPS=1 CHROMIX_BUILD_PROFILE=fast \
  ./build/build.sh ~/.chromix-build x64"
```

（`/tmp/pcdirs.txt` 是 17 个 nix 包 dev pkgconfig 目录的清单，由
`find /nix/store -maxdepth 5 -name '<pkg>.pc'` 逐个定位后去重得到。）

---

# 第十一轮（关键转折）：nixpkgs 已经有能用的 Chromium 构建方案

代码位置（nixpkgs 内）：
```
pkgs/applications/networking/browsers/chromium/{common.nix,ungoogled.nix,browser.nix}
```
nixpkgs 源：`/nix/store/qwxy08ayap8i424l0iygmcj671h7qpgm-b54nhac0czv6fq1wr72gna7vkjxfnbk9-source`

## nixpkgs 的做法（与我前面十轮的方案根本不同）

```nix
is_official_build = true;
custom_toolchain  = "//build/toolchain/linux/unbundle:default";
host_toolchain    = "//build/toolchain/linux/unbundle:default";
use_sysroot       = false;                  # ← 我独立发现的同一条
treat_warnings_as_errors   = false;
clang_use_chrome_plugins   = false;
use_clang_modules          = false;
use_unified_system_module  = false;         # ≥150 必需，因为 /usr/include 不存在
clang_base_path   = "${llvmCcAndBintools}"; # ← 用 nixpkgs 自己的 clang！
pkg_config        = "${pkgsBuildHost.pkg-config}/bin/${stdenv.cc.targetPrefix}pkg-config";
host_pkg_config   = "${pkgsBuildBuild.pkg-config}/bin/pkg-config";
```

外加一步 **`replace_gn_files.py`**：

```bash
python3 build/linux/unbundle/replace_gn_files.py --system-libraries flac libjpeg libxml libxslt
```

它把打包在 `third_party/` 里的这些库**换成系统库**（并删掉 `third_party/<lib>` 的源码）。

## 为什么这解释了我踩的每一个坑

关键差别只有一句话：

> **nixpkgs 不用 Chromium 自带的 clang，也不用它的 sysroot。它用 nixpkgs 自己的 clang +
> Chromium 官方的 `unbundle` 工具链（专为"在 Linux 发行版上构建"设计）。**

而我这十轮一直在做的事是：**让 Chromium 自带的 clang + 它预期的构建流程，在一个它不适配的系统上跑起来**。于是每一个坑都是我自己造出来的：

| 我的坑 | 根因 | nixpkgs 为什么不会有 |
|---|---|---|
| libc++ vs libstdc++ 混用 | Chromium 自带 clang 不捆绑 libc++ | 用 `clang_base_path` 指向 nixpkgs clang（自带一致的 libc++） |
| `crtbeginS.o` / `-lstdc++` | 驱动找不到 GCC 布局 | 不需要：nixpkgs clang 由 stdenv 正确包装 |
| glibc 头/库版本错配 | 手拼环境 | **nixpkgs derivation 里一致性是构造出来的** |
| `PKG_CONFIG_PATH` 一个个补 | 农场不全 | `pkg_config` 显式指向 nixpkgs 的 pkg-config，`buildInputs` 自动提供 |
| `sys/cdefs.h` 缺失 | FHS 的 `/usr/include` 不完整 | stdenv 的 glibc 完整 |
| 硬编码 `/usr/bin/tsc|esbuild` | 补丁集改动 | 他们也有对应处理 |

**我在手工拼一个 nixpkgs 免费就有的环境。**

## 建议的方向修正（下一步该做的）

**放弃 FHS + clang 包装脚本，改写成一个 nixpkgs 派生**，以 nixpkgs 的 chromium 为模板：

1. `stdenv.mkDerivation` + 正常的 `buildInputs`/`nativeBuildInputs`（不要自建 FHS）。
2. args.gn 用 nixpkgs 那套：`custom_toolchain = unbundle`、`use_sysroot = false`、
   `clang_base_path = ${llvmPackages.clang}`、`pkg_config` 显式指定。
3. 视情况跑 `replace_gn_files.py --system-libraries`。
4. **删掉全部 clang 包装 hack**（`--gcc-install-dir`、`-lstdc++`、`-I`、`-Wno-undef`）。

预期收益：**剩余所有链接/头文件类问题基本一次性消失**，因为工具链与库的一致性由 nixpkgs 保证。
代价：需要把 Chromix 的 224 个补丁 + 构建脚本接进 nixpkgs 的构建流程。

---

# 第十二轮：原生 Nix 派生（2026-10-15）

主线仅 `chromix.nix`，不再使用 FHS 或编译器 shell 包装。

## 已诊断 / 修复

1. **小求值并未卡住**：原文件 `timeout 30s nix-instantiate --eval chromix.nix -A pname`
   直接返回 `"chromix"`（整个诊断命令约 0.44 秒）。完整实例化还会遍历、散列并导入源码，
   与只访问 pname 的惰性求值不同；不能把源码入库耗时当成语法错误。
   默认 nixpkgs 已固定到第十一轮指定的 store 路径，避免 channel/flake 漂移。
2. **源码过滤**：使用 `lib.sources.cleanSourceWith`，排除根目录 `out/`、`.git/`
   和 `.chromix-gn-*`，不删除原树；原树 `out/Chromix/gn` 保留。
   本机实测 `out/` 为 3.6GB、其余源码约 10GB（du 分开统计）。
3. **官方方案不只是四个 flag**：对照 pinned nixpkgs common.nix 补齐
   overrideCC + LLVM bintools，clang_base_path 使用官方同款 llvm + stdenv.cc 的
   symlinkJoin，确保 llvm-ar/llvm-nm 等也在同一前缀；关闭 Qt、系统 libffi、
   warning suppression mapping、strictflexarrays1，加入该版本官方 LLVM/Rust/Go 兼容补丁。
4. **GN bootstrap 输出参数错误**：bootstrap.py 的 `-o` 是文件路径而非目录；
   修成先创建 out/gn-bootstrap，再输出 out/gn-bootstrap/gn，并传 -j64。
5. **残留 FHS 路径 / 工具**：沙箱副本内恢复 clang.real 到 clang，保持 clang++ 链接；
   node 原来指向 /usr/bin/node，改用 Nix node；gperf 采用官方预期路径链接。
   tsc/esbuild 的替换改为 --replace-warn（原树已经替换的文件无需再次命中），
   设置 env.ESBUILD_BINARY_PATH 修复缺少 @esbuild/linux-x64。
6. **Rust 工具链对齐**：初始采用同一 nixpkgs rustc / rust-bindgen 的 external sysroot，
   通过源码已应用的 ungoogled Crubit fallback 避免引入 bundled Rust LLVM 24 与 Nix LLVM 21
   的 IR 混用；其余 Rust 功能保持开启。是否需要 M154 的完整官方 Crubit 流程以实测为准。

## 验证 / 日志

- `nix-instantiate --eval chromix.nix -A pname`：通过。
- `nix-instantiate --eval --strict chromix.nix -A stdenv.cc.name`：`clang-wrapper-21.1.8`。
- 新增 `configureOnly` 参数：仅跑正常 unpack/patch/configure，将 ninja 文件输出到 store，
  与正式构建共用全部工具链及 GN 参数。
- 本轮尚未修改 `Chromix/` 仓库文件，旧有 dirty 状态保持原样。

7. **额外的 nixpkgs 整树入库**：观察实例化进程 /proc/PID/fd 发现它还在遍历整个
   pinned nixpkgs。根因是 `"${pkgs.path}/.../patches"` 先把整个 path 转成带上下文的
   store 输入。改成 path 加法 `pkgs.path + "/.../patches"`，逐个 patch 作为输入，
   避免为几个补丁重新导入整个 nixpkgs。停止了诊断用的重复实例化，配置验证单独运行。
8. **空间核对**：/home 有 632GiB 可用，但默认 /build-nix 是仅 128GiB 的 tmpfs。
   本轮构建通过 `--option build-dir /home/bubu/.chromix-build/nix-tmp` 使用 /home 磁盘，
   保持 sandbox=true；不把数十 GB 对象放进 /tmp 或 /var/tmp。

9. **esbuild 缺包信息已过时，实际问题是版本与脚本覆盖**：检查原树发现
   `node_modules/@esbuild/linux-x64` 已有合法 package.json 与 0.25.1 可执行文件，
   但 nixpkgs esbuild 是 0.27.2，不能与 0.25.1 JS shim 混用（服务协议检查版本）。
   另外 scripts/build/esbuild.js 会把传入的 ESBUILD_BINARY_PATH 强行覆盖成 /usr/bin/esbuild。
   修法：把原树已有的平台包封装成带 installCheck 的 Nix 派生 chromix-esbuild-0.25.1，
   env 与脚本、GN 输入全部指向它，不下载、不装 npm、不伪造 JS 版本号。
   同时 postPatch 正规化之前留在源码中的旧 nix store tsc/esbuild 路径。
10. **迭代避免重复散列 10GB**：新增可选 sourceSnapshot 参数，接受本派生已过滤的
    store 源码路径；默认仍按 chromixSrc + cleanSourceWith 正常构建。

11. **初次实例化完成 / build-dir 权限**：过滤源码入库实测约 21 分钟，
    期间进程持续传输，最终 store 快照为
    `/nix/store/gbhrb9map7afqhgj1gqgcs7bczx6hcy5-chromix-source`（约 9.19GB 原始字节）。
    已建立 `~/.chromix-build/source-snapshot` GC root，确认无 out/，原树 GN 仍在。
    随后首个 python 环境派生报 build-dir Permission denied：/home/bubu 是 0700，
    nixbld 用户不能穿越。未放宽用户家目录权限；使用 sudo 创建 root:root 0755 的
    `/home/chromix-nix-build`，后续构建目录设为这里。依赖仍完全由 Nix 管理。
    首次日志保存在 `~/.chromix-build/nix-configure-initial.log`。

12. **GN 已在沙箱中 bootstrap 成功；首次 gn gen 报 safe_browsing/public 未定义**：
    ungoogled 补丁将默认 public 初始化放入 if(false)，但遗漏 ungoogled flags 会令
    safe_browsing_mode 仍为上游默认非零，从而执行 public +=。根因是原派生只抄了
    Chromix/build/args.gn，漏掉 build.sh 先合并的 ungoogled flags.gn。
    修成先读取 pinned nixpkgs 的 ungoogled-flags.toml（与本地 flags.gn 实测一致），
    再由本派生工具链、Chromix 特性覆盖。并保留 portablelinux 的 use_kerberos=false、
    fatal_linker_warnings=false、blink_enable_generated_code_formatting=false。
    同时补入官方 Node 最低版本兼容补丁，避免 Nix Node 24.21.0 被精确版本检查拒绝。
    esbuild-0.25.1 Nix 派生及 installCheck 已通过。

13. **gn gen 已通过（08:03 UTC）**：沙箱中输出
    `Done. Made 34876 targets from 4974 files in 6211ms`。
    configureOnly 随后误触发 ninja setup-hook 的默认 buildPhase（空字符串会退回默认实现），
    在源码根目录找不到 build.ninja。修成 dontBuild=true / dontFixup=true（仅 configureOnly），
    不影响正式构建。重跑配置证据派生，同时启动完整构建。

## 完整构建（已启动，持续跟踪）

- unit：`systemctl --user status chromix-build`
- 脚本：`/home/bubu/.chromix-build/run-nix-build.sh`
- 日志：`/home/bubu/.chromix-build/nix-build.log`
- 退出码：完成时写 `/home/bubu/.chromix-build/nix-build.exit`
- 命令：`nix build -f chromix.nix --argstr sourceSnapshot /nix/store/gbhrb9map7afqhgj1gqgcs7bczx6hcy5-chromix-source --out-link chromix-result --cores 64 --max-jobs 8 --option build-dir /home/chromix-nix-build -L --keep-failed`
- 目标：`chrome chrome_crashpad_handler chrome_sandbox`。
- 成功后入口：`/home/bubu/rev-egolite/chromix-result/bin/chromix`，实际文件在该 store 输出的 libexec/chromix。
- 源码、GN、派生修改均只在 `chromix.nix` 与 Nix 沙箱副本中；未改动 Chromix 仓库。

14. **配置证据派生已成功**：`chromix-configure-result` 指向
    `/nix/store/xrqdbnq1267rqchiwynd7l09z0pssfiw-chromix-154.0.8037.97`，
    其中 generated/build.ninja 与 args.gn 均已生成；配置命令退出 0。
15. **完整构建首次 ninja 输入检查缺 rustfmt**：rust_bindgen_root 不是仅 bindgen 包，
    GN 还期待同一 bin/ 下的 rustfmt。补齐官方 rustTools symlinkJoin
    `[ pkgs.rust-bindgen pkgs.rustfmt ]`，rust_bindgen_root 指向该前缀。
    失败构建保存在 `/home/chromix-nix-build/nix-448052-1691287185/build`。

16. **快速输入图检查通过**：在保留的失败副本（不是原始源码）中用 `nix-shell` 注入
    同一派生环境、同一 configurePhase 重新 gn gen，随后
    `ninja -n chrome chrome_crashpad_handler chrome_sandbox` 返回 0，共 56,901 步。
    日志：`~/.chromix-build/nix-local-configure.log`、`ninja-dry-run.log`。
    修复 rustTools 后重新从干净 store 源码启动正式沙箱构建。

## 2026-10-18 恢复工作与归档

- 上一目标轮：只读权限下仅核对状态，没有落盘进展；本轮写权限已恢复。
- 实测 `chromix-build.service` 为 inactive/dead、MainPID=0，且未发现对应 nix/ninja 进程。
  10 月 15 日最后一条日志停在 unpack；不把它当成仍在构建，更不当成构建成功。
- 必要派生与文档归档到 Chromix Git 仓库；工作区根路径保留为符号链接。
  已有两个 build/ 文件的本地改动不混入本次提交。

17. **必要内容已提交 / 正式进入编译**：提交 `08db2c9`，仅包含原生派生和两份文档；
    两个原有 build/ 修改保留未暂存。16:02 UTC 重启正式构建，16:07 已完成约 974/56901 步，
    实测包含 Clang 21 C++、Rust 1.98、bindgen 以及 DevTools TypeScript/esbuild actions。
    先前 rustfmt 输入缺失已消失，原生工具链实际执行通过，不只是 gn gen/dry-run。
    启动时部分外部 substituter TLS 失败后重试；另有 Nix .links 损坏链接被 daemon 自动清理，
    均未阻断依赖获取和进入编译。没有因此全局修改 Nix 配置或修复整个 store。

18. **Dawn Go 缓存写入失败（12,129/56,901）**：完整编译推进至 Tint generate_sources，
    Go 报 `failed to initialize build cache at /homeless-shelter/.cache/go-build`。
    根因是沙箱 HOME 故意不可写，调用 Go 的 Python 子进程没有可写 GOCACHE。
    在派生 preBuild 中显式 export `GOCACHE=$TMPDIR/go-cache`、`GOPATH=$TMPDIR/go` 并创建目录。
    在保留的失败副本、相同 Nix 环境中单独运行 generate-sources-gn.py 已返回 0，
    并确认生成 enums.h；GOPROXY=off / GOTOOLCHAIN=local 保持，不引入联网构建。
    复现日志 `~/.chromix-build/dawn-generator-test.log`。失败副本保留在
    `/home/chromix-nix-build/nix-3288575-3693464837/build`。

19. **修复后已跨过 Dawn 失败点，继续编译（2026-10-18 16:58 UTC）**：
    - 提交 `16fdf57` 固化 Go 缓存修复。
    - 正式沙箱日志中 Tint generate_sources 在 12,322/56,901 成功完成。
    - 当前已推进至约 21,593/56,901（V8），最新日志未出现 FAILED/error。
    - 实测服务 active，MainPID=3445835；不是仅依据日志或 running 状态文件判断。
    - `/home` 仍有约 558GiB 可用。正式构建保持 LLVM 21 / ThinLTO / official build，未降级目标。
    - 最终 `chromix-result` 尚不存在，编译、链接、安装及运行验证尚未完成；目标保持 active。
    - 后续从同一个 chromix-build.service 继续观察，不因单次观察超时另起重复构建。

20. **运行时清单审计 / 不重编的外层打包**：对照 pinned nixpkgs browser.nix/common.nix
    以及 Chromix/build/linux/package-linux.sh，发现初版 installPhase 漏装 libvulkan.so.1、
    vk_swiftshader_icd.json，且缺少官方对 dlopen 库的 RPATH 收尾。源码编译仍正常进行。
    增加独立外层 Nix 运行时包，保留现有 LLVM 编译派生为 passthru.unwrapped：
    - 系统 vulkan-loader、源树 SwiftShader ICD 模板（只替换 library_path）；
    - 给 chrome/libGLESv2 加包内路径及 libGL/vulkan-loader/pciutils RPATH；
    - Chromix 原有字体资产及 XDG 可写字体缓存、两份许可证；
    - 最终 launcher 指向外层 ELF，不再误用旧 unwrapped 的绝对链接；
    - installCheck 验证三个可执行文件、资源、快照、locale 及 --version。
    **关键证据**：调整后的 `unwrapped.drvPath` 仍精确等于正在构建的
    `/nix/store/661bpim74p2ffizshvqpp8vcq0ikvy69-chromix-154.0.8037.97.drv`，
    未改变其编译参数或重启编译。外层待该编译成功后再执行，尚未宣称运行验证通过。
    注意 nixfmt 默认会替换符号链接：已恢复根路径链接，后续一律 --follow-symlinks。

21. **外层运行时预检（不替代最终浏览器测试）**：从当前活跃沙箱读取实际 GN 生成的
    vk_swiftshader_icd.json，与外层模板替换后的 JSON 逐字段比较完全一致：
    library_path=./libvk_swiftshader.so、api_version=1.0.5。
    已求值的 installPhase/postFixup/installCheckPhase 三段脚本 bash -n 全部通过。
    使用 Nix 已安装的 fontconfig 与实际入 store 的字体目录进行 fc-match，Arial 匹配通过，
    缓存落入指定 XDG_CACHE_HOME，而不是 store。证据在
    `~/.chromix-build/runtime-phase-check/`。正式 Chromium 编译仍为同一 PID，未重启。

22. **31,361/56,901 步遇到 protoc 插件 shebang**：protoc 直接 exec
    `tools/protoc_wrapper/protoc-gen-ts_proto.py`，文件存在且可执行，但其
    `#!/usr/bin/env python3` 在 Nix 沙箱中找不到 /usr/bin/env，因此被报告为 program not found。
    对照官方 common.nix 补齐 postPatch 的 patchShebangs --build .，同时保留官方对
    native_client / harfbuzz makefile / run_deno 的准备处理；不再只修 node/tsc/esbuild。
    在失败副本、同一 Nix 原生环境执行完整 postPatch 后重跑原始 protoc_wrapper 命令，
    返回 0，并生成 1.2MB 的 perfetto_config.ts。日志 `~/.chromix-build/protoc-plugin-test.log`。

23. **显式原生 Nix checkpoint（不混入旧 FHS out）**：为避免重编已完成的约 31k 步，
    从刚刚失败的 Nix 沙箱副本只归档 out/，新增可选 buildCheckpoint 参数（默认 null）。
    archive 加入输入 manifest，恢复时强制核对 source store path、stdenv、GN flags SHA256
    和完整三个构建目标，GN 再生成、Ninja 正常做依赖与命令失效检查。
    - 来源：`/nix/store/661bpim74p2ffizshvqpp8vcq0ikvy69-chromix-154.0.8037.97.drv`
    - 来源目录：`/home/chromix-nix-build/nix-3445914-2203529230/build/chromix-source`
    - 实际 args.gn 与上述 derivation 的 configurePhase GN 参数解析比对一致。
    - 原 out/ 6.6GiB，tar.zst 约 1.3GiB；Nix store 显式输入：
      `/nix/store/rr0glb2j6qzzylgw7fdn8qgyac3l1n3a-checkpoint-661.tar.zst`
    - GC root：`~/.chromix-build/build-checkpoint`。
    - 主源码过滤规则不变，out/ 依旧排除；默认不传 checkpoint 仍从源码干净构建。
    - 归档/manifest 证据在 `~/.chromix-build/checkpoints/`；没有复用旧 FHS/包装 clang 产物。

24. **构建入口归档**：新增 `nix/build-local.sh`，发现 state 目录中已固定的 source/checkpoint
    时显式传给 chromix.nix；日志打印选择结果，EXIT trap 记录真实状态，最终检查 --version。
    原 `~/.chromix-build/run-nix-build.sh` 改为指向该已跟踪脚本的链接。
    运行方式仍是 systemd 用户服务后台运行、64 并发、/home/chromix-nix-build 磁盘沙箱目录。
    当前脚本默认构建的是带运行时层的完整包，不是仅 unwrapped。

25. **Checkpoint 恢复及 shebang 修复已在正式沙箱验证（18:05 UTC）**：
    日志输出 `Reusing native Nix checkpoint from ...661bpim...drv`，GN bootstrap 无需重编，
    gn gen 仍生成 34,876 targets。Ninja 待做图从完整 56,901 步降至约 27,294 步，
    后续动态收敛至 26,771；这不是裁减构建目标，而是正常复用已完成对象。
    原失败目标 `traces_internals:config_proto_gen` 在本轮第 197 步成功完成，
    当前已进入后续 Blink WebAudio 与 Chromium 组件编译。
    unit active/MainPID=3998182，ninja PID=4051719；仍是同一套原生 LLVM/unbundle 工具链。
    本轮编译 drv 为 `/nix/store/psrspzjjbndhbh0q8pvmwfq8lzpzj6p4-chromix-154.0.8037.97.drv`，
    外层包 drv 为 `/nix/store/7wxwkyh5rz64b6wkkj7dfkrjcs7jw8c9-chromix-154.0.8037.97.drv`。
    最终产物尚未出现，继续检查后续编译、链接与安装；完整目标不变。

26. **最终验证入口准备（尚未当作浏览器已通过）**：新增 `nix/verify-package.py`。
    与 portable ZIP 的严格目录验证器分开，按实际 Nix store 结构验证：
    store 注册、三个 x86_64 ELF 及 SHA256、资源/locale/快照、运行库/ICD、字体与许可证，
    然后执行真实 --version 和带同步 JavaScript DOM 标记的 headless 页面。
    不传 --no-sandbox、不读取现有用户 profile，超时清理整个测试进程组；输出 JSON 证据。
    当前只验证了脚本语法、非 store 路径拒绝、辅助进程正常退出与超时清理，
    **没有以这些预检替代最终产物的运行测试**。待构建成功后执行：
    `python3 Chromix/nix/verify-package.py --package ./chromix-result --expected-version 154.0.8037.97 > ~/.chromix-build/nix-package-verification.json`

27. **OpenXR Vulkan headers 依赖遗漏（恢复后 11,931 步附近）**：多个 OpenXR .cpp 报
    xr_dependencies.h:80: `vulkan/vulkan.h file not found`。头文件并非缺少，已在
    `third_party/vulkan-headers/src/include`，而非旧 vulkan-deps 子目录。
    GN 的 openxr_core_headers/openxr 公开 XR_USE_GRAPHICS_API_VULKAN，却未公开依赖 Vulkan
    headers 目标，导致自身及头文件消费者缺少 include config。
    添加局部 GN 补丁：Linux 下这两个目标 public_deps 指向现成
    `//third_party/vulkan-headers/src:vulkan_headers`。不关闭 OpenXR，不拼全局 include path，
    不额外注入可能改变所有编译单元环境的 system Vulkan SDK；补丁 dry-run 通过。
    公共依赖的 include/config 变化由 GN/Ninja 追踪，受影响的消费者会正常重编。

28. **更新严格沙箱来源 checkpoint**：来源为本轮失败 Nix build
    `/nix/store/psrspzjjbndhbh0q8pvmwfq8lzpzj6p4-chromix-154.0.8037.97.drv`，
    保存已完成的前约 43k 步，来源目录 `/home/chromix-nix-build/nix-3998250-3655673972/build/chromix-source`。
    首次普通用户归档遇到部分 0600 生成文件/0700 ThinLTO 缓存权限，tar 退出 2；该不完整归档
    没有选为构建输入。随后 sudo 只读归档该已停止的失败目录，tar 返回 0、zstd --test 通过。
    使用完整归档 `/nix/store/gmi8nx95r17iyqqyxniwcvzxm0lpjjk1-checkpoint-psrsp-root.tar.zst`
    （约 1.6GiB，展开 8.29GB），GC root `~/.chromix-build/checkpoint-psrsp`，
    build-checkpoint 别名已指向它。source/stdenv/GN flags/targets manifest 仍逐项匹配。
    未把宿主机试编译对象混入 checkpoint；归档来自实际 Nix 沙箱的 out/。

29. **OpenXR 修复已在正式沙箱验证（18:56 UTC）**：提交 `87cc4e9`。
    恢复 psrsp checkpoint 的 manifest 校验通过，待做图约 16,634 步；源码目标总量及
    chrome/chrome_crashpad_handler/chrome_sandbox 三目标未改变。
    先前失败的 filesystem_utils、loader_properties、xr_generated_loader、loader_instance、
    runtime_interface、api_layer_interface、manifest_file、loader_core 等 OpenXR 单元
    均出现成功 CXX 完成记录，证实 Vulkan public_deps 生效，而不是关闭该功能。
    当前服务 active/MainPID=91625，后续编译继续进行。最终包仍待链接、安装及实际运行测试。
