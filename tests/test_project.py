#!/usr/bin/env python3
"""Behavior and packaging tests for the public release."""
import os
from pathlib import Path
import hashlib
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def run(*args, env=None, check=False):
    """Run a repository command and capture text output."""
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(
        [str(arg) for arg in args],
        cwd=ROOT,
        env=merged,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


class WaitHelperTests(unittest.TestCase):
    """Exercise renderer detection without real DRM hardware."""

    def setUp(self):
        """Create an isolated fake /dev, /sys, and /run tree."""
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.dev = self.base / "dev"
        self.sys = self.base / "sys"
        self.run_root = self.base / "run"
        self.drivers = self.base / "drivers"
        (self.dev / "dri").mkdir(parents=True)
        (self.sys / "class/drm").mkdir(parents=True)
        self.run_root.mkdir()
        self.drivers.mkdir()
        self.uptime = self.base / "uptime"
        self.uptime.write_text("12.34 99.00\n", encoding="ascii")
        self.fake_bin = self.base / "bin"
        self.fake_bin.mkdir()
        udevadm = self.fake_bin / "udevadm"
        udevadm.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        udevadm.chmod(0o755)

    def tearDown(self):
        """Remove the isolated test tree."""
        self.temp.cleanup()

    def helper_env(self):
        """Return environment overrides for the fake hardware tree."""
        return {
            "NPRF_DEV_ROOT": str(self.dev),
            "NPRF_SYS_ROOT": str(self.sys),
            "NPRF_RUN_ROOT": str(self.run_root),
            "NPRF_UPTIME_FILE": str(self.uptime),
            "NPRF_UDEVADM": str(self.fake_bin / "udevadm"),
            "NPRF_SLEEP": "/bin/true",
            "NPRF_TEST_ALLOW_REGULAR": "1",
            "NPRF_TIMEOUT": "1",
        }

    def add_card(self, name, driver):
        """Add one fake DRM card linked to a named kernel driver."""
        node = self.dev / "dri" / name
        node.touch()
        device = self.sys / "class/drm" / name / "device"
        device.mkdir(parents=True)
        driver_target = self.drivers / driver
        driver_target.mkdir(exist_ok=True)
        (device / "driver").symlink_to(driver_target)

    def test_wait_helper_selects_nvidia_without_hardcoded_card_number(self):
        """Accept any card number when its driver resolves to NVIDIA."""
        self.add_card("card7", "nvidia")
        result = run(ROOT / "src/plymouth-wait-for-nvidia-drm", env=self.helper_env())
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = self.run_root / "nvidia-plymouth-race-fix/graphics-ready"
        self.assertEqual(marker.read_text(encoding="ascii").strip(), "12.34")

    def test_wait_helper_ignores_non_nvidia_cards(self):
        """Ignore cards owned by another DRM driver and time out safely."""
        self.add_card("card0", "amdgpu")
        env = self.helper_env()
        env["NPRF_TIMEOUT"] = "0"
        result = run(ROOT / "src/plymouth-wait-for-nvidia-drm", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        status = self.run_root / "nvidia-plymouth-race-fix/nvidia-drm-wait-status"
        self.assertEqual(status.read_text(encoding="ascii").strip(), "timeout")
        self.assertFalse((self.run_root / "nvidia-plymouth-race-fix/graphics-ready").exists())


class MinimumDurationTests(unittest.TestCase):
    """Verify that the optional delay runs only after real graphics readiness."""

    def setUp(self):
        """Create fake runtime files and command probes."""
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.run_root = self.base / "run"
        self.marker_dir = self.run_root / "nvidia-plymouth-race-fix"
        self.marker_dir.mkdir(parents=True)
        self.uptime = self.base / "uptime"
        self.uptime.write_text("12.00 99.00\n", encoding="ascii")
        self.calls = self.base / "calls"
        self.plymouth = self.base / "plymouth"
        self.plymouth.write_text(
            f"#!/bin/sh\nprintf 'plymouth:%s\\n' \"$*\" >> {self.calls}\nexit 0\n",
            encoding="utf-8",
        )
        self.plymouth.chmod(0o755)
        self.sleep = self.base / "sleep"
        self.sleep.write_text(
            f"#!/bin/sh\nprintf 'sleep:%s\\n' \"$*\" >> {self.calls}\nexit 0\n",
            encoding="utf-8",
        )
        self.sleep.chmod(0o755)

    def tearDown(self):
        """Remove temporary runtime files."""
        self.temp.cleanup()

    def helper_env(self):
        """Return environment overrides for the duration helper."""
        return {
            "NPRF_RUN_ROOT": str(self.run_root),
            "NPRF_UPTIME_FILE": str(self.uptime),
            "NPRF_PLYMOUTH": str(self.plymouth),
            "NPRF_SLEEP": str(self.sleep),
            "NPRF_MIN_DURATION": "5",
        }

    def test_timeout_status_does_not_add_minimum_duration(self):
        """A failed DRM wait must not create an additional boot delay."""
        (self.marker_dir / "nvidia-drm-wait-status").write_text("timeout\n", encoding="ascii")
        result = run(ROOT / "src/plymouth-minimum-duration", env=self.helper_env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls.exists())

    def test_ready_status_sleeps_only_for_remaining_time(self):
        """Measure the minimum duration from the graphics-ready timestamp."""
        (self.marker_dir / "nvidia-drm-wait-status").write_text("ready:card7\n", encoding="ascii")
        (self.marker_dir / "graphics-ready").write_text("1" + "0.00\n", encoding="ascii")
        result = run(ROOT / "src/plymouth-minimum-duration", env=self.helper_env())
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text(encoding="utf-8")
        self.assertIn("plymouth:--ping", calls)
        self.assertIn("sleep:3.000", calls)


class InstallerTests(unittest.TestCase):
    """Verify planning, validation, installation, and rollback."""

    def test_dry_run_is_non_privileged_and_theme_agnostic(self):
        """Dry-run planning must not depend on a specific theme."""
        result = run(ROOT / "install.sh", "--dry-run", "--generator", "dracut", "--timeout", "9", "--min-duration", "4")
        self.assertEqual(result.returncode, 0, result.stderr)
        combined = result.stdout + result.stderr
        self.assertIn("generator: dracut", combined)
        self.assertIn("timeout: 9", combined)
        self.assertIn("minimum splash duration: 4", combined)
        self.assertNotIn("Theme=", combined)
        self.assertNotIn("plymouth-xp", combined.lower())

    def test_invalid_timeout_is_rejected(self):
        """Reject malformed timeout values before any write."""
        result = run(ROOT / "install.sh", "--dry-run", "--timeout", "not-a-number")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timeout", (result.stdout + result.stderr).lower())

    def test_fixture_install_and_uninstall_are_reversible(self):
        """Install and remove all managed files inside a temporary root."""
        with tempfile.TemporaryDirectory() as temp:
            fake_root = Path(temp) / "root"
            fake_root.mkdir()
            original_config = fake_root / "etc/default/nvidia-plymouth-race-fix"
            original_config.parent.mkdir(parents=True)
            original_config.write_text("ORIGINAL=1\n", encoding="utf-8")
            env = {
                "NPRF_ROOT": str(fake_root),
                "NPRF_ALLOW_NON_ROOT": "1",
                "NPRF_SKIP_REBUILD": "1",
            }
            install = run(ROOT / "install.sh", "--generator", "dracut", "--timeout", "8", "--min-duration", "5", env=env)
            self.assertEqual(install.returncode, 0, install.stderr)
            wait_helper = fake_root / "usr/local/libexec/plymouth-wait-for-nvidia-drm"
            dropin = fake_root / "etc/systemd/system/plymouth-start.service.d/10-wait-for-nvidia-drm.conf"
            config = fake_root / "etc/default/nvidia-plymouth-race-fix"
            dracut = fake_root / "etc/dracut.conf.d/90-nvidia-plymouth-race-fix.conf"
            minimum_unit = fake_root / "etc/systemd/system/plymouth-minimum-duration.service"
            for path in (wait_helper, dropin, config, dracut, minimum_unit):
                self.assertTrue(path.exists(), path)
            self.assertTrue(wait_helper.stat().st_mode & stat.S_IXUSR)
            config_text = config.read_text(encoding="utf-8")
            self.assertIn("TIMEOUT=8", config_text)
            self.assertIn("MIN_DURATION=5", config_text)
            self.assertNotIn("Theme=", config_text)

            uninstall = run(ROOT / "uninstall.sh", "--generator", "dracut", env=env)
            self.assertEqual(uninstall.returncode, 0, uninstall.stderr)
            for path in (wait_helper, dropin, dracut, minimum_unit):
                self.assertFalse(path.exists(), path)
            self.assertEqual(config.read_text(encoding="utf-8"), "ORIGINAL=1\n")

    def test_initramfs_tools_fixture_installs_matching_backend(self):
        """Install and remove the initramfs-tools hook set in isolation."""
        with tempfile.TemporaryDirectory() as temp:
            fake_root = Path(temp) / "root"
            fake_root.mkdir()
            env = {
                "NPRF_ROOT": str(fake_root),
                "NPRF_ALLOW_NON_ROOT": "1",
                "NPRF_SKIP_REBUILD": "1",
            }
            install = run(ROOT / "install.sh", "--generator", "initramfs-tools", env=env)
            self.assertEqual(install.returncode, 0, install.stderr)
            hook = fake_root / "etc/initramfs-tools/hooks/nvidia-plymouth-race-fix"
            init_top = fake_root / "etc/initramfs-tools/scripts/init-top/00-nvidia-plymouth-wait"
            self.assertTrue(hook.exists())
            self.assertTrue(init_top.exists())
            self.assertNotIn("/run/plymouth", (ROOT / "src/plymouth-wait-for-nvidia-drm").read_text(encoding="utf-8"))
            uninstall = run(ROOT / "uninstall.sh", env=env)
            self.assertEqual(uninstall.returncode, 0, uninstall.stderr)
            self.assertFalse(hook.exists())
            self.assertFalse(init_top.exists())

    def test_uninstall_refuses_to_discard_local_modifications(self):
        """Require --force before removing an administrator-modified target."""
        with tempfile.TemporaryDirectory() as temp:
            fake_root = Path(temp) / "root"
            fake_root.mkdir()
            env = {
                "NPRF_ROOT": str(fake_root),
                "NPRF_ALLOW_NON_ROOT": "1",
                "NPRF_SKIP_REBUILD": "1",
            }
            install = run(ROOT / "install.sh", "--generator", "dracut", env=env)
            self.assertEqual(install.returncode, 0, install.stderr)
            helper = fake_root / "usr/local/libexec/plymouth-wait-for-nvidia-drm"
            helper.write_text("locally modified\n", encoding="utf-8")
            refused = run(ROOT / "uninstall.sh", env=env)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("modified", (refused.stdout + refused.stderr).lower())
            forced = run(ROOT / "uninstall.sh", "--force", env=env)
            self.assertEqual(forced.returncode, 0, forced.stderr)


class RepositoryTests(unittest.TestCase):
    """Check syntax, documentation coverage, and public sanitization."""

    def test_shell_scripts_parse(self):
        """All distributed shell scripts must pass POSIX shell parsing."""
        scripts = [
            ROOT / "install.sh",
            ROOT / "uninstall.sh",
            ROOT / "diagnose.sh",
            ROOT / "src/plymouth-wait-for-nvidia-drm",
            ROOT / "src/plymouth-minimum-duration",
            ROOT / "src/initramfs-tools-hook",
            ROOT / "src/initramfs-tools-init-top",
        ]
        for script in scripts:
            result = run("/bin/sh", "-n", script)
            self.assertEqual(result.returncode, 0, f"{script}: {result.stderr}")

    def test_readme_documents_scope_safety_and_rollback(self):
        """README must describe scope, safety boundaries, and rollback."""
        text = (ROOT / "README.md").read_text(encoding="utf-8")
        for phrase in (
            "Theme-agnostic",
            "Supported initramfs generators",
            "Dry run",
            "Uninstall",
            "EFI stub messages",
            "Limitations",
        ):
            self.assertIn(phrase, text)

    def test_no_private_machine_details_are_packaged(self):
        """Reject host-specific paths, addresses, names, and theme IDs."""
        forbidden = (
            "/home/" + "oxa",
            "/home/" + "dietpi",
            "192." + "168." + "1" + "0.",
            "ji" + "lua",
            "plymouth-" + "xp-theme",
        )
        for path in ROOT.rglob("*"):
            if not path.is_file() or ".git" in path.parts or "__pycache__" in path.parts:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            for token in forbidden:
                self.assertNotIn(token, text, f"{token!r} found in {path}")

    def test_manifest_matches_release_files(self):
        """Verify every checksum recorded in the release manifest."""
        manifest = ROOT / "MANIFEST.sha256"
        self.assertTrue(manifest.exists())
        for line in manifest.read_text(encoding="utf-8").splitlines():
            expected, relative = line.split("  ", 1)
            actual = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
            self.assertEqual(actual, expected, relative)


if __name__ == "__main__":
    unittest.main(verbosity=2)
