# Images for testing the Bash toolkit.
#
#   tools  Debian 13 with every command the scripts use: the Samba client tools (samba-tool,
#          ldbsearch, smbclient), jq, python3, openssl and the usual network and system tools.
#          samba-dsdb-modules gives the ldb tools Samba's -A (authentication file) option.
#   test   tools + bats-core and its helper libraries, pinned by tag and SHA-256 checksum.
#          Runs the bats unit tests and the integration tests (as the "client").
#   dc     tools + a Samba Active Directory domain controller that provisions a throwaway
#          domain on first start. Used only by the integration tests.
#
# Build context: the repository root.

FROM debian:trixie-slim AS tools
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bsdextrautils \
        ca-certificates \
        curl \
        iproute2 \
        iputils-ping \
        iputils-tracepath \
        jq \
        ldb-tools \
        openssl \
        procps \
        python3 \
        python3-samba \
        samba-dsdb-modules \
        smbclient \
        traceroute \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

FROM tools AS test
ARG BATS_CORE_VERSION=1.14.0
ARG BATS_CORE_SHA256=bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177
ARG BATS_SUPPORT_VERSION=0.3.0
ARG BATS_SUPPORT_SHA256=7815237aafeb42ddcc1b8c698fc5808026d33317d8701d5ec2396e9634e2918f
ARG BATS_ASSERT_VERSION=2.2.4
ARG BATS_ASSERT_SHA256=e305df20c4c36cba4570e10f1cd824efb1ae71d88b5ef474550781ebee04192f
RUN set -eu; \
    fetch() { \
        curl -fsSL -o "/tmp/$1.tar.gz" "https://github.com/bats-core/$1/archive/refs/tags/v$2.tar.gz"; \
        echo "$3  /tmp/$1.tar.gz" | sha256sum -c -; \
        mkdir -p "/tmp/$1"; \
        tar -xzf "/tmp/$1.tar.gz" -C "/tmp/$1" --strip-components 1; \
    }; \
    fetch bats-core "$BATS_CORE_VERSION" "$BATS_CORE_SHA256"; \
    fetch bats-support "$BATS_SUPPORT_VERSION" "$BATS_SUPPORT_SHA256"; \
    fetch bats-assert "$BATS_ASSERT_VERSION" "$BATS_ASSERT_SHA256"; \
    /tmp/bats-core/install.sh /usr/local; \
    mkdir -p /usr/local/lib/bats; \
    mv /tmp/bats-support /tmp/bats-assert /usr/local/lib/bats/; \
    rm -rf /tmp/bats-core /tmp/*.tar.gz
ENV BATS_LIB_PATH=/usr/local/lib/bats
WORKDIR /work
ENTRYPOINT ["bats"]

FROM tools AS dc
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends samba samba-ad-dc samba-ad-provision \
    && rm -rf /var/lib/apt/lists/* /etc/samba/smb.conf
COPY tests/integration/samba-dc-entrypoint.sh /usr/local/sbin/samba-dc-entrypoint
ENTRYPOINT ["/usr/local/sbin/samba-dc-entrypoint"]
