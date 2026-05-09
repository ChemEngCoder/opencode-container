FROM debian:12-slim AS builder-tools

ARG USER_UID=1000
ARG USER_GID=1000
ARG NODE_MAJOR=24
ARG OPENCODE_VERSION=unknown

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --no-install-recommends -y \
    ca-certificates \
    curl \
    gnupg \
    git \
    python3 \
    python3-venv \
    xvfb \
    xclip \
    wl-clipboard \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install --no-install-recommends -y nodejs && \
    rm -rf /var/lib/apt/lists/*

RUN echo "Installing OpenCode (version hint: ${OPENCODE_VERSION})" && \
    curl -fsSL https://opencode.ai/install | bash && \
    install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode

RUN npm install -g @upstash/context7-mcp @modelcontextprotocol/server-sequential-thinking

RUN node --version && \
    npm --version && \
    python3 --version && \
    python3 -m venv /tmp/test-venv && \
    rm -rf /tmp/test-venv && \
    opencode --version

COPY scripts/collect-runtime-deps.sh /usr/local/bin/collect-runtime-deps.sh
RUN chmod 0755 /usr/local/bin/collect-runtime-deps.sh

FROM builder-tools AS collector

ARG USER_UID=1000
ARG USER_GID=1000

RUN mkdir -p /opt/runtime-rootfs && \
    /usr/local/bin/collect-runtime-deps.sh /opt/runtime-rootfs \
      opencode node npm python3 Xvfb xclip wl-copy wl-paste git \
      mkdir find grep cat head tail sed awk \
      ls cp mv rm chmod wc sort cut env date dirname basename

RUN mkdir -p /opt/runtime-rootfs/app/.local/share /opt/runtime-rootfs/app/.config/opencode /opt/runtime-rootfs/app/.cache && \
    chown -R ${USER_UID}:${USER_GID} /opt/runtime-rootfs/app && \
    printf 'opencode:x:%s:%s:OpenCode User:/app:/usr/bin/python3\n' "${USER_UID}" "${USER_GID}" >> /opt/runtime-rootfs/etc/passwd && \
    printf 'opencode:x:%s:\n' "${USER_GID}" >> /opt/runtime-rootfs/etc/group

FROM gcr.io/distroless/base-debian12 AS final

ARG USER_UID=1000
ARG USER_GID=1000

WORKDIR /app

ENV DISPLAY=:99.0
ENV HOME=/app
ENV XDG_CONFIG_HOME=/app/.config
ENV OPENCODE_CONFIG_DIR=/app/.config/opencode
ENV XDG_DATA_HOME=/app/.local/share
ENV PATH=/usr/local/bin:/usr/bin:/bin

COPY --from=collector /opt/runtime-rootfs/ /
COPY --chmod=0755 bootstrap.py /usr/local/bin/bootstrap.py

USER ${USER_UID}:${USER_GID}

ENTRYPOINT ["/usr/bin/python3", "/usr/local/bin/bootstrap.py"]
