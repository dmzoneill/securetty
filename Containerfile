FROM registry.fedoraproject.org/fedora:45

ARG UID=1000
ARG GID=1000
ARG USERNAME=daoneill
ARG QUARANTINE_DAYS=7

# System packages
RUN dnf install -y --setopt=install_weak_deps=False \
        nodejs npm \
        python3 python3-pip python3-devel \
        python3.12 python3.12-devel \
        git git-core curl jq make gcc g++ \
        findutils procps-ng which \
        openssh-clients gnupg2 \
        unzip tar xz \
        gnome-shell mutter-devkit dbus-daemon dbus-tools \
        glib2 glib2-devel gsettings-desktop-schemas \
        mesa-dri-drivers mesa-libEGL \
        xdg-utils socat \
        gjs gnome-extensions-app dconf \
        gh glab sshpass \
        awscli2 \
        rpm-build dnf-plugins-core \
        ansible-core python3-ansible-lint \
        skopeo podman-remote \
        sqlite tree man-db \
        bind-utils nmap-ncat nmap iproute iputils \
        hostname net-tools ncat \
        ffmpeg ImageMagick \
        pulseaudio-utils pipewire-pulseaudio \
        sound-theme-freedesktop \
        libxml2 python3-lxml \
        gettext sassc \
        ruff python3-flake8 yamllint \
        python3-pytest \
        pciutils lsof util-linux \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Ensure python3.12 has pip
RUN python3.12 -m ensurepip --upgrade 2>/dev/null || true

# pip-only tools (not in Fedora repos)
RUN python3.12 -m pip install --break-system-packages \
        black pyright pipenv pandoc kubernetes

# Verify Node >= 22 (required by Codex CLI, Cline)
RUN node_ver=$(node -v | sed 's/v//' | cut -d. -f1) \
    && if [ "$node_ver" -lt 22 ]; then \
         echo "ERROR: Node $node_ver < 22, Codex/Cline require 22+"; exit 1; \
       fi

# Install uv (for pip --exclude-newer support)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv \
    && mv /root/.local/bin/uvx /usr/local/bin/uvx 2>/dev/null || true

# =============================================================================
# Delayed agent installation — versions >= QUARANTINE_DAYS old
# =============================================================================
COPY scripts/install-delayed.sh /tmp/install-delayed.sh
RUN chmod +x /tmp/install-delayed.sh \
    && QUARANTINE_DAYS=${QUARANTINE_DAYS} /tmp/install-delayed.sh \
    && rm /tmp/install-delayed.sh

# =============================================================================
# User setup — same username and home path as host
# =============================================================================
RUN groupadd -g ${GID} ${USERNAME} \
    && useradd -u ${UID} -g ${GID} -m -s /bin/bash ${USERNAME}

# GPG agent socket dir
RUN mkdir -p /home/${USERNAME}/.gnupg \
    && chmod 700 /home/${USERNAME}/.gnupg \
    && chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.gnupg

# npm config: skip install scripts by default for project deps
RUN echo "ignore-scripts=true" > /home/${USERNAME}/.npmrc \
    && chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.npmrc

# pip config: require virtualenv for project deps
RUN mkdir -p /home/${USERNAME}/.config/pip \
    && cat > /home/${USERNAME}/.config/pip/pip.conf <<'EOF'
[global]
require-virtualenv = true

[install]
no-deps = false
EOF
RUN chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config

# Create all mount point dirs for host bind mounts + named volumes
RUN mkdir -p \
    /home/${USERNAME}/src \
    /home/${USERNAME}/bin \
    /home/${USERNAME}/.kube \
    /home/${USERNAME}/.aws \
    /home/${USERNAME}/.local/share/virtualenvs \
    /workspace/.securetty \
    # Claude Code
    /home/${USERNAME}/.claude/projects \
    /home/${USERNAME}/.claude/plugins \
    /home/${USERNAME}/.claude/plans \
    /home/${USERNAME}/.claude/sessions \
    /home/${USERNAME}/.claude/shell-snapshots \
    /home/${USERNAME}/.claude/cache \
    /home/${USERNAME}/.claude/debug \
    /home/${USERNAME}/.claude/downloads \
    # Codex
    /home/${USERNAME}/.codex/sessions \
    /home/${USERNAME}/.codex/skills \
    # Gemini
    /home/${USERNAME}/.gemini/history \
    /home/${USERNAME}/.gemini/sessions \
    # Cursor
    /home/${USERNAME}/.cursor/skills-cursor \
    /home/${USERNAME}/.cursor/plugins \
    /home/${USERNAME}/.cursor/projects \
    /home/${USERNAME}/.cursor/plans \
    # Kiro
    /home/${USERNAME}/.kiro/sessions \
    /home/${USERNAME}/.kiro/agents \
    # Cline
    /home/${USERNAME}/.cline/data/tasks \
    /home/${USERNAME}/.cline/log \
    # OpenCode
    /home/${USERNAME}/.config/opencode/commands \
    /home/${USERNAME}/.local/share/opencode \
    # Amp
    /home/${USERNAME}/.amp \
    # Kilo Code
    /home/${USERNAME}/.config/kilo \
    # Aider
    /home/${USERNAME}/.aider \
    # OpenHands
    /home/${USERNAME}/.openhands/conversations \
    # Goose
    /home/${USERNAME}/.config/goose/sessions \
    # Grok Build
    /home/${USERNAME}/.grok \
    # Forge
    /home/${USERNAME}/.forge \
    /home/${USERNAME}/.local/bin \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME} /workspace

# No-op stubs for hooks that reference host-only scripts
RUN touch /home/${USERNAME}/.local/bin/claude-post-commit-hook.sh \
    && chmod +x /home/${USERNAME}/.local/bin/claude-post-commit-hook.sh

# Copy project install script
COPY --chown=${USERNAME}:${USERNAME} scripts/install.sh /workspace/.securetty/install.sh
RUN chmod +x /workspace/.securetty/install.sh

# SSH config — route git SSH through egress-proxy
RUN mkdir -p /home/${USERNAME}/.ssh \
    && cat > /home/${USERNAME}/.ssh/config.securetty <<'EOF'
# Git SSH routed through egress-proxy (Envoy L4)
Host github.com
    ProxyCommand nc -X connect -x egress-proxy:3128 %h %p

Host gitlab.com gitlab.cee.redhat.com
    ProxyCommand nc -X connect -x egress-proxy:3128 %h %p
EOF
RUN chmod 700 /home/${USERNAME}/.ssh \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh

# xdg-open shim — sends URLs to host relay socket instead of opening locally
COPY scripts/xdg-open /usr/local/bin/xdg-open
RUN chmod +x /usr/local/bin/xdg-open

# Entrypoint — age banner on TTY, then exec command
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ${USERNAME}
WORKDIR /home/${USERNAME}/src

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
