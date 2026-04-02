FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    gawk wget git diffstat unzip texinfo gcc build-essential chrpath \
    socat cpio python3 python3-pip python3-pexpect xz-utils debianutils \
    iputils-ping python3-git python3-jinja2 libegl1-mesa libsdl1.2-dev \
    pylint3 xterm python3-subunit mesa-common-dev zstd liblz4-tool \
    locales file python \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Install Google Cloud SDK for gsutil (sstate cache sync to GCS)
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - \
    && apt-get update && apt-get install -y google-cloud-sdk \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1000 builder \
    && useradd -u 1000 -g 1000 -m -s /bin/bash builder

RUN su - builder -c 'git config --global user.email "builder@plaid.local"' \
    && su - builder -c 'git config --global user.name "PLAID Builder"'

RUN curl -fsSL "https://github.com/tianon/gosu/releases/download/1.16/gosu-amd64" -o /usr/local/bin/gosu \
    && chmod +x /usr/local/bin/gosu \
    && gosu --version

RUN mkdir -p /build && chown builder:builder /build

COPY entrypoint.sh /build/entrypoint.sh
RUN chmod +x /build/entrypoint.sh

WORKDIR /build
ENTRYPOINT ["/build/entrypoint.sh"]
