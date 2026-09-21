# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/devcontainers/dotnet:2.0.5-10.0-noble

ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive
ARG AWS_CLI_VERSION="2.32.9"

# Switch to root for configuring image
USER root

# Add new Yarn GPG key
RUN mkdir -p /etc/apt/keyrings && \
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor -o /etc/apt/keyrings/yarn.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/yarn.gpg] https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list

# Custom Cert Support
COPY ./certs /usr/local/share/ca-certificates/custom/
RUN find /usr/local/share/ca-certificates/custom -type f ! -name '*.crt' -delete \
    && if find /usr/local/share/ca-certificates/custom -type f -name '*.crt' -print -quit | grep -q .; then \
    update-ca-certificates; \
    fi

ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt

# Install man pages and additional packages
# Use a docker cache mount to increase rebuild speed
# unminimize only runs apt-get update in its restore-documentation branch, so update explicitly or
# the cache-mounted index goes stale and installs 404. Again after, since unminimize is slow enough
# for the archive to rotate underneath it.
RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    yes | unminimize && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    php \
    php-cli \
    # php-xml supplies SimpleXML, without which phpcs cannot parse the Moodle ruleset;
    # php-curl and php-zip are what composer needs to fetch and unpack packages
    php-xml \
    php-curl \
    php-zip \
    php-mbstring \
    # includes certutil for dev cert verification
    libnss3-tools \
    # Playwright system dependencies (headless Chromium, English-only)
    libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
    libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 \
    libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 \
    libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 \
    libfontconfig1 libfreetype6 fonts-liberation fonts-freefont-ttf

# Install Composer, used to install the Moodle coding standard in postcreate.sh
# The release phar can be checksum-pinned; getcomposer.org/installer cannot. It is architecture
# independent, so no TARGETARCH case. Bump both ARGs together or sha256sum -c fails the build.
ARG COMPOSER_VERSION=2.10.3
ARG COMPOSER_SHA256=7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6
RUN set -eux; \
    curl -fsSL -o /tmp/composer.phar \
    "https://github.com/composer/composer/releases/download/${COMPOSER_VERSION}/composer.phar"; \
    echo "${COMPOSER_SHA256}  /tmp/composer.phar" | sha256sum -c -; \
    install -m 0755 /tmp/composer.phar /usr/local/bin/composer; \
    rm /tmp/composer.phar; \
    composer --version

# Install Vale
ARG VALE_VERSION=3.12.0
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64)  VALE_ARCH="64-bit" ;; \
    arm64)  VALE_ARCH="arm64" ;; \
    *)      echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/vale.tgz \
    "https://github.com/errata-ai/vale/releases/download/v${VALE_VERSION}/vale_${VALE_VERSION}_Linux_${VALE_ARCH}.tar.gz" \
    && tar -xzf /tmp/vale.tgz -C /usr/local/bin vale \
    && rm /tmp/vale.tgz \
    && chmod +x /usr/local/bin/vale \
    && vale --version

# Install OMP
ARG OMP_VERSION=18.2.7
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) OMP_ARCH="x64"; OMP_SHA256="1c28ed66566ecabab814514cfe626b4aff5981b7ca9892477b46550fe6b6d83b" ;; \
    arm64) OMP_ARCH="arm64"; OMP_SHA256="dee01159c63577eafe1e9396b1687462352063ec1b62203177946fc5d5acff1a" ;; \
    *)     echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/omp \
    "https://github.com/can1357/oh-my-pi/releases/download/v${OMP_VERSION}/omp-linux-${OMP_ARCH}"; \
    echo "${OMP_SHA256}  /tmp/omp" | sha256sum -c -; \
    install -m 0755 /tmp/omp /usr/local/bin/omp; \
    rm /tmp/omp; \
    omp --version

# Install Herdr
ARG HERDR_VERSION=0.9.1
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) HERDR_ARCH="x86_64"; HERDR_SHA256="2a02fed16beb651ef006e1d43f048f652ca4dc58ad053cd2d44450563d5c54b7" ;; \
    arm64) HERDR_ARCH="aarch64"; HERDR_SHA256="f4ccf4de745f2cb9a39a983e9ba3703dad50ec2a58dea83026ceab721bbd8d9e" ;; \
    *)     echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/herdr \
    "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${HERDR_ARCH}"; \
    echo "${HERDR_SHA256}  /tmp/herdr" | sha256sum -c -; \
    install -m 0755 /tmp/herdr /usr/local/bin/herdr; \
    rm /tmp/herdr; \
    herdr --version

