# Native NixOS build (Linux x64)

Build Chromium 154.0.8037.97 + the prepared ungoogled/portablelinux layers +
224 Chromix patches using nixpkgs' Chromium toolchain model:

- `pkgs.rustc.llvmPackages.stdenv` and the same LLVM for `clang_base_path`;
- target and host toolchains `//build/toolchain/linux/unbundle:default`;
- `use_sysroot = false`, with dependencies provided by Nix;
- source filtering excludes root `out/`, `.git/` and `.chromix-gn-*` directories.

The additional [Nix overlay patches](patches/README.md) provide a separate
`chromix` default profile directory, real HEVC software decoding, and an optional
x86-64-v3 performance build. They do not change the authenticated cross-platform
`patches/series`. The original FHS/compiler-wrapper experiments are historical,
not part of this build.

## Inputs

Run commands from the repository root. `chromixSrc` must be an already-prepared
M154 source tree, including its Node dependencies. Source preparation is separate
from the offline Nix sandbox build; see [BUILDING.md](../BUILDING.md) and
`build/prepare-ungoogled.sh WORKDIR linux x64`.

The default source path is `$HOME/.chromix-build/src`; assets default to this
repository's `assets/`. The default `pkgs` is the locally retained, tested
`/nix/store/b54nhac0czv6fq1wr72gna7vkjxfnbk9-source` snapshot (LLVM 21.1.8,
Rust 1.98.1). On another machine, explicitly select a compatible nixpkgs checkout:

```sh
# Add this argument to the commands below when selecting your own nixpkgs:
# --arg pkgs 'import /absolute/path/to/nixpkgs {}'
```

That checkout must provide the Chromium compatibility patches named in
`chromix.nix`; choosing a different toolchain requires its own build validation.

## Configure and build

```sh
SRC="$HOME/.chromix-build/src"
nix-instantiate --eval nix/chromix.nix -A pname

# Only bootstrap GN and generate Ninja files.
nix build -f nix/chromix.nix --arg chromixSrc "$SRC" \
  --arg configureOnly true --out-link result-configure --cores 64 -L

# Portable CPU baseline, with the new profile directory and HEVC backend.
nix build -f nix/chromix.nix --arg chromixSrc "$SRC" \
  --out-link result-portable --cores 64 -L

# Separate x86-64-v3 / O3 / stronger ThinLTO output.
nix build -f nix/chromix.nix --arg chromixSrc "$SRC" \
  --arg performanceBuild true --out-link result-avx2 --cores 64 -L
```

Both variants build `chrome`, `chrome_crashpad_handler` and `chrome_sandbox`.
The AVX2 variant requires the full x86-64-v3 CPU baseline. It keeps floating-point
contraction and libc++ hardening unchanged; no speedup is claimed without A/B
benchmarks. Start the selected output with `./result-portable/bin/chromix` or
`./result-avx2/bin/chromix`. Profiles are not automatically migrated.

## Verification

All tools below are supplied through Nix. Node >=22 provides the built-in
WebSocket client; no npm/pip installation is needed for these verifiers.

```sh
python3 nix/verify-package.py --package ./result-portable \
  --expected-version 154.0.8037.97
node nix/verify-features.mjs ./result-portable

# Local source-overlay tests; supply an existing filtered store snapshot.
CHROMIX_SOURCE_SNAPSHOT=/nix/store/EXISTING-chromix-source \
  python3 nix/tests/test_local_patches.py -v
```

Repeat package and feature verification for `result-avx2`. The feature verifier
checks the derived `chromix-headless/scoped_dir*` directory, HEVC Main/Main10
WebCodecs and HTML video decoding with expected pixels, native capability queries,
and the disabled-HEVC policy. Hardware decoding is disabled for these tests and
`--no-sandbox` is not passed. This is not full acceptance of all 224 persona patches.

## Local batch runner and checkpoints

`build-variants.sh` first checks both GN configurations, then builds and verifies
portable followed by AVX2. It preserves the accepted `chromix-result` and writes
new `chromix-next-result` / `chromix-avx2-result` links in the repository's parent
directory. Set `CHROMIX_SOURCE_SNAPSHOT` to a retained filtered store snapshot and
`CHROMIX_VARIANTS_STATE` to the desired log directory before running it.
`CHROMIX_NIX_BUILD_DIR` overrides the local `/home/chromix-nix-build` build directory.

`sourceSnapshot` reuses a filtered source input; it is not a compiled artifact.
`buildCheckpoint` is optional and explicit. Schema 2 binds source, stdenv, GN flags,
patch-content hashes and targets; old schema-1 archives are rejected.

## Verified results

Both variants completed on 2026-10-19 and were reverified on 2026-10-20:

| Variant | Full build | JS/DOM | HEVC Main/Main10 | HEVC disabled policy |
| --- | --- | --- | --- | --- |
| Portable | passed | passed | actual software decode passed | passed |
| x86-64-v3 | passed | passed | actual software decode passed | passed |

See [archived verification reports](../docs/nixos-verification/2026-10-20/README.md),
[build history](../docs/NIXOS-BUILD-STATUS.md), and
[local deviations](../docs/NIXOS-LOCAL-DEVIATIONS.md). Store paths in the reports
identify local Nix outputs, not downloadable release assets. No GitHub Release
or browser binary upload is part of this source push.
