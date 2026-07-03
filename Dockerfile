FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    VNC_RESOLUTION=1280x720 \
    VNC_COL_DEPTH=24 \
    GITHUB_USER="user" \
    WORK=/workspaces/projects/.build.enc \
    BUILD=/workspaces/projects/build

RUN apt-get update \
    && dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        locales \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8 \
    && apt-get install -y --no-install-recommends \
        # Desktop & VNC
        xfce4 \
        xfce4-terminal \
        xterm \
        tigervnc-standalone-server \
        novnc \
        websockify \
        xauth \
        xfonts-base \
        xfonts-100dpi \
        xfonts-75dpi \
        x11-xserver-utils \
        dbus-x11 \
        ca-certificates \
        curl \
        bash \
        # Editors
        vim \
        vim-gtk3 \
        mousepad \
        # SSH client
        openssh-client \
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
        liblz4-dev \
        help2man \
        libelf-dev \
        texinfo \
        libboost-dev \
        git \
        perl \
        libswitch-perl \
        ccache \
        # 32-bit libs
        libc6:i386 \
        libncurses6:i386 \
        libstdc++6:i386 \
        lib32ncurses6 \
        libxft2 \
        libxft2:i386 \
        libxext6 \
        libxext6:i386 \
        bzip2 \
        # File-write watcher (needed by chipcraft-sweep.sh)
        inotify-tools \
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

# Allow ubuntu to run iptables and the build-remount wrapper via sudo.
# The wrapper remounts the build tmpfs with exec — Codespaces forces noexec
# on --tmpfs mounts, which prevents compiled binaries from running.
# Using a wrapper script avoids sudoers comma-parsing issues with mount -o.
RUN printf '%s\n' \
        "ubuntu ALL=(root) NOPASSWD: /sbin/iptables" \
        "ubuntu ALL=(root) NOPASSWD: /usr/local/bin/chipcraft-mount-exec.sh" \
        > /etc/sudoers.d/lab-iptables \
    && chmod 440 /etc/sudoers.d/lab-iptables

# Install Verilator + GTKWave via OSS CAD Suite (latest stable release)
# Queries the release LIST (not /releases/latest) and picks the newest entry
# that already has a linux-x64 .tgz asset attached. oss-cad-suite-build
# publishes a new nightly release tag before its per-platform assets finish
# uploading, so /releases/latest can point at a release with an empty assets
# array for a while — assets[0] on that raises IndexError, $OSS_URL ends up
# empty, and the download curl fails with no URL (this bit us in CI).
# To pin to a specific release instead: https://github.com/YosysHQ/oss-cad-suite-build/releases
RUN OSS_URL=$(curl -fsSL --max-time 30 \
        "https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases?per_page=10" \
        | python3 -c \
          "import sys, json; rels = json.load(sys.stdin); \
url = next((a['browser_download_url'] for r in rels for a in r['assets'] if 'linux-x64' in a['name'] and a['name'].endswith('.tgz')), ''); \
print(url)") \
    && test -n "$OSS_URL" \
    && echo "Downloading OSS CAD Suite: $OSS_URL" \
    && curl -fSL --retry 3 --retry-delay 10 --max-time 600 "$OSS_URL" \
       -o /tmp/oss-cad-suite.tgz \
    && tar xz -C /opt/ -f /tmp/oss-cad-suite.tgz \
    && rm /tmp/oss-cad-suite.tgz

ENV PATH="/opt/oss-cad-suite/bin:$PATH"

RUN useradd -m -s /bin/bash ubuntu

