#!/usr/bin/env python3
import hashlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from update import Updater, UpdateError, PRODUCT, update_lock


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.bundle = self.root / "stillepost/app/0.9.47"
        (self.bundle / "bin").mkdir(parents=True)
        (self.bundle / "bin/openssl").symlink_to(shutil.which("openssl"))
        self.private = self.root / "private.pem"
        self.public = self.bundle / "update-public.pem"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(self.private)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "openssl",
                "pkey",
                "-in",
                str(self.private),
                "-pubout",
                "-out",
                str(self.public),
            ],
            check=True,
            capture_output=True,
        )
        (self.bundle / "linux-build.json").write_text('{"build":9047}')
        (self.bundle.parent / "current").symlink_to(self.bundle.name)
        self.manifest = self.root / "manifest"
        self.signature = self.root / "signature"
        self.data = {
            "product": PRODUCT,
            "channel": "stable",
            "arch": "x86_64",
            "build": 9048,
            "version": "0.9.48",
            "min_glibc": "2.39",
            "size": 10,
            "sha256": "0" * 64,
            "url": "https://github.com/DanielMuellerIR/stille_post/releases/download/v0.9.48/StillePost-linux.tar.gz",
        }
        self.updater = Updater(self.bundle)

    def sign(self):
        self.manifest.write_text(json.dumps(self.data))
        subprocess.run(
            [
                "openssl",
                "pkeyutl",
                "-sign",
                "-inkey",
                str(self.private),
                "-rawin",
                "-in",
                str(self.manifest),
                "-out",
                str(self.signature),
            ],
            check=True,
            capture_output=True,
        )

    def test_valid_signed_manifest(self):
        self.sign()
        self.assertEqual(
            self.updater.verify(self.manifest, self.signature)["build"], 9048
        )

    def test_tampered_manifest_is_rejected(self):
        self.sign()
        self.manifest.write_bytes(self.manifest.read_bytes() + b" ")
        with self.assertRaises(UpdateError):
            self.updater.verify(self.manifest, self.signature)

    def test_other_product_and_download_source_rejected_even_when_signed(self):
        for key, value in [
            ("product", "other"),
            ("url", "https://example.org/payload"),
            ("arch", "aarch64"),
            ("size", 2**40),
            ("build", True),
        ]:
            original = self.data[key]
            self.data[key] = value
            self.sign()
            with self.assertRaises(UpdateError):
                self.updater.verify(self.manifest, self.signature)
            self.data[key] = original

    def archive(self, name, kind=tarfile.REGTYPE):
        path = self.root / "bad.tar.gz"
        with tarfile.open(path, "w:gz") as tar:
            info = tarfile.TarInfo(name)
            info.type = kind
            if kind == tarfile.REGTYPE:
                info.size = 1
                tar.addfile(info, io.BytesIO(b"x"))
            else:
                info.linkname = "/tmp/escape"
                tar.addfile(info)
        return path

    def test_traversal_and_links_rejected(self):
        for name, kind in [
            ("StillePost.AppDir/../escape", tarfile.REGTYPE),
            ("/absolute", tarfile.REGTYPE),
            ("StillePost.AppDir/link", tarfile.SYMTYPE),
            ("StillePost.AppDir/fifo", tarfile.FIFOTYPE),
        ]:
            dest = self.root / "dest"
            dest.mkdir(exist_ok=True)
            with self.assertRaises(UpdateError):
                Updater.extract(self.archive(name, kind), dest)

    def test_normal_archive_and_atomic_rollback(self):
        dest = self.root / "dest"
        dest.mkdir()
        Updater.extract(self.archive("StillePost.AppDir/bin/test"), dest)
        self.assertEqual((dest / "bin/test").read_bytes(), b"x")
        source = self.install_source("0.9.48", "exit 0\n")
        (self.bundle / "AppRun").touch()
        current = self.bundle.parent / "current"
        newer = self.bundle.parent / "0.9.48"
        with patch.dict(os.environ, {"XDG_DATA_HOME": str(self.root)}):
            Updater(source).install_local()
            self.assertEqual(current.resolve(), newer)
            self.assertTrue(Updater(newer).rollback()["rolledBack"])
            self.assertEqual(current.resolve(), self.bundle)

    def test_failed_download_does_not_switch_version(self):
        with patch.dict(os.environ, {"XDG_DATA_HOME": str(self.root)}):

            def fail(*args):
                raise OSError("fixture")

            self.updater.download = fail
            with self.assertRaises(OSError):
                self.updater.install()
            self.assertEqual((self.bundle.parent / "current").resolve(), self.bundle)
            self.assertTrue((self.bundle.parent / ".update-lock").is_file())
            with self.assertRaises(OSError):
                self.updater.install()  # Sperre ist nach dem Fehler wieder frei.

    def test_signed_install_activates_the_smoke_tested_version(self):
        version = self.data["version"]
        source = self.install_source(version, 'test "$1" = "--smoke-test"\n')
        (source / "linux-build.json").write_text(
            json.dumps({"build": self.data["build"]})
        )
        shutil.copy2(self.public, source / "update-public.pem")
        archive = self.root / "update.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(source, arcname="StillePost.AppDir")
        self.data.update(
            size=archive.stat().st_size,
            sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
        )
        self.sign()
        downloads = {
            self.updater.feed: self.manifest,
            self.updater.feed + ".sig": self.signature,
            self.data["url"]: archive,
        }

        def copy_download(url, target, limit):
            shutil.copyfile(downloads[url], target)
            self.assertLessEqual(target.stat().st_size, limit)
            return target.stat().st_size

        with patch.dict(os.environ, {"XDG_DATA_HOME": str(self.root)}):
            with patch.object(self.updater, "download", side_effect=copy_download):
                self.assertTrue(self.updater.check()["available"])
                self.assertEqual(
                    self.updater.install(), {"installed": True, "version": version}
                )
            self.assertEqual((self.bundle.parent / "current").resolve().name, version)
            with self.assertRaisesRegex(UpdateError, "aktive App"):
                self.updater.install()
            with self.assertRaisesRegex(UpdateError, "aktive App"):
                self.updater.rollback()

    def install_source(self, version, app_run):
        source = self.root / f"source-{version}"
        (source / "bin").mkdir(parents=True)
        for name in ("install.sh", "launcher.py", "update.py", "stillepost.desktop"):
            shutil.copy2(pathlib.Path(__file__).parent / name, source)
        (source / "VERSION").write_text(version + "\n")
        (source / "AppRun").write_text("#!/bin/sh\n" + app_run)
        (source / "bin/stillepost-linux").write_text("#!/bin/sh\nexit 0\n")
        for name in ("AppRun", "bin/stillepost-linux"):
            (source / name).chmod(0o755)
        return source

    def install_environment(self):
        home = self.root / "home"
        home.mkdir()
        return dict(
            os.environ,
            HOME=str(home),
            XDG_DATA_HOME=str(self.root),
            STILLEPOST_SKIP_MODEL_SETUP="1",
        )

    def test_late_launcher_failure_preserves_concurrent_local_install(self):
        env = self.install_environment()
        (self.bundle.parent / "current").unlink()
        newer = self.install_source("0.9.49", 'touch "$STILLEPOST_STARTUP_ACK"\n')
        starting = self.install_source(
            "0.9.48", '"$STILLEPOST_TEST_INSTALLER"\nexit 1\n'
        )
        env["STILLEPOST_TEST_INSTALLER"] = str(newer / "install.sh")
        subprocess.run(
            [starting / "install.sh"], env=env, check=True, capture_output=True
        )

        result = subprocess.run(
            [self.root / "home/.local/bin/stillepost"],
            env=env,
            capture_output=True,
            timeout=15,
        )

        current = self.bundle.parent / "current"
        self.assertEqual(current.resolve().name, "0.9.49")
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_launcher_rolls_back_when_the_failing_version_is_still_active(self):
        env = self.install_environment()
        previous = self.install_source("0.9.48", 'touch "$STILLEPOST_STARTUP_ACK"\n')
        newer = self.install_source("0.9.49", "exit 1\n")
        for source in (previous, newer):
            subprocess.run(
                [source / "install.sh"], env=env, check=True, capture_output=True
            )

        result = subprocess.run(
            [self.root / "home/.local/bin/stillepost"],
            env=env,
            capture_output=True,
            timeout=15,
        )

        self.assertEqual((self.bundle.parent / "current").resolve().name, "0.9.48")
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_rollback_checks_the_activation_even_after_switching_back(self):
        source = self.install_source("0.9.48", "exit 0\n")
        (self.bundle / "AppRun").touch()
        current = self.bundle.parent / "current"
        with patch.dict(os.environ, {"XDG_DATA_HOME": str(self.root)}):
            starting_activation = self.updater.activation()
            Updater(source).install_local()
            Updater(current).rollback()
            self.assertEqual(current.resolve(), self.bundle)
            with self.assertRaisesRegex(UpdateError, "inzwischen gewechselt"):
                self.updater.rollback(starting_activation)
            self.assertEqual(current.resolve(), self.bundle)
            self.assertEqual(Updater(current).rollback()["version"], "0.9.48")

    def test_rollback_and_local_installer_share_the_update_lock(self):
        source = self.install_source("0.9.48", "exit 0\n")
        root = self.bundle.parent
        with patch.dict(os.environ, {"XDG_DATA_HOME": str(self.root)}), update_lock(
            root
        ):
            for action in (
                self.updater.install,
                Updater(source).install_local,
                self.updater.rollback,
            ):
                with self.assertRaisesRegex(UpdateError, "andere Aktualisierung"):
                    action()
        self.assertEqual((root / "current").resolve(), self.bundle)
        self.assertFalse((root / "0.9.48").exists())

    def test_failed_activation_preserves_the_existing_rollback(self):
        source = self.install_source("0.9.48", "exit 0\n")
        root = self.bundle.parent
        previous = root / "0.9.46"
        previous.mkdir()
        (previous / "AppRun").touch()
        (root / "previous-version").write_text(previous.name + "\n")
        current = root / "current"
        replace = os.replace

        def fail_current_replacement(source_path, target_path):
            if target_path == current:
                raise OSError("fixture")
            replace(source_path, target_path)

        with patch.dict(os.environ, {"XDG_DATA_HOME": str(self.root)}):
            with patch("update.os.replace", side_effect=fail_current_replacement):
                with self.assertRaisesRegex(OSError, "fixture"):
                    Updater(source).install_local()
            self.assertEqual(current.resolve(), self.bundle)
            self.assertFalse((root / "0.9.48").exists())
            self.updater.rollback()
            self.assertEqual(current.resolve(), previous)

    def test_unusable_content_length_still_checks_downloaded_bytes(self):
        response = MagicMock()
        response.headers = {"Content-Length": "unknown"}
        response.__enter__.return_value = response
        response.read.side_effect = [b"local", b""]
        with patch.object(self.updater.opener, "open", return_value=response):
            self.assertEqual(
                self.updater.download(self.data["url"], self.root / "download", 5), 5
            )
            response.read.side_effect = [b"larger"]
            with self.assertRaisesRegex(UpdateError, "Download zu groß"):
                self.updater.download(self.data["url"], self.root / "oversized", 5)
            response.read.reset_mock()
            response.headers["Content-Length"] = "6"
            with self.assertRaisesRegex(UpdateError, "Download zu groß"):
                self.updater.download(
                    self.data["url"], self.root / "declared-oversized", 5
                )
            response.read.assert_not_called()

    def tearDown(self):
        self.tmp.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
