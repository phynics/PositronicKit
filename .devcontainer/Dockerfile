FROM swift:6.3.2-noble

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libssl-dev \
        curl \
        perl \
        libdigest-sha-perl \
        git \
    && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME="/usr/local/rustup" \
    PATH="/usr/local/cargo/bin:${PATH}"

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | CARGO_HOME=/usr/local/cargo sh -s -- -y --default-toolchain stable --profile minimal

RUN chmod -R a+rX /usr/local/rustup /usr/local/cargo

RUN if ! id -u vscode >/dev/null 2>&1; then \
        useradd --create-home --shell /bin/bash vscode; \
    fi

USER vscode
WORKDIR /workspace
