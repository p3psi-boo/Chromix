"""Apply both complete Nix patch stacks to sparse copies, never the real tree."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


NIX = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("CHROMIX_TEST_SOURCE", "/home/bubu/.chromix-build/src"))
SNAPSHOT = os.environ.get(
    "CHROMIX_SOURCE_SNAPSHOT", "/nix/store/gbhrb9map7afqhgj1gqgcs7bczx6hcy5-chromix-source"
)


def evaluate(attribute, performance):
    expression = (f'let p = import {NIX / "chromix.nix"} '
                  f'{{ sourceSnapshot = {json.dumps(SNAPSHOT)}; '
                  f'performanceBuild = {str(performance).lower()}; }}; in ')
    expression += ("map builtins.toString p.unwrapped.patches"
                   if attribute == "unwrapped.patches" else f"p.{attribute}")
    return json.loads(subprocess.check_output([
        "nix-instantiate", "--eval", "--strict", "--json", "--expr", expression,
    ], text=True))


class LocalPatches(unittest.TestCase):
    def test_both_complete_patch_stacks(self):
        hashes = []
        for performance in (False, True):
            with self.subTest(performance=performance), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                patches = [Path(p) for p in evaluate("unwrapped.patches", performance)]
                # Copy only existing patch inputs; new files are created by patch.
                for patch in patches:
                    for rel in re.findall(r"^--- a/(.+)$", patch.read_text(), re.M):
                        target = root / rel
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(SOURCE / rel, target)
                for patch in patches:
                    result = subprocess.run([
                        "patch", "--batch", "--forward", "--fuzz=0", "--reject-file=-",
                        "-p1", "-d", str(root), "-i", str(patch),
                    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    self.assertEqual(result.returncode, 0, f"{patch}: {result.stdout}")
                paths = (root / "chrome/common/chrome_paths_linux.cc").read_text()
                self.assertIn('data_dir_basename = "chromix"', paths)
                ffmpeg = root / "third_party/ffmpeg"
                config = ffmpeg / "chromium/config/Chrome/linux/x64"
                for filename, prefix, flags in [
                    ("config_components.h", "#", ("HEVC_DECODER", "HEVC_PARSER")),
                    ("config_components.asm", "%", ("HEVC_DECODER", "HEVC_PARSER")),
                    ("config.h", "#", ("HEVCPARSE", "HEVC_SEI", "BSWAPDSP")),
                    ("config.asm", "%", ("HEVCPARSE", "HEVC_SEI", "BSWAPDSP")),
                ]:
                    for flag in flags:
                        self.assertIn(f"{prefix}define CONFIG_{flag} 1", (config / filename).read_text())
                self.assertIn("&ff_hevc_decoder", (config / "libavcodec/codec_list.c").read_text())
                self.assertIn("&ff_hevc_parser", (config / "libavcodec/parser_list.c").read_text())
                generated = (ffmpeg / "ffmpeg_generated.gni").read_text().split("# Chromix:", 1)[1]
                for rel in re.findall(r'"(libavcodec/[^\"]+)"', generated):
                    self.assertTrue((ffmpeg / rel).is_file() or (SOURCE / "third_party/ffmpeg" / rel).is_file(), rel)
                types = (root / "media/base/supported_types.cc").read_text()
                self.assertIn("bool IsUxrVideoCodecAllowed", types)
                self.assertIn("if (!IsUxrVideoCodecAllowed(type.codec))", types)
                self.assertIn("if (!IsColorSpaceSupported(type.color_space))", types)
                self.assertIn("type.profile == HEVCPROFILE_MAIN10", types)
                compiler = (root / "build/config/compiler/BUILD.gn").read_text()
                abi = (root / "build/config/compiler_cpu_abi.gn").read_text() if performance else ""
                self.assertEqual("-Ctarget-cpu=x86-64-v3" in compiler, performance)
                self.assertEqual("-march=x86-64-v3" in abi, performance)
                self.assertEqual("--lto-CGO3" in compiler, performance)
                self.assertIn('"-ffp-contract=off"', compiler)
                self.assertIn("_LIBCPP_HARDENING_MODE_EXTENSIVE", compiler)
                self.assertNotIn('"-ffast-math"', compiler)
                info = evaluate("buildInfo", performance)
                self.assertEqual(info["profile"], "avx2" if performance else "portable")
                self.assertTrue(info["features"]["hevcSoftwareDecoder"])
                hashes.append(info["patches_sha256"])
        self.assertEqual(len(hashes), 2)
        self.assertNotEqual(hashes[0], hashes[1])

    def test_fixture_hashes(self):
        import hashlib
        for path in (NIX / "tests/data").glob("hevc-*.json"):
            fixture = json.loads(path.read_text())
            data = (path.parent / fixture["mp4"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), fixture["sha256"])


if __name__ == "__main__":
    unittest.main()
