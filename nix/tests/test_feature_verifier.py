"""Negative integration tests: an old binary must not pass the new verifier."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


NIX = Path(__file__).resolve().parents[1]


class FeatureVerifier(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        package = os.environ.get("CHROMIX_BASELINE_PACKAGE")
        if not package:
            raise unittest.SkipTest("set CHROMIX_BASELINE_PACKAGE to the pre-feature Nix output")
        cls.launcher = Path(package).resolve(strict=True) / "bin/chromix"
        if not cls.launcher.is_file():
            raise unittest.SkipTest("baseline launcher missing")

    def reject_baseline(self, force_directory, marker):
        with tempfile.TemporaryDirectory(prefix="chromix-negative-harness-") as temporary:
            root = Path(temporary)
            (root / "bin").mkdir()
            (root / "share/chromix").mkdir(parents=True)
            # Deliberately declared metadata is not runtime evidence. The old
            # browser must still be rejected after reading these claimed flags.
            metadata = {"profile": "negative-fixture", "features": {
                "defaultProfileDirectory": "chromix", "hevcSoftwareDecoder": True,
            }}
            (root / "share/chromix/build-info.json").write_text(json.dumps(metadata))
            profile = ' "--user-data-dir=$XDG_CONFIG_HOME/chromix"' if force_directory else ""
            launcher = root / "bin/chromix"
            launcher.write_text("#!/run/current-system/sw/bin/bash\n"
                                "# Negative verifier fixture, not a browser package.\n"
                                f'exec {shlex.quote(str(self.launcher))}{profile} "$@"\n')
            launcher.chmod(0o755)
            result = subprocess.run([
                "node", str(NIX / "verify-features.mjs"), str(root),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 1, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["status"], "failed")
            self.assertIn(marker, report["error"])

    def test_old_default_directory_rejected(self):
        self.reject_baseline(False, "browser still uses the chromium default directory")

    def test_old_hevc_backend_rejected(self):
        # Force the test directory only to get past the first independent gate;
        # no decode capability is supplied by this wrapper.
        self.reject_baseline(True, "HEVC capability missing: main")


if __name__ == "__main__":
    unittest.main()
