FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

# Keep bootstrap tools in a stable layer. Application source is never copied
# into this image, so ordinary source changes reuse all toolchain layers.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

# Keep the MoonBit toolchain below only stable operating-system layers. A
# Dockerfile change after this instruction does not download it again.
RUN curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash

# Native builds use the MoonBit backend plus a C compiler/linker driver.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.moon/bin:${PATH}"

# Registry metadata lives under the container user's Moon cache.  Preload it
# into the toolchain image so each short-lived `docker run` can resolve the
# dependencies already declared by the bind-mounted workspace.
RUN moon update

WORKDIR /workspace

ENTRYPOINT ["moon"]
