FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash

RUN apt-get update \
    && apt-get install --yes --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.moon/bin:${PATH}"

WORKDIR /workspace

ENTRYPOINT ["moon"]
