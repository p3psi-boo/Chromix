"""Check a completed native Nix Chromix package and exercise its renderer."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import tempfile


class VerificationError(ValueError):
    pass


def run_browser(launcher: Path, arguments: list[str], timeout: int) -> dict:
    process = subprocess.Popen(
        [str(launcher), *arguments], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        start_new_session=True,
    )
    try:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise VerificationError(f"browser exceeded {timeout}s") from error
        if process.returncode:
            raise VerificationError(
                f"browser exited {process.returncode}: {stderr[-4000:]}"
            )
        return {"stdout": stdout, "stderr": stderr}
    finally:
        # Chromium may leave child processes after the launcher has exited.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired as error:
            raise VerificationError("browser process group did not terminate") from error


def verify(package: Path, version: str) -> dict:
    if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", version):
        raise VerificationError("expected version must contain four numeric components")
    package = package.resolve(strict=True)
    if package.parent != Path("/nix/store"):
        raise VerificationError(f"expected a Nix store output, got {package}")
    subprocess.run(["nix-store", "--check-validity", str(package)], check=True)
    launcher = package / "bin/chromix"
    if not launcher.is_file() or not os.access(launcher, os.X_OK):
        raise VerificationError("missing executable bin/chromix launcher")
    root = package / "libexec/chromix"
    binaries = {}
    for name in ("chrome", "chrome_crashpad_handler", "chrome_sandbox"):
        binary = root / name
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise VerificationError(f"missing executable {name}")
        with binary.open("rb") as stream:
            header = stream.read(64)
            if (len(header) != 64 or header[:6] != b"\x7fELF\x02\x01"
                    or struct.unpack_from("<H", header, 18)[0] != 62):
                raise VerificationError(f"{name} is not an x86_64 ELF64 executable")
            stream.seek(0)
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        binaries[name] = {"bytes": binary.stat().st_size, "sha256": digest}
    for name in ("icudtl.dat", "resources.pak", "chrome_100_percent.pak",
                 "chrome_200_percent.pak", "vk_swiftshader_icd.json"):
        if not (root / name).is_file() or (root / name).stat().st_size == 0:
            raise VerificationError(f"missing or empty runtime file {name}")
    if not any((root / name).is_file() for name in (
            "v8_context_snapshot.bin", "snapshot_blob.bin")):
        raise VerificationError("missing V8 snapshot")
    if not any((root / "locales").glob("*.pak")):
        raise VerificationError("missing locale resource packs")
    for name in ("libEGL.so", "libGLESv2.so", "libvulkan.so.1"):
        if not (root / name).is_file():
            raise VerificationError(f"missing runtime library {name}")
    icd = json.loads((root / "vk_swiftshader_icd.json").read_text())
    icd_library = (root / icd["ICD"]["library_path"]).resolve(strict=True)
    if not icd_library.is_relative_to(root) or not icd_library.is_file():
        raise VerificationError("SwiftShader ICD does not resolve inside this package")
    for name in ("NOTICE", "SOURCE.md", "fonts.conf.template"):
        if not (root / "fonts" / name).is_file():
            raise VerificationError(f"missing font bundle metadata {name}")
    if not any(p.suffix.lower() in (".ttf", ".ttc") for p in (root / "fonts").iterdir()):
        raise VerificationError("font bundle contains no fonts")
    for name in ("LICENSE.chromix", "LICENSE.chromium"):
        if not (package / "share/licenses/chromix" / name).is_file():
            raise VerificationError(f"missing {name}")
    result = run_browser(launcher, ["--version"], 30)
    if not re.search(rf"(?<![\d.]){re.escape(version)}(?![\d.])", result["stdout"]):
        raise VerificationError(f"unexpected version output: {result['stdout'][:2000]}")
    version_output = result["stdout"].strip()
    page = ('<html><body><p id="smoke">chromix-smoke-ok</p><script>'
            'document.getElementById("smoke").dataset.nix="passed";'
            'document.title="Chromix Nix smoke";</script></body></html>')
    with tempfile.TemporaryDirectory(prefix="chromix-nix-smoke-") as profile:
        result = run_browser(launcher, [
            "--headless", "--disable-gpu", "--disable-background-networking",
            "--no-first-run", "--no-default-browser-check",
            f"--user-data-dir={profile}", "--dump-dom", "data:text/html," + page,
        ], 90)
    if "GLib-GIO-CRITICAL" in result["stderr"]:
        raise VerificationError("GSettings runtime initialization failed: " + result["stderr"][-4000:])
    for marker in ("chromix-smoke-ok", 'data-nix="passed"',
                   "<title>Chromix Nix smoke</title>"):
        if marker not in result["stdout"]:
            raise VerificationError(f"headless JS/DOM marker missing: {marker}")
    return {"status": "passed", "package": str(package), "arch": "x86_64-linux",
            "version": version_output, "binaries": binaries, "runtime": {
                "headless_dom": "passed", "javascript": "passed",
                "no_sandbox_flag_passed": False, "stderr": result["stderr"][-4000:]}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--expected-version", required=True)
    args = parser.parse_args()
    try:
        report = verify(args.package, args.expected_version)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
