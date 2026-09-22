FROM docker.io/lukemathwalker/cargo-chef:latest-rust-trixie AS frontend-builder
WORKDIR /build
RUN rustup target add wasm32-unknown-unknown && \
    curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
# Dummy src to satisfy workspace root member
RUN mkdir -p src && echo "fn main() {}" > src/main.rs
# Dummy xtask to satisfy workspace member list
COPY xtask/Cargo.toml xtask/Cargo.toml
RUN mkdir -p xtask/src && echo "fn main() {}" > xtask/src/main.rs
COPY Cargo.toml Cargo.lock ./
COPY anthropic-wire/ anthropic-wire/
COPY clewdr-types/ clewdr-types/
COPY clewdr-frontend/ clewdr-frontend/
COPY .cargo/ .cargo/
RUN cargo binstall trunk --no-confirm && \
    cd clewdr-frontend && trunk build --release

FROM docker.io/lukemathwalker/cargo-chef:latest-rust-trixie AS chef
WORKDIR /build

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS backend-builder
ARG TARGETARCH
# Zig toolchain versions. Zig provides the musl C/C++ cross toolchain (musl
# headers + libc++) that the vendored BoringSSL in btls-sys needs; the previous
# musl-gcc + host clang++ combo linked the glibc libstdc++, which pulls
# glibc-only symbols (__isoc23_strtoull, __sprintf_chk) that musl lacks, so the
# final static link failed with exit 101. cargo-zigbuild drives cargo build and
# the cmake/cc-rs C++ compiles through Zig.
ARG ZIG_VERSION=0.16.0
ARG CARGO_ZIGBUILD_VERSION=0.23.4

# Install build dependencies. build-essential provides the host cc/linker for
# proc-macros and build scripts (which run on the build host); clang/libclang
# are for bindgen; cmake/perl build BoringSSL; python3 hosts the pinned Zig.
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    clang \
    libclang-dev \
    perl \
    pkg-config \
    python3 \
    python3-pip \
    upx-ucl \
    && rm -rf /var/lib/apt/lists/*

# Zig (pinned) as the musl C/C++ toolchain, plus cargo-zigbuild to wire it into
# cargo, cmake and cc-rs. `zig` on PATH is what cargo-zigbuild looks for.
RUN pip3 install --break-system-packages --no-cache-dir "ziglang==${ZIG_VERSION}" \
    && printf '#!/bin/sh\nexec python3 -m ziglang "$@"\n' > /usr/local/bin/zig \
    && chmod +x /usr/local/bin/zig \
    && zig version \
    && cargo install cargo-zigbuild --locked --version "${CARGO_ZIGBUILD_VERSION}"

# btls-sys picks the C++ runtime lib by target: for musl it defaults to
# `stdc++` (no musl build exists), so pin it to `c++`, which Zig supplies.
ENV BORING_BSSL_RUST_CPPLIB=c++

# Determine musl target from Docker platform
RUN case "$TARGETARCH" in \
    amd64) echo "x86_64-unknown-linux-musl" > /tmp/rust-target ;; \
    arm64) echo "aarch64-unknown-linux-musl" > /tmp/rust-target ;; \
    *) echo "Unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac && \
    rustup target add "$(cat /tmp/rust-target)"

COPY --from=planner /build/recipe.json recipe.json

# Build dependencies - this is the caching Docker layer.
RUN RUST_TARGET=$(cat /tmp/rust-target) && \
    cargo chef cook --release --zigbuild --target "$RUST_TARGET" \
    --no-default-features --features embed-resource,xdg \
    --recipe-path recipe.json

# Build application
COPY . .
COPY --from=frontend-builder /build/static/ ./static
RUN RUST_TARGET=$(cat /tmp/rust-target) && \
    cargo zigbuild --release --target "$RUST_TARGET" \
    --no-default-features --features embed-resource,xdg --bin clewdr \
    && cp ./target/"$RUST_TARGET"/release/clewdr /build/clewdr \
    && upx --best --lzma /build/clewdr \
    && mkdir -p /etc/clewdr/log \
    && touch /etc/clewdr/clewdr.toml

FROM gcr.io/distroless/static-debian13
COPY --from=backend-builder /build/clewdr /usr/local/bin/clewdr
COPY --from=backend-builder /etc/clewdr /etc/clewdr
ENV CLEWDR_IP=0.0.0.0
ENV CLEWDR_PORT=8484
ENV CLEWDR_CHECK_UPDATE=FALSE
ENV CLEWDR_AUTO_UPDATE=FALSE
EXPOSE 8484
CMD ["/usr/local/bin/clewdr", "--config", "/etc/clewdr/clewdr.toml", "--log-dir", "/etc/clewdr/log"]
