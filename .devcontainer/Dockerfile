FROM swift:6.3.3-noble

RUN apt-get update && apt-get install -y --no-install-recommends \
        make \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN if ! id -u vscode >/dev/null 2>&1; then \
        useradd --create-home --shell /bin/bash vscode; \
    fi

USER vscode
WORKDIR /workspace
