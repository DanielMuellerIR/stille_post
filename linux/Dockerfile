FROM swift:6.2.1-noble@sha256:0e4716bd34384d22963a63afbdbc93be3129dfd0753185aa1ded27755abdcae8
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    cmake ninja-build g++ pkg-config qt6-base-dev qt6-multimedia-dev qt6-wayland \
    libx11-dev libxtst-dev libssl-dev libvulkan-dev glslc ffmpeg espeak-ng \
    patchelf libsecret-tools ca-certificates curl git && rm -rf /var/lib/apt/lists/*
WORKDIR /src
