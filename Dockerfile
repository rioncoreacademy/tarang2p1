FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    VNC_RESOLUTION=1280x720 \
    VNC_COL_DEPTH=24

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
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
        vim \
        vim-gtk3 \
        sdcc \
        build-essential \
        verilator \
        gtkwave \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends openssl \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/chipcraft

COPY chipcraft-run.sh /usr/local/bin/vrun
RUN chmod +x /usr/local/bin/vrun

RUN useradd -m -s /bin/bash ubuntu

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY novnc-index.html /usr/share/novnc/index.html
COPY vnc.html /usr/share/novnc/vnc.html

EXPOSE 6080

USER ubuntu
WORKDIR /home/ubuntu

ENTRYPOINT ["/entrypoint.sh"]