# Create ~/lab and own it as ubuntu *before* any tmpfs mount is declared at
# /home/ubuntu/lab/build. Without this, Docker/Codespaces auto-creates the
# missing parent directory itself to attach that mount — as root, with
# default 0755 — and ubuntu is left with read+execute but no write on ~/lab
# itself, breaking every clone/touch/mv into it. ubuntu's sudo is locked to
# iptables only (see below), so this can't be fixed later from inside the
# container — it has to be baked into the image.
RUN mkdir -p /workspaces/projects/.build.enc && chown -R ubuntu:ubuntu /workspaces

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY tools/chipcraft-mount-exec.sh  /usr/local/bin/chipcraft-mount-exec.sh
COPY tools/chipcraft-key-init.sh    /usr/local/bin/chipcraft-key-init.sh
COPY tools/chipcraft-tree.sh        /usr/local/bin/chipcraft-tree
COPY tools/chipcraft-decrypt-all.sh /usr/local/bin/chipcraft-decrypt-all.sh
COPY tools/chipcraft-sweep.sh     /usr/local/bin/chipcraft-sweep.sh
COPY tools/chipcraft-refresh-github-ips.sh /usr/local/bin/chipcraft-refresh-github
COPY tools/chipcraft-github-ssh-setup.sh /usr/local/bin/chipcraft-github-ssh-setup
COPY tools/watermark.py           /usr/local/bin/watermark.py
COPY tools/git-wrapper.sh         /usr/local/bin/git
COPY tools/chipcraft-vim-wrapper.sh /usr/local/bin/chipcraft-vim-wrapper.sh
COPY tools/pre-commit             /usr/local/lib/chipcraft-hooks/pre-commit
COPY tools/chipcraft-gitignore    /etc/chipcraft-gitignore
# System-wide gvim plugin: transparent in-memory decrypt/encrypt of *.enc
# (any source type, not just Verilog). Loaded for every user automatically —
# Debian/Ubuntu vim ships /usr/share/vim/vimfiles in 'runtimepath' by default.
COPY tools/chipcraft-crypt.vim    /usr/share/vim/vimfiles/plugin/chipcraft-crypt.vim
RUN chmod +x /usr/local/bin/chipcraft-mount-exec.sh \
             /usr/local/bin/chipcraft-key-init.sh \
             /usr/local/bin/chipcraft-tree \
             /usr/local/bin/chipcraft-decrypt-all.sh \
             /usr/local/bin/chipcraft-sweep.sh \
             /usr/local/bin/chipcraft-refresh-github \
             /usr/local/bin/chipcraft-github-ssh-setup \
             /usr/local/bin/watermark.py \
             /usr/local/bin/git \
             /usr/local/bin/chipcraft-vim-wrapper.sh \
             /usr/local/lib/chipcraft-hooks/pre-commit \
    # vi / vim / gvim all go through the wrapper — *.v args become *.v.enc
    && ln -sf /usr/local/bin/chipcraft-vim-wrapper.sh /usr/local/bin/vi \
    && ln -sf /usr/local/bin/chipcraft-vim-wrapper.sh /usr/local/bin/vim \
    && ln -sf /usr/local/bin/chipcraft-vim-wrapper.sh /usr/local/bin/gvim \
    # System-level git config: *.v excluded and hooksPath locked — root-owned, not writable by ubuntu
    # Use /usr/bin/git directly — the wrapper at /usr/local/bin/git blocks hooksPath changes
    && /usr/bin/git config --system core.excludesFile /etc/chipcraft-gitignore \
    && /usr/bin/git config --system core.hooksPath    /usr/local/lib/chipcraft-hooks \
    && chmod 444 /etc/gitconfig /etc/chipcraft-gitignore

COPY novnc-index.html /usr/share/novnc/index.html

# Rebrand the stock noVNC connect screen's "noVNC" logo to "ChipCraft".
# See novnc-rebrand.js header for why this is a runtime text-replace instead
# of patching vnc.html's markup directly (version-fragile).
COPY novnc-rebrand.js /usr/share/novnc/chipcraft-rebrand.js
RUN sed -i 's#</body>#<script src="chipcraft-rebrand.js"></script></body>#' \
        /usr/share/novnc/vnc.html

EXPOSE 6080

USER ubuntu
WORKDIR /home/ubuntu

ENTRYPOINT ["/entrypoint.sh"]
