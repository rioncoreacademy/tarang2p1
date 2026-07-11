FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
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
        # Icon themes (gnome-icon-theme is gone from Ubuntu repos since ~19.10;
        # adwaita-icon-theme is its replacement) — fixes gvim toolbar buttons
        # rendering as identical/generic squares under XFCE's GTK theme.
        adwaita-icon-theme \
        hicolor-icon-theme \
        # This desktop runs XFCE, not GNOME — elementary-xfce is Xubuntu's
        # own native icon theme (vs. Adwaita, GNOME's), set active below.
        elementary-xfce-icon-theme \
        # Line-ending conversion (Windows CRLF -> Unix LF)
        dos2unix \
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
        # File-write watcher (needed by tarang2-dp1-sweep.sh)
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
        "ubuntu ALL=(root) NOPASSWD: /usr/local/bin/tarang2-dp1-mount-exec.sh" \
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

COPY tools/tarang2-dp1-mount-exec.sh  /usr/local/bin/tarang2-dp1-mount-exec.sh
COPY tools/tarang2-dp1-key-init.sh    /usr/local/bin/tarang2-dp1-key-init.sh
COPY tools/tarang2-dp1-tree.sh        /usr/local/bin/tarang2-dp1-tree
COPY tools/tarang2-dp1-decrypt-all.sh /usr/local/bin/tarang2-dp1-decrypt-all.sh
COPY tools/tarang2-dp1-sweep.sh     /usr/local/bin/tarang2-dp1-sweep.sh
COPY tools/tarang2-dp1-refresh-github-ips.sh /usr/local/bin/tarang2-dp1-refresh-github
COPY tools/tarang2-dp1-github-ssh-setup.sh /usr/local/bin/tarang2-dp1-github-ssh-setup
COPY tools/watermark.py           /usr/local/bin/watermark.py
COPY tools/git-wrapper.sh         /usr/local/bin/git
COPY tools/tarang2-dp1-vim-wrapper.sh /usr/local/bin/tarang2-dp1-vim-wrapper.sh
COPY tools/pre-commit             /usr/local/lib/tarang2-dp1-hooks/pre-commit
COPY tools/tarang2-dp1-gitignore    /etc/tarang2-dp1-gitignore
# System-wide gvim plugin: transparent in-memory decrypt/encrypt of *.enc
# (any source type, not just Verilog). Loaded for every user automatically —
# Debian/Ubuntu vim ships /usr/share/vim/vimfiles in 'runtimepath' by default.
COPY tools/tarang2-dp1-crypt.vim    /usr/share/vim/vimfiles/plugin/tarang2-dp1-crypt.vim
RUN chmod +x /usr/local/bin/tarang2-dp1-mount-exec.sh \
             /usr/local/bin/tarang2-dp1-key-init.sh \
             /usr/local/bin/tarang2-dp1-tree \
             /usr/local/bin/tarang2-dp1-decrypt-all.sh \
             /usr/local/bin/tarang2-dp1-sweep.sh \
             /usr/local/bin/tarang2-dp1-refresh-github \
             /usr/local/bin/tarang2-dp1-github-ssh-setup \
             /usr/local/bin/watermark.py \
             /usr/local/bin/git \
             /usr/local/bin/tarang2-dp1-vim-wrapper.sh \
             /usr/local/lib/tarang2-dp1-hooks/pre-commit \
    # vi / vim / gvim all go through the wrapper — *.v args become *.v.enc
    && ln -sf /usr/local/bin/tarang2-dp1-vim-wrapper.sh /usr/local/bin/vi \
    && ln -sf /usr/local/bin/tarang2-dp1-vim-wrapper.sh /usr/local/bin/vim \
    && ln -sf /usr/local/bin/tarang2-dp1-vim-wrapper.sh /usr/local/bin/gvim \
    # System-level git config: *.v excluded and hooksPath locked — root-owned, not writable by ubuntu
    # Use /usr/bin/git directly — the wrapper at /usr/local/bin/git blocks hooksPath changes
    && /usr/bin/git config --system core.excludesFile /etc/tarang2-dp1-gitignore \
    && /usr/bin/git config --system core.hooksPath    /usr/local/lib/tarang2-dp1-hooks \
    && chmod 444 /etc/gitconfig /etc/tarang2-dp1-gitignore

COPY novnc-index.html /usr/share/novnc/index.html

