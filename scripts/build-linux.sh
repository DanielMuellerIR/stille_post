#!/bin/bash
# Linux-Build bleibt vollständig im Projektverzeichnis und installiert nichts.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
builder=stillepost-linux-builder:6.2.1
mkdir -p build/linux
if ! docker image inspect "$builder" >/dev/null 2>&1; then
    docker build -t "$builder" -f linux/Dockerfile .
fi
if [[ ! -d build/linux/whisper-src/.git ]]; then
    git clone --depth 1 --branch v1.8.4 https://github.com/ggml-org/whisper.cpp.git build/linux/whisper-src
fi
[[ $(git -C build/linux/whisper-src rev-parse HEAD) == 9386f239401074690479731c1e41683fbbeac557 ]] || { echo 'Falscher Whisper-Quellstand' >&2; exit 1; }
if [[ ! -x build/linux/ollama/bin/ollama ]]; then
    curl -fL --retry 2 -o build/linux/ollama-linux-amd64.tar.zst https://github.com/ollama/ollama/releases/download/v0.40.14/ollama-linux-amd64.tar.zst
    echo '993e83d08c3d13d17c55009a3e2664c8a25445e644aec3a68bef5abb6abce67d  build/linux/ollama-linux-amd64.tar.zst' | sha256sum -c -
    mkdir -p build/linux/ollama
    tar --zstd -xf build/linux/ollama-linux-amd64.tar.zst -C build/linux/ollama --exclude='lib/ollama/cuda*'
fi
# SwiftPM verändert unter Linux sonst Package.resolved des macOS-Targets.
source_dir=$(mktemp -d "$root/build/linux/source.XXXXXXXX")
trap 'rm -rf -- "$source_dir"' EXIT
cp -a Package.swift Sources Tests "$source_dir/"
source_relative=${source_dir#"$root/"}
docker run --rm --user "$(id -u):$(id -g)" -v "$root:/src" -w /src -e SWIFT_SOURCE="$source_relative" "$builder" bash -eu -c '
    swift test --package-path "$SWIFT_SOURCE" --scratch-path /src/build/linux/swift
    swift build --package-path "$SWIFT_SOURCE" --scratch-path /src/build/linux/swift -c release --product stillepost-linux
    cmake -S linux -B build/linux/qt -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build build/linux/qt -j4
    cmake -S build/linux/whisper-src -B build/linux/whisper -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_CURL=OFF
    cmake --build build/linux/whisper --target whisper-server -j8
    SWIFT_BINARY_DIR=/src/build/linux/swift/release python3 linux/bundle.py
'
version=$(cat VERSION)
tar -C build/linux -I 'gzip -1' -cf "build/StillePost-$version-linux-x86_64.tar.gz" StillePost.AppDir
sha256sum "build/StillePost-$version-linux-x86_64.tar.gz" > "build/StillePost-$version-linux-x86_64.tar.gz.sha256"
echo "LINUX BUILD OK: build/StillePost-$version-linux-x86_64.tar.gz"
