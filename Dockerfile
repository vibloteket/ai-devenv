FROM ubuntu:25.10 AS base

ARG USERNAME=ai
ARG USER_UID=1000
ARG USER_GID=1000
ARG GIT_USER
ARG GIT_EMAIL

# Rename the existing ubuntu user to ai (if it exists)
RUN if id ubuntu &>/dev/null; then \
        usermod -l ai ubuntu && \
        groupmod -n ai ubuntu && \
        usermod -d /home/ai -m ai; \
    else \
        useradd -m -s /bin/bash ai; \
    fi

# General tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    fish \
    git \
    gyp \
    gnupg \
    jq \
    less \
    nano \
    ripgrep \
    socat \
    tar \
    unzip \
    wget \
    file \
    tree \
    tmux \
    strace \
    openssh-client \
    # C
    cmake clang-format \
    # For documentation generation
    doxygen \
    # Java
    maven openjdk-21-jdk \
    # Node / JS
    nodejs npm \
    # For AppImages
    libfuse2 \
    # for SDL (pygame)
    libsdl2-dev libsdl2-image-dev libsdl2-mixer-dev libsdl2-ttf-dev \
    # OpenGL software
    libglvnd0 libgl1 libegl1 libgles2 libglvnd-dev mesa-utils libosmesa6 libgl1-mesa-dri \
    # Headless screen
    xvfb \
    # Image editing (png, svg, webp etc)
    imagemagick librsvg2-bin webp inkscape \
    # Fonts
    fontconfig fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# Install oxipng for optimizing pngs. 
