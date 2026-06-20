FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    VNC_RESOLUTION=1280x720 \
    VNC_COL_DEPTH=24 \
    GITHUB_USER="student"

RUN apt-get update \
    && dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        # Desktop & VNC
        xfce4 \
        xfce4-terminal \
        tigervnc-standalone-server \
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
        # File-save watcher (needed by decrypt_watch.sh)
        inotify-tools \
        bzip2 \
        # Egress firewall (blocks students uploading decrypted files to internet)
        iptables \
        sudo \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install SDCC 4.5.0 from official SourceForge binary (apt ships 4.0.0)
# To upgrade later: https://sourceforge.net/projects/sdcc/files/sdcc-linux-amd64/
RUN curl -fSL \
       "https://sourceforge.net/projects/sdcc/files/sdcc-linux-amd64/4.5.0/sdcc-4.5.0-amd64-unknown-linux2.5.tar.bz2/download" \
       -o /tmp/sdcc.tar.bz2 \
    && tar -xjf /tmp/sdcc.tar.bz2 -C /usr/local --strip-components=1 \
    && rm /tmp/sdcc.tar.bz2

# Allow ubuntu to run only iptables via sudo (no full root access)
RUN echo "ubuntu ALL=(root) NOPASSWD: /sbin/iptables" \
        > /etc/sudoers.d/lab-iptables \
    && chmod 440 /etc/sudoers.d/lab-iptables

# Install Verilator + GTKWave via OSS CAD Suite (pinned release)
# To upgrade: https://github.com/YosysHQ/oss-cad-suite-build/releases
RUN curl -fSL \
    "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-06-19/oss-cad-suite-linux-x64-20260619.tgz" \
    | tar xz -C /opt/

ENV PATH="/opt/oss-cad-suite/bin:$PATH"

RUN useradd -m -s /bin/bash ubuntu

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY tools/decrypt_watch.sh /usr/local/bin/decrypt_watch.sh
COPY tools/watermark.py    /usr/local/bin/watermark.py
COPY tools/git-wrapper.sh  /usr/local/bin/git
COPY tools/pre-commit      /usr/local/lib/chipcraft-hooks/pre-commit
RUN chmod +x /usr/local/bin/decrypt_watch.sh \
             /usr/local/bin/watermark.py \
             /usr/local/bin/git \
             /usr/local/lib/chipcraft-hooks/pre-commit

COPY novnc-index.html /usr/share/novnc/index.html

EXPOSE 6080

USER ubuntu
WORKDIR /home/ubuntu

ENTRYPOINT ["/entrypoint.sh"]
