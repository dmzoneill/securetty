FROM localhost/securetty_base:latest

ARG UID=1000
ARG GID=1000
ARG USERNAME=daoneill
ARG QUARANTINE_DAYS=7

# System packages (base image already has nodejs, npm, python3.12, curl, jq, uv)
RUN dnf install -y --setopt=install_weak_deps=False \
        gsettings-desktop-schemas golang sqlite nmap-ncat ansible-core xdg-utils libxml2 sassc dconf which mesa-dri-drivers gh dbus-daemon python3-pip net-tools python3-devel awscli2 gnome-shell python3 git gnome-extensions-app rpm-build lsof glib2 findutils util-linux gettext tar dbus-tools python3-lxml xz skopeo ncat ImageMagick gjs hostname man-db sshpass python3-pytest dnf-plugins-core ruff openssh-clients pciutils g++ iputils glib2-devel podman-remote glab git-core make yamllint pulseaudio-utils bind-utils mesa-libEGL iproute pipewire-pulseaudio socat sound-theme-freedesktop mutter-devkit gnupg2 unzip gcc nmap python3-flake8 python3-ansible-lint tree ffmpeg \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# pip-only tools (not in Fedora repos)
RUN python3.12 -m pip install --break-system-packages black
RUN python3.12 -m pip install --break-system-packages pyright
RUN python3.12 -m pip install --break-system-packages pipenv
RUN python3.12 -m pip install --break-system-packages pandoc
RUN python3.12 -m pip install --break-system-packages kubernetes

# Verify Node >= 22 (required by Codex CLI, Cline)
RUN node_ver=$(node -v | sed 's/v//' | cut -d. -f1) \
    && if [ "$node_ver" -lt 22 ]; then \
         echo "ERROR: Node $node_ver < 22, Codex/Cline require 22+"; exit 1; \
       fi

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
    /home/${USERNAME}/.claude \
    /home/${USERNAME}/.codex \
    /home/${USERNAME}/.gemini \
    /home/${USERNAME}/.cursor \
    /home/${USERNAME}/.kiro \
    /home/${USERNAME}/.cline \
    /home/${USERNAME}/.config/opencode \
    /home/${USERNAME}/.local/share/opencode \
    /home/${USERNAME}/.openhands \
    /home/${USERNAME}/.config/goose \
    /home/${USERNAME}/.grok \
    /home/${USERNAME}/.forge \
    /home/${USERNAME}/.amp \
    /home/${USERNAME}/.config/kilo \
    /home/${USERNAME}/.aider \
    /home/${USERNAME}/.config/gcloud \
    /home/${USERNAME}/.local/bin \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME} /workspace

# No-op stubs for hooks that reference host-only scripts
RUN touch /home/${USERNAME}/.local/bin/claude-post-commit-hook.sh \
    && chmod +x /home/${USERNAME}/.local/bin/claude-post-commit-hook.sh

# Copy project install script
COPY --chown=${USERNAME}:${USERNAME} scripts/install.sh /workspace/.securetty/install.sh
RUN chmod +x /workspace/.securetty/install.sh

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
