# Chromix — built the way nixpkgs builds chromium.
#
# The point of this file is to stop fighting Chromium's bundled clang and its
# Cloud-Storage sysroot. nixpkgs' chromium derivation shows the supported way to
# build Chromium on a Linux distribution, and it comes down to four things (see
# pkgs/applications/networking/browsers/chromium/common.nix):
#
#   1. an LLVM *stdenv* (stdenv = pkgs.rustc.llvmPackages.stdenv), so the
#      compiler and its C++ standard library are consistent by construction;
#   2. clang_base_path pointing at that same LLVM, so gn's unbundle toolchain
#      uses nixpkgs' clang instead of third_party/llvm-build;
#   3. custom_toolchain/host_toolchain = "//build/toolchain/linux/unbundle:default",
#      Chromium's official "build against system libraries" toolchain;
#   4. use_sysroot = false, so nothing reaches for the downloaded bullseye sysroot.
#
# That removes the need for every workaround this project previously carried: no
# --gcc-install-dir, no -lstdc++, no -I of host libstdc++, no -Wno-undef, no
# hand-assembled PKG_CONFIG_PATH, no buildFHSEnv, no clang wrapper script.
#
# The source used here is the already-patched tree (Chromium 154.0.8037.97 +
# ungoogled + portablelinux + all 224 Chromix patches). Point `chromixSrc` at
# that tree to iterate quickly; swap in fetchgit + applyPatches for a clean build.

{
  pkgs ?
    import /nix/store/qwxy08ayap8i424l0iygmcj671h7qpgm-b54nhac0czv6fq1wr72gna7vkjxfnbk9-source
      { },
  # Pre-patched source tree, as produced by Chromix/build/prepare-ungoogled.sh.
  chromixSrc ? /home/bubu/.chromix-build/src,
  chromixAssets ? /home/bubu/rev-egolite/Chromix/assets,
  # Bootstrap gn from the source tree rather than taking nixpkgs' gn: Chromium's
  # gn must match the tree it is generating for.
  bootstrapGn ? true,
  # Stop after gn gen, retaining the generated files for a sandboxed smoke test.
  configureOnly ? false,
  # Reuse a previously filtered store snapshot while iterating on build flags.
  sourceSnapshot ? null,
  # Optional tar.zst of out/ from this same native Nix build, never an FHS out/.
  buildCheckpoint ? null,
}:

