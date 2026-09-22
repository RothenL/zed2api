# syntax=docker/dockerfile:1.7
# ── Stage 1: build the WebUI (Node) ──────────────────────────────────────────
FROM node:22-bookworm-slim AS webui

WORKDIR /build/webui
# Install deps first for better layer caching. Fall back to npm install if there's no lockfile.
COPY webui/package.json webui/package-lock.json* ./
RUN npm ci || npm install

COPY webui/ ./
# Produces a single inlined index.html under dist/.
RUN npm run build

# ── Stage 2: build the Zig server ────────────────────────────────────────────
FROM debian:bookworm-slim AS zig-builder

ARG ZIG_VERSION=0.15.1
ARG ZIG_HOST=x86_64-linux
ARG TARGET=x86_64-linux

# Minimal build toolchain: curl to fetch Zig, xz to extract, libc headers.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils \
      libc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Install Zig (pinned version, deterministic URL).
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_HOST}-${ZIG_VERSION}.tar.xz" \
      -o /tmp/zig.tar.xz \
    && tar -xf /tmp/zig.tar.xz -C /opt \
    && ln -s "/opt/zig-${ZIG_HOST}-${ZIG_VERSION}/zig" /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz \
    && zig version

# Copy sources and the pre-built WebUI HTML.
COPY build.zig build.zig.zon ./
COPY src/ ./src/
COPY --from=webui /build/webui/dist/index.html ./webui/dist/index.html

# Pass -Dwebui=false: the HTML was built in the previous stage and Node isn't
# installed here, so skip build.zig's tsc/vite steps and embed the existing file.
RUN zig build -Dwebui=false -Doptimize=ReleaseSafe -Dtarget=${TARGET} \
 && ls -la zig-out/bin/

# ── Stage 3: runtime image ───────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

# Runtime deps:
#   - ca-certificates : TLS verification for cloud.zed.dev
#   - curl            : used by the proxy path (HTTPS_PROXY) and the healthcheck
#   - tzdata          : correct timestamps in logs
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl tzdata \
    && rm -rf /var/lib/apt/lists/*

# Non-root user; the binary writes accounts.json and temp files to its working dir.
RUN useradd --system --create-home --uid 10001 --shell /usr/sbin/nologin zed2api

# Binary in /app; runtime data (accounts.json, temp files) in /data, which is the
# process working directory and the volume you mount.
RUN mkdir -p /app /data && chown -R zed2api:zed2api /app /data

COPY --from=zig-builder /build/zig-out/bin/zed2api /app/zed2api

USER zed2api

# The server reads accounts.json and writes temp files relative to its cwd, so run
# it from /data. HOST=0.0.0.0 is required inside a container (traffic arrives on a
# non-loopback interface); Docker port mapping controls external exposure.
ENV HOST=0.0.0.0
ENV PORT=8000

WORKDIR /data
VOLUME /data

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/v1/models" >/dev/null || exit 1

CMD ["sh", "-c", "/app/zed2api serve ${PORT}"]
