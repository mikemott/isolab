FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# ── Core tools ──────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    build-essential \
    curl wget git \
    python3 python3-pip python3-venv \
    nodejs npm \
    openssh-server \
    tmux \
    vim nano \
    jq ripgrep fd-find bat \
    tree unzip zip \
    htop \
    sudo cron \
    direnv \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js LTS via n ──────────────────────────────────
RUN npm install -g n && n lts && hash -r

# ── uv (fast Python package manager) ──────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# ── Starship prompt ────────────────────────────────────
RUN curl -sS https://starship.rs/install.sh | sh -s -- -y

# ── Create sandbox user ───────────────────────────────
RUN useradd -m -s /bin/bash -G sudo sandbox && \
    echo 'sandbox ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# ── SSH server ─────────────────────────────────────────
RUN mkdir /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    echo "AllowUsers sandbox" >> /etc/ssh/sshd_config

RUN mkdir -p /home/sandbox/.ssh && \
    chmod 700 /home/sandbox/.ssh && \
    chown sandbox:sandbox /home/sandbox/.ssh

# ── Directories ────────────────────────────────────────
RUN mkdir -p /home/sandbox/workspace \
             /home/sandbox/logs \
             /home/sandbox/.config && \
    chown -R sandbox:sandbox /home/sandbox

# ── Config files ───────────────────────────────────────
COPY tmux.conf /home/sandbox/.tmux.conf
COPY starship.toml /home/sandbox/.config/starship.toml
COPY bashrc /home/sandbox/.bashrc
RUN chown -R sandbox:sandbox /home/sandbox/.config \
    /home/sandbox/.tmux.conf /home/sandbox/.bashrc

# ── MOTD ───────────────────────────────────────────────
RUN rm -rf /etc/update-motd.d/*
COPY motd.sh /etc/update-motd.d/00-isolab
RUN chmod +x /etc/update-motd.d/00-isolab

# ── Disk watchdog ──────────────────────────────────────
COPY disk-watchdog.sh /usr/local/bin/disk-watchdog
RUN chmod +x /usr/local/bin/disk-watchdog && \
    echo "*/10 * * * * sandbox /usr/local/bin/disk-watchdog" > /etc/cron.d/disk-watchdog && \
    chmod 0644 /etc/cron.d/disk-watchdog

# ── Entrypoint ─────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /home/sandbox/workspace
EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