# The Ubuntu-packaged novnc (1.0.0-5) predates defaults.json/mandatory.json
# support entirely (verified: no reference to either in its ui.js), so a
# dropped-in config file is silently ignored. The only way to change its
# default behavior is patching the hardcoded default in ui.js itself.
# This flips "resize" from 'off' to 'remote': TigerVNC's Xvnc here already
# supports RandR/ExtendedDesktopSize (confirmed via XFCE's own Display
# settings showing a resizable VNC-0 output), so 'remote' has the X session
# itself resize to match the browser viewport exactly — sharper and simpler
# than client-side canvas scaling, and needs no user interaction with the
# settings gear.
RUN sed -i "s/UI.initSetting('resize', 'off');/UI.initSetting('resize', 'remote');/" \
        /usr/share/novnc/app/ui.js

# Rebrand the stock noVNC connect screen: hide the "noVNC" logo (the
# background image below already carries the RionCore Academy branding, so
# a second on-screen logo just visually collides with it). See
# novnc-rebrand.js header for why this is a runtime text-search instead of
# patching vnc.html's markup directly (version-fragile).
COPY novnc-rebrand.js /usr/share/novnc/tarang2-dp1-rebrand.js
RUN sed -i 's#</body>#<script src="tarang2-dp1-rebrand.js"></script></body>#' \
        /usr/share/novnc/vnc.html

# Default XFCE desktop wallpaper (RionCore Academy branding). Baked in
# read-only here; entrypoint.sh points xfdesktop at this fixed path at
# every container start rather than us guessing a per-user default.
COPY vnc_background.png /usr/share/backgrounds/tarang2p1-background.png
RUN chmod 444 /usr/share/backgrounds/tarang2p1-background.png

# RionCore Academy branding on the noVNC pre-connect landing page.
# Deliberately a DIFFERENT image (vnc_background_1.png) than the desktop
# wallpaper above, by request. Has to live under /usr/share/novnc/ since
# that's the only directory websockify's static file server
# (--web=/usr/share/novnc/) actually serves over HTTP.
COPY vnc_background_1.png /usr/share/novnc/vnc_background_1.png
RUN chmod 444 /usr/share/novnc/vnc_background_1.png

# Montserrat (SIL OFL licensed, github.com/google/fonts) to match the
# branding image's own typeface. Bundled as a font file rather than a
# Google Fonts <link> since the running container's egress firewall only
# allows GitHub/Cloudflare — a CDN font request would just hang.
COPY Montserrat-Variable.ttf /usr/share/novnc/Montserrat-Variable.ttf
RUN chmod 444 /usr/share/novnc/Montserrat-Variable.ttf

RUN sed -i 's|<img src="app/images/connect.svg"> Connect|<img src="app/images/connect.svg"> VNC - Start Session|' \
        /usr/share/novnc/vnc.html
RUN sed -i 's|<body>|<body><style>#noVNC_container{background-color:transparent!important}@font-face{font-family:Montserrat;src:url(Montserrat-Variable.ttf);font-weight:400 800}body{font-family:Montserrat,sans-serif}#noVNC_connect_dlg.noVNC_open{transform:translateY(-8vh) translateX(14vw) scale(1,1)!important}#noVNC_connect_button{background-color:#facc15!important;color:#1a1a1a!important;font-weight:bold!important;font-size:24px!important}#noVNC_connect_button div{background:#facc15!important;border-color:#a16207!important}</style><img src="vnc_background_1.png" style="position:fixed;top:5vh;left:5vw;width:90vw;height:90vh;object-fit:contain;z-index:-1;pointer-events:none">|' \
        /usr/share/novnc/vnc.html

# Hide the Clipboard button/panel in the noVNC sidebar. It's a client-side
# text sync between the browser and the remote desktop, independent of
# Xvnc's -noclipboard flag (entrypoint.sh) — leaving it visible would give
# students another path to copy decrypted text out of the container.
# #noVNC_clipboard_button / #noVNC_clipboard are noVNC's own stable IDs
# (referenced by its ui.js), so a CSS hide is safe across point releases.
RUN sed -i 's|</body>|<style>#noVNC_clipboard_button,#noVNC_clipboard{display:none!important}</style></body>|' \
        /usr/share/novnc/vnc.html

EXPOSE 6080

USER ubuntu
WORKDIR /home/ubuntu

ENTRYPOINT ["/entrypoint.sh"]
