# Fixture for test.sh: the Dockerfile shapes tools.json anchors into, and nothing else.
FROM mcr.microsoft.com/devcontainers/dotnet:2.0.5-10.0-noble

ARG TARGETARCH
ARG AWS_CLI_VERSION="2.32.9"

ARG COMPOSER_VERSION=2.10.3
ARG COMPOSER_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
RUN echo composer

ARG OMP_VERSION=18.2.7
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) OMP_ARCH="x64"; OMP_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;; \
    arm64) OMP_ARCH="arm64"; OMP_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;; \
    *)     echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    echo omp

ARG VALE_VERSION=3.12.0
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64)  VALE_ARCH="64-bit" ;; \
    arm64)  VALE_ARCH="arm64" ;; \
    esac
