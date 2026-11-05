FROM swift:6.2.1-noble@sha256:0e4716bd34384d22963a63afbdbc93be3129dfd0753185aa1ded27755abdcae8
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    cmake ninja-build g++ pkg-config qt6-base-dev qt6-multimedia-dev qt6-wayland qt6-translations-l10n \
    qt6-base-private-dev qt6-wayland-dev qt6-wayland-private-dev qt6-declarative-dev extra-cmake-modules wayland-protocols libwayland-dev libxkbcommon-dev \
    libx11-dev libxtst-dev libatspi2.0-dev libqrencode-dev libpulse-dev libssl-dev libvulkan-dev glslc ffmpeg espeak-ng \
    xz-utils patch patchelf libsecret-tools ca-certificates curl git && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN curl -fL --retry 2 https://github.com/microsoft/onnxruntime/releases/download/v1.28.2/onnxruntime-linux-x64-1.28.2.tgz -o /tmp/onnxruntime.tgz && \
    echo 'd7209b8751b27b862b0c76332c2e20e203396edb5dab700ecf4bb485cf147415  /tmp/onnxruntime.tgz' | sha256sum -c - && \
    mkdir -p /opt/onnxruntime && tar -xzf /tmp/onnxruntime.tgz --strip-components=1 -C /opt/onnxruntime && \
    cp -a /opt/onnxruntime/include/. /usr/local/include/ && rm /tmp/onnxruntime.tgz

COPY linux/layer-shell-qt-geometry.patch /tmp/layer-shell-geometry.patch
RUN curl -fL --retry 2 https://download.kde.org/stable/plasma/5.27.9/layer-shell-qt-5.27.9.tar.xz -o /tmp/layershell.tar.xz && \
    echo '67207ed9f764280da309d735dd1b0788187a7a9efcbb4f5b2849c723ee66886f  /tmp/layershell.tar.xz' | sha256sum -c - && \
    mkdir -p /opt/stillepost-layershell-src && tar -xf /tmp/layershell.tar.xz --strip-components=1 -C /opt/stillepost-layershell-src && \
    cd /opt/stillepost-layershell-src && patch -p1 < /tmp/layer-shell-geometry.patch && \
    cmake -S /opt/stillepost-layershell-src -B /opt/stillepost-layershell-build -G Ninja -DQT_MAJOR_VERSION=6 -DBUILD_WITH_QT6=ON -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local && \
    cmake --build /opt/stillepost-layershell-build -j4 && cmake --install /opt/stillepost-layershell-build && ldconfig && rm /tmp/layershell.tar.xz
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends meson && rm -rf /var/lib/apt/lists/* && \
    curl -fL --retry 2 https://codeload.github.com/bugaevc/wl-clipboard/tar.gz/refs/tags/v2.3.0 -o /tmp/wl-clipboard.tar.gz && \
    echo 'b4dc560973f0cd74e02f817ffa2fd44ba645a4f1ea94b7b9614dacc9f895f402  /tmp/wl-clipboard.tar.gz' | sha256sum -c - && \
    mkdir -p /opt/stillepost-wl-clipboard-src && tar -xf /tmp/wl-clipboard.tar.gz --strip-components=1 -C /opt/stillepost-wl-clipboard-src && \
    meson setup /opt/stillepost-wl-clipboard-build /opt/stillepost-wl-clipboard-src --prefix=/usr/local --buildtype=release && \
    ninja -C /opt/stillepost-wl-clipboard-build install && rm /tmp/wl-clipboard.tar.gz
