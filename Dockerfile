FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    VNC_RESOLUTION=1280x720 \
    VNC_COL_DEPTH=24

RUN apt-get update \
    && dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        # Desktop & VNC
        xfce4 \
        xfce4-terminal \
        tightvncserver \
        novnc \
        websockify \
        xauth \
        xfonts-base \
        x11-xserver-utils \
        dbus-x11 \
        ca-certificates \
        curl \
        bash \
        # Editors
        vim \
        vim-gtk3 \
        mousepad \
        # Python
        python3 \
        python3-pip \
        # GTKWave waveform viewer
        gtkwave \
        # C compiler for microcontrollers
        sdcc \
        # Build tools (also needed for Verilator build)
        build-essential \
        autoconf \
        bison \
        flex \
        libfl2 \
        libfl-dev \
        zlib1g-dev \
        help2man \
        libelf-dev \
        texinfo \
        libboost-dev \
        git \
        perl \
        ccache \
        # 32-bit libs
        libc6:i386 \
        libncurses5:i386 \
        libstdc++6:i386 \
        lib32ncurses6 \
        libxft2 \
        libxft2:i386 \
        libxext6 \
        libxext6:i386 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Build Verilator latest stable from source
RUN git clone https://github.com/verilator/verilator --branch stable --depth 1 /tmp/verilator \
    && cd /tmp/verilator \
    && autoconf \
    && ./configure \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/verilator

RUN useradd -m -s /bin/bash ubuntu

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY novnc-index.html /usr/share/novnc/index.html

EXPOSE 6080

USER ubuntu
WORKDIR /home/ubuntu

ENTRYPOINT ["/entrypoint.sh"]
