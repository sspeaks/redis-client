# Sandbox for factory agents. Build context: scripts/factory/container.
FROM nixos/nix:2.28.3@sha256:e623d73af9cac82d1b50784c83e0cf2a4b83bfd2cfe8d5b67809a2fc94e043ac AS nix

FROM debian:bookworm-slim@sha256:e67eeead736ff7bbe258ef088bff683635c561b1fcfefad0806c1df4ab49ce0e

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git openssl python3 xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Claude Code as published, checked against the integrity value npm records for it.
ARG CLAUDE_VERSION=2.1.325
ARG TARGETARCH
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) arch=x64; integrity=BqZzMvP/zgLLL34S+7OzbG+cyoFp7gwWHU5koVwsyMlTAz+0zZAmbY+UkzvtN2RXxp6AcMenbYIjQJxoXfUY3w== ;; \
      arm64) arch=arm64; integrity=NCvQcOxr685Y4mkYUjQT8l/Ouzw0k2xWloWeyzfsUtWiOedHosPkaW6XCSpzAl1dMuvDNBF97qpWgVDrSdK2Vw== ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/claude.tgz "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-$arch/-/claude-code-linux-$arch-$CLAUDE_VERSION.tgz"; \
    test "$(openssl dgst -sha512 -binary /tmp/claude.tgz | base64 -w0)" = "$integrity"; \
    tar -xzf /tmp/claude.tgz -C /tmp package/claude; \
    install -m 0755 /tmp/package/claude /usr/local/bin/claude; \
    rm -rf /tmp/claude.tgz /tmp/package

# The agent shares the runner's user ID so that it can write the mounted workspace.
ARG AGENT_UID=1001
RUN useradd --uid "$AGENT_UID" --create-home --shell /bin/bash agent
COPY --from=nix --chown=agent /nix /nix

# nixpkgs is the revision of nixos-25.05 that CI resolves. It comes straight from
# codeload because github.com, which also accepts writes, is not reachable.
ENV PATH=/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin \
    NIX_PATH=nixpkgs=https://codeload.github.com/NixOS/nixpkgs/tar.gz/ac62194c3917d5f474c1a844b6fd6da2db95077d \
    NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    NIX_CONFIG="sandbox = false" \
    HOME=/home/agent \
    USER=agent

COPY entrypoint.py probe.py /opt/factory/
USER agent
# HTTPS, because the egress proxy only opens TLS tunnels.
RUN mkdir -p ~/.cabal && printf '%s\n' \
    'repository hackage.haskell.org' \
    '  url: https://hackage.haskell.org/' \
    '  secure: True' \
    'http-transport: curl' > ~/.cabal/config
WORKDIR /workspace
ENTRYPOINT ["python3", "/opt/factory/entrypoint.py"]