RUN curl -fsSLo /tmp/oxipng.deb https://github.com/oxipng/oxipng/releases/download/v10.1.0/oxipng_10.1.0-1_amd64.deb \
    && echo "62cdfec9711f18bed51de535b4f060fcca46fd1e08cfe8e5ed07a6918b076c5c  /tmp/oxipng.deb" | sha256sum -c - \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/oxipng.deb \
    && rm -f /tmp/oxipng.deb \
    && rm -rf /var/lib/apt/lists/*

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Install gh cli
RUN mkdir -p -m 755 /etc/apt/keyrings \
	&& out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
	&& cat $out | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
	&& chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& mkdir -p -m 755 /etc/apt/sources.list.d \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
	&& apt-get update \
	&& apt-get install -y gh \
	&& rm -rf /var/lib/apt/lists/*

# Install GitLab CLI 
COPY --from=gitlab/glab:latest /usr/bin/glab /usr/local/bin/glab

# Install Codeberg / forgejo
RUN curl -OL https://codeberg.org/forgejo-contrib/forgejo-cli/releases/download/v0.5.0/forgejo-cli-x86_64-linux.tar.gz \
    && tar -C /usr/local/bin -xzf forgejo-cli-x86_64-linux.tar.gz \
    && chmod +x /usr/local/bin/fj \
    && rm forgejo-cli-x86_64-linux.tar.gz 

# Install GO
RUN curl -OL https://golang.org/dl/go1.26.0.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.26.0.linux-amd64.tar.gz && \
    rm go1.26.0.linux-amd64.tar.gz

ENV GOPATH="/home/${USERNAME}/go"
ENV PATH="${GOPATH}/bin:/usr/local/go/bin:${PATH}"


# Install Browser (Lightpanda)
RUN curl -L -o /usr/local/bin/lightpanda \
    https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-x86_64-linux \
    && chmod +x /usr/local/bin/lightpanda


# Switch to non-root user    
USER ${USERNAME}
ENV HOME=/home/${USERNAME}
WORKDIR /home/${USERNAME}

# Make gopath folders as non-root
RUN mkdir -p $GOPATH/bin $GOPATH/src

# Install Python
RUN uv python install --default
ENV PATH="${HOME}/.local/bin:${PATH}"

# Python tools
RUN uv tool install ruff@latest && \
    uv tool install ty@latest

# Love2d
RUN mkdir -p /home/ai/.local/bin \
    && curl -L "https://github.com/love2d/love/releases/download/11.5/love-11.5-x86_64.AppImage" -o /tmp/love.AppImage \
    && chmod +x /tmp/love.AppImage \
    && cd /home/ai/.local/bin \
    && /tmp/love.AppImage --appimage-extract \
    && mv squashfs-root love-11.5 \
    && rm /tmp/love.AppImage \
    && ln -s /home/ai/.local/bin/love-11.5/AppRun /home/ai/.local/bin/love

ENV SHELL=/bin/bash

# Set git user & email
RUN git config --global user.name "$GIT_USER" && \
    git config --global user.email "$GIT_EMAIL" && \
    git config --global init.defaultBranch main

# Install Bun
ENV BUN_INSTALL="${HOME}/.bun"
# .local/bin will be put first anyway from .profile, so can just as well do it here.
ENV PATH="/home/ai/.local/bin:${BUN_INSTALL}/bin:${PATH}"
ENV npm_config_python="/usr/bin/python3"

RUN curl https://bun.sh/install | bash 

# # # Verify installed tools
RUN echo "Installed Versions" \
    && uv python list \
    && uv --version \
    # && dotnet --version \
    && java --version \
    && gh --version \
    && glab --version \
    && fj version \
    && bun --version \
    && node --version \
    && npm --version

RUN mkdir $HOME/ai-workdir


#
# OpenChamber & OpenCode
#
FROM base AS openchamber-agent

RUN bun install -g opencode-ai && bun install -g @openchamber/web

EXPOSE 8126

ENTRYPOINT ["/bin/bash", "-c", "cd $HOME/ai-workdir && openchamber --port 8126 --host 0.0.0.0 && exec openchamber logs --port 8126"]

#
# PicoClaw
#
FROM base AS picoclaw-agent

# Download and extract the binary to user's local bin
RUN curl -L "https://github.com/sipeed/picoclaw/releases/latest/download/picoclaw_Linux_x86_64.tar.gz" -o /tmp/picoclaw.tar.gz \
    && tar -xzf /tmp/picoclaw.tar.gz -C /tmp \
    && mv /tmp/picoclaw /home/ai/.local/bin/picoclaw \
    && chmod +x /home/ai/.local/bin/picoclaw \
    && mv /tmp/picoclaw-launcher /home/ai/.local/bin/picoclaw-launcher \
    && chmod +x /home/ai/.local/bin/picoclaw-launcher \
    && rm /tmp/picoclaw.tar.gz

RUN mkdir $HOME/.picoclaw

EXPOSE 8131
#ENTRYPOINT ["/bin/bash"]
ENTRYPOINT ["/bin/bash", "-c", "picoclaw-launcher -public -port 8131"]

#
# Nanobot
#
FROM base AS nanobot-agent

RUN uv tool install nanobot-ai

EXPOSE 8136

#ENTRYPOINT ["/bin/bash"]
ENTRYPOINT ["/bin/bash", "-c", "nanobot gateway"]

#
# CodeNomad & OpenCode
#
# Folders that are needed:
#   /home/ai/ai-workdir - for code and projects, this is the main workspace    
#   /home/ai/.local/share/opencode - for OpenCode auth persistence, this is needed to keep Copilot login working across container restarts.
#   /home/ai/.config/codenomad - for CodeNomad's own data, such as installed agents and their data. Not strictly needed to persist this, but good to have it outside of the container for easier access and backup.    
#
# OpenCode auth must be completed before CodeNomad is used:
#  - Exec into the container with docker exec -it codenomad-agent bash
#  - Then run `opencode auth login` once and persist ~/.local/share/opencode to keep Copilot login.

FROM base AS codenomad-agent

RUN bun install -g opencode-ai && bun install -g @neuralnomads/codenomad

EXPOSE 8141

ENTRYPOINT ["/bin/bash", "-c", "cd $HOME/ai-workdir && codenomad --http true --http-port 8141 --https false --host 0.0.0.0 --dangerously-skip-auth "]

#
# Hapi & OpenCode
#
# Folders that are needed:
#   /home/ai/ai-workdir - for code and projects, this is the main workspace    
#   /home/ai/.local/share/opencode - for OpenCode auth persistence, this is needed to keep Copilot login working across container restarts.
#   /home/ai/.hapi - for Hapi's own data, such as installed agents and their data. Not strictly needed to persist this, but good to have it outside of the container for easier access and backup.    
#
# OpenCode auth must be completed before hapi is used:
#  - Exec into the container with docker exec -it hapi-agent bash
#  - Then run `opencode auth login` once and persist ~/.local/share/opencode to keep Copilot login.

FROM base AS hapi-agent

RUN bun install -g opencode-ai && bun install -g @twsxtd/hapi

EXPOSE 8146

ENTRYPOINT ["/bin/bash", "-lc", "export HAPI_LISTEN_HOST=0.0.0.0 HAPI_LISTEN_PORT=8146 HAPI_API_URL=http://127.0.0.1:8146; cd \"$HOME/ai-workdir\"; hapi hub & hub_pid=$!; until curl -fsS http://127.0.0.1:8146/health > /dev/null; do if ! kill -0 \"$hub_pid\" 2>/dev/null; then wait \"$hub_pid\"; exit $?; fi; sleep 1; done; hapi runner start --workspace-root /home/ai/ai-workdir ; wait \"$hub_pid\""]

#
# Paseo & Pi & OpenCode
#
FROM base AS paseo-agent
RUN bun install -g @mariozechner/pi-coding-agent && bun install -g opencode-ai && bun install -g @getpaseo/cli

EXPOSE 8151

ENTRYPOINT ["/bin/bash", "-c", "cd $HOME/ai-workdir && paseo start --listen 0.0.0.0:8151 --foreground"]
#ENTRYPOINT ["/bin/bash", "-c", "cd $HOME/ai-workdir && paseo"]

#
# Piclaw
#
FROM base AS piclaw-agent

RUN bun install -g github:rcarmo/piclaw

EXPOSE 8161

ENTRYPOINT ["/bin/bash", "-lc", "export PICLAW_WEB_UI_MODE=visual PICLAW_WORKSPACE=\"$HOME/ai-workdir\" PICLAW_WEB_HOST=0.0.0.0 PICLAW_WEB_PORT=8161; cd \"$HOME/ai-workdir\"; piclaw --host 0.0.0.0 --port 8161"]