let
  inherit (pkgs) lib;

  # (1) The same stdenv choice nixpkgs' chromium makes.
  llvmPackages = pkgs.rustc.llvmPackages;
  stdenv = pkgs.overrideCC llvmPackages.stdenv (
    llvmPackages.stdenv.cc.override { inherit (llvmPackages) bintools; }
  );
  llvmCcAndBintools = pkgs.symlinkJoin {
    name = "chromix-llvm-toolchain";
    paths = [
      llvmPackages.llvm
      stdenv.cc
    ];
  };
  rustTools = pkgs.symlinkJoin {
    name = "chromix-rust-tools";
    paths = [
      pkgs.rust-bindgen
      pkgs.rustfmt
    ];
  };
  # esbuild's JS service protocol requires exactly the same binary version.
  # The prepared tree already includes the 0.25.1 platform package; package it
  # with Nix rather than mixing it with nixpkgs esbuild 0.27.2.
  esbuildChromix = pkgs.stdenvNoCC.mkDerivation {
    pname = "chromix-esbuild";
    version = "0.25.1";
    src = chromixSrc + "/third_party/devtools-frontend/src/node_modules/@esbuild/linux-x64";
    dontBuild = true;
    installPhase = ''
      install -Dm755 bin/esbuild "$out/bin/esbuild"
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      test "$("$out/bin/esbuild" --version)" = "$version"
    '';
  };
  chromiumPatches = pkgs.path + "/pkgs/applications/networking/browsers/chromium/patches";

  version = "154.0.8037.97";
  buildPath = "out/Release";

  # Third-party libraries handed to the system instead of the copies vendored in
  # third_party/. Mirrors nixpkgs' gnSystemLibraries. ffmpeg and snappy stay
  # bundled exactly as they do there — Chromix needs the Chrome-branded ffmpeg
  # for proprietary_codecs.
  gnSystemLibraries = [
    "flac"
    "libjpeg"
    "libxml"
    "libxslt"
  ];

  # Serialise Nix values into GN literals; same helper nixpkgs' chromium uses.
  mkGnFlags =
    let
      mkGnString = value: "\"${lib.escape [ "\"" "$" "\\" ] value}\"";
      sanitize =
        value:
        if value == true then
          "true"
        else if value == false then
          "false"
        else if lib.isList value then
          "[${lib.concatMapStringsSep ", " sanitize value}]"
        else if lib.isInt value then
          toString value
        else if lib.isString value then
          mkGnString value
        else
          throw "Unsupported type for GN value '${toString value}'.";
      toFlag = key: value: "${key}=${sanitize value}";
    in
    attrs: lib.concatStringsSep " " (lib.attrValues (lib.mapAttrs toFlag attrs));

  # (2)+(3)+(4): nixpkgs' toolchain flags, then Chromix's own identity flags.
  gnFlags = mkGnFlags (
    (lib.importTOML (
      pkgs.path + "/pkgs/applications/networking/browsers/chromium/ungoogled-flags.toml"
    ))
    // {
      # --- toolchain: use the system one, the way nixpkgs does ----------------
      # Build against system libraries instead of the downloaded sysroot.
      use_sysroot = false;
      # Chromium's official "unbundle" toolchain: build on a Linux distribution.
      custom_toolchain = "//build/toolchain/linux/unbundle:default";
      host_toolchain = "//build/toolchain/linux/unbundle:default";
      # Our clang, not Chromium's bundled one. This is what keeps clang and its
      # C++ runtime in lockstep and removes the libc++/libstdc++ ambiguity.
      clang_base_path = "${llvmCcAndBintools}";
      clang_use_chrome_plugins = false;
      use_clang_modules = false;
      # Chromium >=150 expands "${sysroot}/usr/include" for the unified module
      # map, and that path does not exist when use_sysroot is false.
      use_unified_system_module = false;
      use_qt5 = false;
      use_qt6 = false;
      clang_warning_suppression_file = "";
      use_system_libffi = true;
      # The ungoogled patch set retains C++ fallbacks when external Rust disables
      # Crubit. Keep Rust on the same nixpkgs LLVM as the C/C++ linker.
      rust_sysroot_absolute = "${pkgs.rustc}";
      rust_bindgen_root = "${rustTools}";
      rustc_version = pkgs.rustc.version;
      enable_rust = true;
      # Our clang is older than Chromium's, so its extra warnings are noise.
      treat_warnings_as_errors = false;
      # Point gn at pkg-config explicitly instead of relying on the sandbox.
      pkg_config = "${pkgs.buildPackages.pkg-config}/bin/pkg-config";
      host_pkg_config = "${pkgs.buildPackages.pkg-config}/bin/pkg-config";

      # --- build shape --------------------------------------------------------
      is_official_build = true;
      is_component_build = false;
      is_debug = false;
      dcheck_always_on = false;
      symbol_level = 0;
      blink_symbol_level = 0;
      chrome_pgo_phase = 0;

      # --- platform -----------------------------------------------------------
      target_cpu = "x64";
      v8_target_cpu = "x64";
      target_os = "linux";
      host_cpu = "x64";
      host_os = "linux";

      # --- Chromix's own identity / feature flags -----------------------------
      # Proprietary codecs plus Chrome ffmpeg branding, so
      # canPlayType('video/mp4') answers "probably" (stock Chromium answers "").
      proprietary_codecs = true;
      ffmpeg_branding = "Chrome";
      # De-branded at build time; the Google Chrome identity is applied at runtime
      # through the --uxr-* switches.
      is_chrome_branded = false;
      # Widevine CDM adapter compiled in; the CDM itself is fetched at runtime
      # (tools/fetch-widevine.py + --uxr-widevine-cdm). The persona claims Google
      # Chrome, so EME support has to exist.
      enable_widevine = true;

      # --- optional desktop integrations, as nixpkgs enables them -------------
      use_gio = true;
      rtc_use_pipewire = true;
      use_cups = true;
      use_kerberos = false;
      fatal_linker_warnings = false;
      blink_enable_generated_code_formatting = false;
    }
  );
  unwrapped = stdenv.mkDerivation (finalAttrs: {
    pname = "chromix";
    inherit version;
    src =
      if sourceSnapshot != null then
        builtins.storePath sourceSnapshot
      else
        lib.sources.cleanSourceWith {
          name = "chromix-source";
          src = chromixSrc;
          filter =
            path: type:
            let
              relative = lib.removePrefix (toString chromixSrc + "/") (toString path);
              top = builtins.head (lib.splitString "/" relative);
            in
            !(builtins.elem top [
              "out"
              ".git"
            ])
            && !(lib.hasPrefix ".chromix-gn-" top);
        };

    patches =
      map (name: chromiumPatches + "/${name}") (
        [
          "chromium-150-rust.patch"
          "chromium-136-nodejs-assert-minimal-version-instead-of-exact-match.patch"
          "chromium-151-dawn-use-Go-from-PATH.patch"
          "chromium-142-bytemuck-rust-1.95.patch"
        ]
        ++ lib.optionals (lib.versionOlder llvmPackages.llvm.version "23") [
          "chromium-147-llvm-22.patch"
          "chromium-153-llvm-22.patch"
        ]
      )
      ++ [
        (pkgs.writeText "openxr-linux-vulkan-headers.patch" ''
          --- a/third_party/openxr/BUILD.gn
          +++ b/third_party/openxr/BUILD.gn
          @@ -30,6 +30,9 @@
                 "src/src/common/hex_and_handles.h",
               ]
           
          +    if (is_linux) {
          +      public_deps = [ "//third_party/vulkan-headers/src:vulkan_headers" ]
          +    }
               public_configs = [ ":config" ]
             }
           
          @@ -157,6 +160,9 @@
           
               deps = [ "//third_party/jsoncpp" ]
           
          +    if (is_linux) {
          +      public_deps = [ "//third_party/vulkan-headers/src:vulkan_headers" ]
          +    }
               public_configs = [ ":config" ]
           
               defines = [
        '')
      ];
    hardeningDisable = [ "strictflexarrays1" ];

    # Chromium's build scripts call gn/ninja/python directly; nixpkgs' list is the
    # reference for what a working environment needs.
    nativeBuildInputs =
      with pkgs;
      [
        ninja
        bashInteractive # buildPhase -> process_template uses compgen
        pkg-config
        (python3.withPackages (p: [
          p.requests
          p.setuptools
          p.ply
          p.jinja2
        ]))
        perl
        which
        bison
        gperf
        zstd
        nodejs
        go # third_party/dawn/tools/generate-sources-gn.py
        cargo
        rustc
        rust-bindgen
        llvmPackages.bintools
      ]
      ++ lib.optional (!bootstrapGn) pkgs.gn;

    buildInputs = with pkgs; [
      (libopus.override { withCustomModes = true; })
      bzip2
      flac
      speex
      libevent
      expat
      libjpeg
      snappy
      libcap
      minizip
      libwebp
      libusb1
      re2
      ffmpeg
      libxslt
      libxml2
      nasm
      nspr
      nss
      util-linux
      alsa-lib
      libkrb5
      glib
      gtk3
      dbus-glib
      libxscrnsaver
      libxcursor
      libxtst
      libxshmfence
      libGLU
      libGL
      dri-pkgconfig-stub
      libgbm
      pciutils
      protobuf
      speechd-minimal
      libxdamage
      at-spi2-core
      pipewire
      libva
      libdrm
      wayland
      libxkbcommon
      curl
      libepoxy
      libffi
      libevdev
      systemd
      libgcrypt
      cups
      libpulseaudio
    ];

    # Chromix's patch set replaces devtools-frontend's "resolve tsc/esbuild from
    # node_modules" logic with hardcoded /usr/bin paths, which never exist in the
    # nix store. Point them at nixpkgs' packages instead.
    postPatch = ''
      # Discard the old FHS wrapper in the sandbox copy only. The unbundle
      # toolchain uses stdenv; ancillary probes should see the original binary.
      if [ -f third_party/llvm-build/Release+Asserts/bin/clang.real ]; then
        cp -f third_party/llvm-build/Release+Asserts/bin/clang.real \
          third_party/llvm-build/Release+Asserts/bin/clang
        ln -sfn clang third_party/llvm-build/Release+Asserts/bin/clang++
      fi
      mkdir -p third_party/node/linux/node-linux-x64/bin third_party/gperf/cipd/bin
      ln -sfn ${pkgs.nodejs}/bin/node third_party/node/linux/node-linux-x64/bin/node
      ln -sfn ${pkgs.gperf}/bin/gperf third_party/gperf/cipd/bin/gperf

      # M154 uses the native TypeScript compiler and declares its standard libs
      # as ninja inputs; the prepared tree did not contain this CIPD directory.
      mkdir -p third_party/typescript/linux-amd64/src
      ln -sfn ${pkgs.typescript}/lib/typescript third_party/typescript/linux-amd64/src/lib
      # Normalize old /usr paths as well as store paths left by prior attempts.
      export CHROMIX_ESBUILD=${esbuildChromix}/bin/esbuild
      export CHROMIX_TSC=${pkgs.typescript}/bin/tsc
      python3 - <<'PY_NORMALIZE_TOOLS'
      import os, pathlib, re
      root = pathlib.Path("third_party/devtools-frontend/src")
      for rel in ["scripts/build/typescript/typescript_vars.gni",
                  "third_party/typescript/typescript.py"]:
          p = root / rel
          if p.exists():
              s = p.read_text()
              s = re.sub(r'"/(?:usr/bin/tsc|nix/store/[^"\n]+/bin/tsc)"',
                         '"' + os.environ["CHROMIX_TSC"] + '"', s)
              p.write_text(s)
      for rel in ["scripts/build/ninja/bundle.gni", "scripts/build/typescript/typescript.gni"]:
          p = root / rel
          if p.exists():
              s = re.sub(r'"/(?:usr/bin/esbuild|nix/store/[^"\n]+/bin/esbuild)"',
                         '"' + os.environ["CHROMIX_ESBUILD"] + '"', p.read_text())
              p.write_text(s)
      p = root / "scripts/build/esbuild.js"
      s = re.sub(r'process.env.ESBUILD_BINARY_PATH = path.join\([\s\S]*?\);',
                 'process.env.ESBUILD_BINARY_PATH = ' + repr(os.environ["CHROMIX_ESBUILD"]) + ';',
                 p.read_text())
      p.write_text(s)
      PY_NORMALIZE_TOOLS

      # Protoc executes plugins directly, so Python's shebang must also work
      # without /usr/bin/env. Match nixpkgs' build-time shebang normalization.
      if [ -e native_client/SConstruct ]; then
        substituteInPlace native_client/SConstruct --replace-warn '#! -*- python -*-' ""
      fi
      if [ -e third_party/harfbuzz-ng/src/src/update-unicode-tables.make ]; then
        substituteInPlace third_party/harfbuzz-ng/src/src/update-unicode-tables.make \
          --replace-warn '/usr/bin/env -S make -f' '/usr/bin/make -f'
      fi
      for script in third_party/webgpu-cts/src/tools/run_deno \
        third_party/dawn/third_party/webgpu-cts/tools/run_deno; do
        if [ -e "$script" ]; then chmod -x "$script"; fi
      done
      patchShebangs --build .
    '';

    # gn from the source tree, since Chromium's gn must match the tree it
    # generates for. Bootstrapping this is only possible now that the toolchain
    # and libc are consistent — it is the step that used to fail on the old setup.
    preConfigure =
      lib.optionalString (buildCheckpoint != null) ''
        tar --zstd -xf ${builtins.storePath buildCheckpoint} --no-same-owner
        python3 - <<'PY_CHECKPOINT'
        import json
        from pathlib import Path
        manifest = json.loads(Path("checkpoint-manifest.json").read_text())
        expected = ${
          builtins.toJSON {
            schema = 1;
            source = toString finalAttrs.src;
            gn_flags_sha256 = builtins.hashString "sha256" gnFlags;
            stdenv = toString stdenv;
            targets = [
              "chrome"
              "chrome_crashpad_handler"
              "chrome_sandbox"
            ];
          }
        }
        actual = {key: manifest.get(key) for key in expected}
        if actual != expected:
            raise SystemExit("Checkpoint inputs differ: " + repr((actual, expected)))
        print("Reusing native Nix checkpoint from", manifest["origin_derivation"])
        PY_CHECKPOINT
      ''
      + lib.optionalString bootstrapGn ''
        mkdir -p out/gn-bootstrap
        python3 tools/gn/bootstrap/bootstrap.py --skip-generate-buildfiles \
          -j "$NIX_BUILD_CORES" -o "$PWD/out/gn-bootstrap/gn"
        export PATH="$PWD/out/gn-bootstrap:$PATH"
      '';

    configurePhase = ''
      set -o pipefail
      runHook preConfigure

      if [ -f build/linux/unbundle/replace_gn_files.py ]; then
        python3 build/linux/unbundle/replace_gn_files.py \
          --system-libraries ${lib.concatStringsSep " " gnSystemLibraries}
      fi

      gn gen --args=${lib.escapeShellArg gnFlags} ${buildPath} | tee gn-gen-outputs.txt

      runHook postConfigure
    '';

    # The knobs Chromium's own build needs under a foreign clang.
    env = {
      # Bootstrapping rustc needs nightly features; nixpkgs' rustc is stable.
      RUSTC_BOOTSTRAP = 1;
      ESBUILD_BINARY_PATH = "${esbuildChromix}/bin/esbuild";
      GOTOOLCHAIN = "local";
      GOPROXY = "off";
      BUILD_CC = "$CC_FOR_BUILD";
      BUILD_CXX = "$CXX_FOR_BUILD";
      BUILD_AR = "$AR_FOR_BUILD";
      BUILD_NM = "$NM_FOR_BUILD";
      BUILD_READELF = "$READELF_FOR_BUILD";
      # Chromium enables warnings our clang does not know; silencing these keeps
      # the log readable (it is ~25 MB otherwise).
      NIX_CFLAGS_COMPILE = "-Wno-unknown-warning-option -Wno-unused-command-line-argument -Wno-shadow -Wno-macro-redefined";
      # [56385/56385] LINK ./chrome
      # ld.lld: Argument list too long
      NIX_LD_USE_RESPONSE_FILE = 1;
    };

    # Nix intentionally gives builders an unwritable HOME. Dawn invokes Go via
    # subprocess, so caches must live in the writable per-build TMPDIR instead.
    preBuild = ''
      export GOCACHE="$TMPDIR/go-cache"
      export GOPATH="$TMPDIR/go"
      mkdir -p "$GOCACHE" "$GOPATH"
    '';

    buildPhase = lib.optionalString (!configureOnly) ''
      runHook preBuild
      TERM=dumb ninja -C ${buildPath} -j"''${NIX_BUILD_CORES:-$(nproc)}" \
        chrome chrome_crashpad_handler chrome_sandbox
      runHook postBuild
    '';

    installPhase =
      if configureOnly then
        ''
          mkdir -p "$out"
          cp gn-gen-outputs.txt "$out/"
          cp -r ${buildPath} "$out/generated"
        ''
      else
        ''
          runHook preInstall

          mkdir -p $out/libexec/chromix $out/bin

          install -Dm755 ${buildPath}/chrome $out/libexec/chromix/chrome
          install -Dm755 ${buildPath}/chrome_crashpad_handler \
            $out/libexec/chromix/chrome_crashpad_handler
          if [ -f ${buildPath}/chrome_sandbox ]; then
            install -Dm755 ${buildPath}/chrome_sandbox $out/libexec/chromix/chrome_sandbox
          fi

          # Resource bundles and the data files Chrome mmaps at startup.
          for d in locales resources icudtl.dat v8_context_snapshot.bin \
                   chrome_100_percent.pak chrome_200_percent.pak \
                   resources.pak snapshot_blob.bin; do
            if [ -e "${buildPath}/$d" ]; then
              cp -r "${buildPath}/$d" $out/libexec/chromix/
            fi
          done

          # Shared objects Chromium loads by name relative to the binary — ANGLE's
          # libEGL/libGLESv2 among them.
          find ${buildPath} -maxdepth 1 -name '*.so' -exec cp -a {} $out/libexec/chromix/ \;

          ln -s $out/libexec/chromix/chrome $out/bin/chromix

          runHook postInstall
        '';

    enableParallelBuilding = true;
    dontBuild = configureOnly;
    dontFixup = configureOnly;

    meta = {
      description = "Chromix — ungoogled Chromium with surface-consistency persona patches";
      longDescription = ''
        Chromix is a Chromium build carrying a large set of "surface consistency"
        persona patches (user agent, WebGL, canvas noise, fonts, codecs, WebRTC,
        SOCKS5, time zone). It builds against system libraries using Chromium's
        official unbundle toolchain, the way nixpkgs builds chromium.
      '';
      homepage = "https://github.com/xiaozhou26/Chromix";
      license = lib.licenses.bsd3;
      platforms = [ "x86_64-linux" ];
      mainProgram = "chromix";
    };
  });
