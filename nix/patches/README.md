# Native Nix source overlay (Chromium 154.0.8037.97, Linux x64)

These patches are applied **after** the prepared ungoogled / portablelinux /
224-patch Chromix source, inside the Nix sandbox. The prepared source and the
authenticated cross-platform `patches/series` stay unchanged.

## Provenance and scope

- Reference: RobRich999/Chromium_Clang at
  `27eac50e18b2ea401424e976615fd678114e1564`, `Linux/linux64-avx2.patch`.
  <https://github.com/RobRich999/Chromium_Clang/tree/27eac50e18b2ea401424e976615fd678114e1564/Linux>
- FFmpeg reference: StaZhu/enable-chromium-hevc-hardware-decoding at
  `027325135a14413f54cbd8bdbfcfbc2ce3ba3eb2`,
  `add-hevc-ffmpeg-decoder-parser.cjs` and `enable-hevc-ffmpeg-decoding.patch`.
  Adaptations retain the MIT notice in `LICENSE.StaZhu`; existing Chromium and
  FFmpeg code retains its own license.
  <https://github.com/StaZhu/enable-chromium-hevc-hardware-decoding/tree/027325135a14413f54cbd8bdbfcfbc2ce3ba3eb2>

| Patch | Scope |
| --- | --- |
| `chromix-user-data-directory.patch` | Linux default profile basename becomes `chromix`; explicit user-data-dir still wins. No automatic migration of existing profiles. |
| `chromix-ffmpeg-hevc-linux-x64.patch` | Chrome/Linux/x64 C and NASM configuration, decoder/parser registration, three collision-free wrapper files, and complete HEVC C/assembly source lists. Other platform configurations stay unchanged. |
| `chromix-hevc-decoder.patch` | Software decoder selection, thread count, FFmpeg whitelist, and supported profile queries. Retains native color-space validation, platform fallback, and the existing Uxr codec restriction path. Does not fabricate encoding capability. |
| `chromix-performance-avx2.patch` | Opt-in only: C/C++ and Rust x86-64-v3, generic tuning, optimize_max O3, ThinLTO optimization level 2 and codegen level 3. No `-march=native`, Zen-specific tuning, fast-math, FP contraction changes, Polly, warning suppression or libc++ hardening changes. |
| `openxr-linux-vulkan-headers.patch` | Existing Nix OpenXR public header dependency fix, moved unchanged in behavior from the inline expression. |

No MV2 patch is added: the prepared source already preserves legacy extensions.
No Wayland log-only change, distro `/usr/lib` broker paths, deb/rpm packaging
changes, or WebRTC H.265 layered-encoding default changes are imported.

## Build and verification

Portable is the default. Pass `--arg performanceBuild true` for a distinct
`chromix-avx2` output. Both retain the native LLVM/unbundle toolchain and disable
Chromium's Debian sysroot. The performance output requires the full x86-64-v3
baseline, not merely the AVX2 CPUID bit. A speed improvement is not asserted
without comparable benchmarks.

`nix/tests/test_local_patches.py` applies both entire Nix patch stacks to sparse
copies, including official nixpkgs compatibility patches, without editing the
prepared tree. `nix/verify-features.mjs` runs the finished browser through CDP
using Node's built-in WebSocket implementation. It checks the default directory
through M154's derived `chromix-headless/scoped_dir*` container,
real Main/Main10 software-preferred WebCodecs decode and pixel output, HTML video
decode, capability queries, and the disabled-HEVC policy. No `--no-sandbox` flag
is passed. Passing source checks or GN is not runtime feature acceptance.

`nix/tests/test_feature_verifier.py` optionally accepts CHROMIX_BASELINE_PACKAGE
pointing to the old pre-feature package. Two negative tests ensure that an old
default directory and the old missing HEVC software backend are rejected, even
when a test fixture claims the new metadata. They do not validate new features.

Native checkpoint schema 2 binds source, toolchain, GN arguments **and patch
content hashes**. Old schema-1 checkpoints are intentionally rejected. The
runner restores checkpoints only when explicitly requested.
