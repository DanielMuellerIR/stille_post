#!/usr/bin/env python3
"""Prüft die Übergabe zwischen Modell-Setup und Installationen der App."""
import fcntl
import hashlib
import pathlib
import select
import subprocess
import sys
import tempfile
import unittest


class ModelSetupTests(unittest.TestCase):
    def test_setup_checks_the_file_after_the_shared_lock_is_released(self):
        script = pathlib.Path(__file__).with_name("setup-models.py")
        with tempfile.TemporaryDirectory() as directory:
            models = pathlib.Path(directory)
            target = models / "ggml-large-v3-turbo.bin"
            model = b"synthetic existing model"
            driver = """
import fcntl, pathlib, runpy, sys
setup = runpy.run_path(sys.argv[1])
prepare = setup['install_whisper']
def unexpected_download(_):
    raise AssertionError('Ein bereits installiertes Modell darf nicht geladen werden')
flock = fcntl.flock
def observed_flock(file, operation):
    print('waiting', flush=True)
    return flock(file, operation)
fcntl.flock = observed_flock
prepare.__globals__.update(WHISPER_BYTES=int(sys.argv[3]), WHISPER_SHA=sys.argv[4],
                           download_whisper=unexpected_download)
prepare(pathlib.Path(sys.argv[2]))
"""
            with target.with_suffix(".bin.lock").open("wb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                with subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        driver,
                        str(script),
                        directory,
                        str(len(model)),
                        hashlib.sha256(model).hexdigest(),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                ) as child:
                    try:
                        self.assertTrue(select.select([child.stdout], [], [], 5)[0])
                        self.assertEqual(child.stdout.readline().strip(), "waiting")
                        self.assertIsNone(child.poll())
                        target.write_bytes(model)
                        fcntl.flock(lock, fcntl.LOCK_UN)
                        _, error = child.communicate(timeout=10)
                        self.assertEqual(child.returncode, 0, error)
                    finally:
                        if child.poll() is None:
                            child.kill()
            self.assertEqual(target.read_bytes(), model)


if __name__ == "__main__":
    unittest.main()
