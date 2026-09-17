# The base toolchain is selectable so the pinned image can track the current
# Swift lane and the next qualified lane without a second Dockerfile.
#   docker build --build-arg SWIFT_VERSION=6.4 -f .devcontainer/Dockerfile .
ARG SWIFT_VERSION=6.3.3
FROM swift:${SWIFT_VERSION}-noble

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        make \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN if ! id -u vscode >/dev/null 2>&1; then \
        useradd --create-home --shell /bin/bash vscode; \
    fi

USER vscode
WORKDIR /workspace
