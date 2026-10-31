FROM ubuntu@sha256:0e73b71479e7bc5f006bca872e25c3cd680dc052a0116f90d63ae363537db0dd

ENV DEBIAN_FRONTEND=noninteractive

ARG UBUNTU_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu

RUN set -eu; \
    for attempt in 1 2 3 4 5; do \
        apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=60 update && break; \
        [ "$attempt" -lt 5 ] || exit 1; sleep 3; \
    done; \
    for attempt in 1 2 3 4 5; do \
        apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=60 install -y --no-install-recommends \
            ca-certificates=20260816ubuntu0.26.04.1 && break; \
        [ "$attempt" -lt 5 ] || exit 1; sleep 3; \
    done; \
    rm -rf /var/lib/apt/lists/*

RUN sed -i \
        -e "s|http://archive.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g" \
        -e "s|http://security.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g" \
        /etc/apt/sources.list.d/ubuntu.sources

RUN apt-get -o Acquire::Retries=5 -o Acquire::https::Timeout=60 update \
    && apt-get -o Acquire::Retries=5 -o Acquire::https::Timeout=60 install -y --no-install-recommends \
        android-sdk-libsparse-utils=1:34.0.5-12build1 \
        mkbootimg=1:34.0.5-12build1 \
        cmake=4.2.3-2ubuntu2 \
        cpio=2.15+dfsg-2.1ubuntu0.1 \
        curl=8.18.0-1ubuntu2.8 \
        e2fsprogs=1.47.2-3ubuntu4 \
        file=1:5.46-5build2 \
        git=1:2.53.0-1ubuntu1.1 \
        gzip=1.14-1~exp2ubuntu1.1 \
        jq=1.8.1-4ubuntu2 \
        kmod=34.2-2ubuntu2 \
        locales=2.43-2ubuntu2.4 \
        openssh-client=1:10.2p1-2ubuntu3.8 \
        proot=5.4.0-3 \
        python3=3.14.3-0ubuntu2 \
        qemu-user-binfmt=1:10.2.1+ds-1ubuntu3.3 \
        rsync=3.4.1+ds1-7ubuntu0.3 \
        shellcheck=0.11.0-2 \
        tar=1.35+dfsg-4ubuntu0.4 \
        xz-utils=5.8.3-1ubuntu0.1 \
        zip=3.0-15ubuntu3 \
        zstd=1.5.7+dfsg-3 \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get -o Acquire::Retries=5 -o Acquire::https::Timeout=60 update \
    && apt-get -o Acquire::Retries=5 -o Acquire::https::Timeout=60 install -y --no-install-recommends device-tree-compiler=1.7.2-2ubuntu1 \
    && rm -rf /var/lib/apt/lists/*

ARG EXPORT_PACKAGE_LOCK=0
COPY config/builder-packages.lock.tsv /tmp/builder-packages.lock.tsv
RUN dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' \
        | LC_ALL=C sort > /tmp/builder-packages.actual.tsv \
    && (test "$EXPORT_PACKAGE_LOCK" = 1 || cmp /tmp/builder-packages.lock.tsv /tmp/builder-packages.actual.tsv) \
    && rm -f /tmp/builder-packages.lock.tsv /tmp/builder-packages.actual.tsv

WORKDIR /workspace/oneplus6-image
ENTRYPOINT ["bash", "scripts/build.sh"]