# Install t3code (t3) — runs the local server that the t3client on a developer's own
# machine pairs with directly over the forwarded port (no cloud relay, no account login).
# It ships as a Node bundle (launcher + bundled node_modules), so extract the whole
# directory and symlink the launcher onto PATH. The launcher needs Node, which the Node
# devcontainer feature installs after this build finishes, so the runnable version check
# lives in CI (ci-verify-tools.sh); here we only confirm the launcher was extracted.
ARG T3CODE_VERSION=0.0.42
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) T3_ARCH="x64";   T3_SHA256="f504e931ee4406bfe76754147cb0e2a0f300d75c6c505a0e174a1e79f65ceea3" ;; \
    arm64) T3_ARCH="arm64"; T3_SHA256="7de47e66793c91b01ee3fb304d9d2dc9a7019aaa8f85c55b535d6d8ca3e14013" ;; \
    *)     echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/t3.tar.gz \
    "https://github.com/pingdotgg/t3code/releases/download/v${T3CODE_VERSION}/t3-${T3CODE_VERSION}-linux-${T3_ARCH}.tar.gz"; \
    echo "${T3_SHA256}  /tmp/t3.tar.gz" | sha256sum -c -; \
    install -d /opt/t3; \
    tar -xzf /tmp/t3.tar.gz -C /opt/t3; \
    ln -sf "/opt/t3/t3-${T3CODE_VERSION}-linux-${T3_ARCH}/t3" /usr/local/bin/t3; \
    rm /tmp/t3.tar.gz; \
    test -x "/opt/t3/t3-${T3CODE_VERSION}-linux-${T3_ARCH}/t3"

# Prepare persistent agent state directories before Docker initializes named volumes
RUN install -d -o vscode -g vscode /home/vscode/.omp /home/vscode/.config/herdr /home/vscode/.t3

# Install AWS CLI with Session Manager Plugin
RUN case "${TARGETARCH}" in \
    amd64)  AWSCLI_PKG="awscli-exe-linux-x86_64-${AWS_CLI_VERSION}.zip" \
    SSM_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" ;; \
    arm64)  AWSCLI_PKG="awscli-exe-linux-aarch64-${AWS_CLI_VERSION}.zip" \
    SSM_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb" ;; \
    *)      echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl "https://awscli.amazonaws.com/${AWSCLI_PKG}" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install --update && \
    curl "${SSM_URL}" -o /tmp/session-manager-plugin.deb && \
    dpkg -i /tmp/session-manager-plugin.deb && \
    rm -rf /tmp/awscliv2.zip /tmp/aws /tmp/session-manager-plugin.deb

# Configure AWS CLI bash completion
RUN echo '' >> /home/vscode/.bashrc && \
    echo '# AWS CLI completion' >> /home/vscode/.bashrc && \
    echo 'bind "set show-all-if-ambiguous on"' >> /home/vscode/.bashrc && \
    echo 'complete -C /usr/local/bin/aws_completer aws' >> /home/vscode/.bashrc

# Configure AWS CLI zsh completion (using bashcompinit for AWS CLI v2 compatibility)
RUN echo '' >> /home/vscode/.zshrc && \
    echo '# AWS CLI completion' >> /home/vscode/.zshrc && \
    echo 'autoload -Uz bashcompinit && bashcompinit' >> /home/vscode/.zshrc && \
    echo 'complete -C /usr/local/bin/aws_completer aws' >> /home/vscode/.zshrc

# Codex system config is bind-mounted into this directory at container runtime.
RUN mkdir -p /etc/codex

# Install kubefwd
ARG KUBEFWD_VERSION=1.25.14
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64)  KUBEFWD_ARCH="x86_64" ;; \
    arm64)  KUBEFWD_ARCH="arm64"  ;; \
    *)      echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/kubefwd.tgz \
    "https://github.com/txn2/kubefwd/releases/download/v${KUBEFWD_VERSION}/kubefwd_Linux_${KUBEFWD_ARCH}.tar.gz" \
    && tar -xzf /tmp/kubefwd.tgz -C /usr/local/bin kubefwd \
    && rm /tmp/kubefwd.tgz \
    && chmod +x /usr/local/bin/kubefwd \
    && kubefwd version

# Configure ZSH History
RUN mkdir -p "/home/vscode/.history" && touch "/home/vscode/.history/zsh_history" && \
    chown -R vscode:vscode /home/vscode/.history && \
    cat >> /home/vscode/.zshrc <<'EOF'
# Persistent zsh history for devcontainer
# Use a dedicated history directory (backed by a Docker volume)
mkdir -p "/home/vscode/.history"
export HISTFILE="/home/vscode/.history/zsh_history"
export HISTSIZE=50000      # in-memory commands
export SAVEHIST=100000     # on-disk commands
# History behavior options
setopt APPEND_HISTORY          # append to history file, don't overwrite
setopt INC_APPEND_HISTORY      # write each command as it's entered
setopt SHARE_HISTORY           # share history across sessions
setopt HIST_IGNORE_DUPS        # ignore immediate duplicates
setopt HIST_IGNORE_ALL_DUPS    # drop older duplicates
setopt HIST_IGNORE_SPACE       # ignore commands starting with a space
setopt HIST_REDUCE_BLANKS      # trim extra spaces
setopt HIST_VERIFY             # don't immediately execute recalled commands
# DEVCONTAINER ZSH HISTORY END
EOF

# Export GitHub token from gh CLI for MCP server auth
RUN echo '' >> /home/vscode/.zshrc && \
    echo '# GitHub MCP token from gh CLI' >> /home/vscode/.zshrc && \
    echo 'export GITHUB_PERSONAL_ACCESS_TOKEN=$(gh auth token 2>/dev/null)' >> /home/vscode/.zshrc
