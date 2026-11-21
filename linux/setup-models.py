#!/usr/bin/env python3
"""Öffentliche Modelle einmalig und geprüft im privaten Benutzerdatenordner ablegen."""
import fcntl
import hashlib
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request

REVISION = "5359861c739e955e79d9a303bcbc70fb988958b1"
WHISPER_SHA = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
WHISPER_BYTES = 1624555275
WHISPER_LARGE_SHA = "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"
GEMMA_SHA = "ee665637121887cf3befff38abbb1be4ee117c7db867d97a67e29049ecd7e15f"
bundle = pathlib.Path(__file__).resolve().parent
root = (
    pathlib.Path(
        os.environ.get("XDG_DATA_HOME", str(pathlib.Path.home() / ".local/share"))
    )
    / "stillepost"
)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1048576), b""):
            h.update(block)
    return h.hexdigest()


def install_whisper(models):
    models.mkdir(parents=True, exist_ok=True)
    target = models / "ggml-large-v3-turbo.bin"
    descriptor = os.open(
        target.with_suffix(".bin.lock"),
        os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK,
        0o600,
    )
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise RuntimeError("Die Modellsperre ist keine reguläre Datei.")
        # Dieselbe Zieldatei wie bei der Modellinstallation aus der App.
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        if os.path.lexists(target):
            hashes = {WHISPER_BYTES: WHISPER_SHA, 3095033483: WHISPER_LARGE_SHA}
            expected = hashes.get(target.stat().st_size) if target.is_file() else None
            if expected is None or digest(target) != expected:
                raise RuntimeError(
                    "Vorhandenes Whisper-Modell hat eine andere Prüfsumme; Datei bleibt erhalten."
                )
            return
        download_whisper(target)
    finally:
        os.close(descriptor)


def download_whisper(target):
    with tempfile.TemporaryDirectory(prefix=".whisper-", dir=target.parent) as stage:
        temporary = pathlib.Path(stage) / target.name
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        print("Whisper large-v3-turbo laden (1,6 GB) …", flush=True)
        with opener.open(
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/"
            + REVISION
            + "/ggml-large-v3-turbo.bin",
            timeout=30,
        ) as response, temporary.open("wb") as out:
            count = 0
            while True:
                block = response.read(1048576)
                if not block:
                    break
                count += len(block)
                if count > WHISPER_BYTES:
                    raise RuntimeError("Modell ist zu groß.")
                out.write(block)
        if digest(temporary) != WHISPER_SHA:
            raise RuntimeError("Whisper-Prüfsumme stimmt nicht.")
        temporary.rename(target)


def main():
    os.umask(0o077)
    install_whisper(root / "models")
    env = dict(
        os.environ,
        OLLAMA_HOST="127.0.0.1:11434",
        OLLAMA_MODELS=str(root / "ollama-models"),
        OLLAMA_NUM_PARALLEL="1",
        OLLAMA_MAX_LOADED_MODELS="1",
        LD_LIBRARY_PATH=str(bundle / "lib"),
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    owned = None
    try:
        try:
            opener.open("http://127.0.0.1:11434/api/tags", timeout=1).close()
        except OSError:
            owned = subprocess.Popen(
                [str(bundle / "bin/ollama"), "serve"],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            for _ in range(40):
                try:
                    opener.open("http://127.0.0.1:11434/api/tags", timeout=0.5).close()
                    break
                except OSError:
                    time.sleep(0.25)
        print("Lokalen Gemma-Fallback laden (etwa 6,2 GB) …", flush=True)
        subprocess.run(
            [str(bundle / "bin/ollama"), "pull", "gemma4:e4b-it-qat"],
            env=env,
            check=True,
        )
        request = urllib.request.Request("http://127.0.0.1:11434/api/tags")
        data = json.load(opener.open(request, timeout=5))
        found = next(
            (m for m in data.get("models", []) if m.get("name") == "gemma4:e4b-it-qat"),
            None,
        )
        if not found or found.get("digest") != GEMMA_SHA:
            raise RuntimeError(
                "Gemma-Modellstand hat sich geändert; erneuter Qualitätsabgleich erforderlich."
            )
    finally:
        if owned:
            owned.terminate()
            try:
                owned.wait(timeout=5)
            except subprocess.TimeoutExpired:
                owned.kill()
                owned.wait()
    print("Modelle sind geprüft und bereit.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Einrichtung fehlgeschlagen: " + str(error), file=sys.stderr)
        sys.exit(1)