in
if configureOnly then
  unwrapped
else
  pkgs.stdenvNoCC.mkDerivation {
    pname = "chromix";
    inherit version;
    dontUnpack = true;
    dontBuild = true;
    dontStrip = true;
    nativeBuildInputs = [
      pkgs.makeWrapper
      pkgs.patchelf
    ];

    # Like nixpkgs' outer chromium wrapper, runtime packaging must not force a
    # rebuild of the browser. unwrapped is intentionally byte-for-byte the same
    # derivation as the original source build.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a ${unwrapped}/. "$out/"
      chmod -R u+w "$out"

      # The system Vulkan loader is used by nixpkgs, not Chromium's bundled one.
      ln -s ${lib.getLib pkgs.vulkan-loader}/lib/libvulkan.so.1 \
        "$out/libexec/chromix/libvulkan.so.1"
      substitute ${chromixSrc + "/third_party/swiftshader/src/Vulkan/vk_swiftshader_icd.json.tmpl"} \
        "$out/libexec/chromix/vk_swiftshader_icd.json" \
        --replace-fail ${lib.escapeShellArg "\${ICD_LIBRARY_PATH}"} './libvk_swiftshader.so'

      cp -a ${chromixAssets + "/fonts"} "$out/libexec/chromix/fonts"
      mkdir -p "$out/etc/fonts" "$out/share/licenses/chromix"
      # Fontconfig expands the XDG cache directory at runtime. Nothing writes to
      # the immutable store, and no generated host-specific config is required.
      cat > "$out/etc/fonts/fonts.conf" <<EOF_FONTCONFIG
      <?xml version="1.0"?>
      <fontconfig>
        <dir>$out/libexec/chromix/fonts</dir>
        <cachedir prefix="xdg">chromix/fontconfig</cachedir>
      </fontconfig>
      EOF_FONTCONFIG
      cp ${chromixAssets + "/../LICENSE"} "$out/share/licenses/chromix/LICENSE.chromix"
      cp ${chromixSrc + "/LICENSE"} "$out/share/licenses/chromix/LICENSE.chromium"

      # Replace the unwrapped absolute symlink with a launcher for this output's
      # copy of the ELF; leaving it untouched would bypass these runtime fixes.
      unlink "$out/bin/chromix"
      makeWrapper "$out/libexec/chromix/chrome" "$out/bin/chromix" \
        --set FONTCONFIG_FILE "$out/etc/fonts/fonts.conf"
      runHook postInstall
    '';

    postFixup = ''
      for binary in "$out/libexec/chromix/chrome" "$out/libexec/chromix/libGLESv2.so"; do
        if [ -f "$binary" ]; then
          patchelf --set-rpath "$out/libexec/chromix:${
            lib.makeLibraryPath [
              pkgs.libGL
              pkgs.vulkan-loader
              pkgs.pciutils
            ]
          }:$(patchelf --print-rpath "$binary")" "$binary"
        fi
      done
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      set -o pipefail
      for binary in chrome chrome_crashpad_handler chrome_sandbox; do
        test -x "$out/libexec/chromix/$binary"
      done
      for data in icudtl.dat resources.pak vk_swiftshader_icd.json; do
        test -s "$out/libexec/chromix/$data"
      done
      test -s "$out/libexec/chromix/v8_context_snapshot.bin" \
        || test -s "$out/libexec/chromix/snapshot_blob.bin"
      test -n "$(find "$out/libexec/chromix/locales" -name '*.pak' -print -quit)"
      "$out/bin/chromix" --version | tee "$TMPDIR/chromix-version.txt"
      grep -F '${version}' "$TMPDIR/chromix-version.txt"
    '';

    passthru = { inherit unwrapped; };
    meta = unwrapped.meta;
  }
