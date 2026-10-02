# Images for testing the Bash toolkit.
#
#   tools  Debian 13 with every command the scripts use: the Samba client tools (samba-tool,
#          ldbsearch, smbclient), jq, python3, openssl and the usual network and system tools.
#          samba-dsdb-modules gives the ldb tools Samba's -A (authentication file) option.
#   test   tools + bats-core and its helper libraries, pinned by tag and SHA-256 checksum.
#          Runs the bats unit tests and the integration tests (as the "client").
#   dc     tools + a Samba Active Directory domain controller that provisions a throwaway
#          domain on first start. Used only by the integration tests.
#   powershell
#          Ubuntu 24.04 with PowerShell 7.6 LTS from Microsoft's .deb package, pinned by version
#          and SHA-256, and openssl for the delivery-file interoperability test. Runs
#          PSScriptAnalyzer and the Pester suite (scripts/test-powershell.sh), and records
#          the Linux Test-ItoNetwork sample (scripts/make-samples.sh). It replaces
#          mcr.microsoft.com/powershell:7.5-ubuntu-24.04, which in September 2026 still held
#          PowerShell 7.5.0 from January 2025; that registry has no 7.6 tag.
#
# Build context: the repository root.
#
# The base images are pinned by digest (Dependabot updates them). The apt packages come from
# Debian 13 and Ubuntu 24.04 at build time; tests/integration/run.sh prints the Samba version each
# run tested, and scripts/Invoke-Tests.ps1 prints the PowerShell version.

FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS tools
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

FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3 AS powershell
ARG DEBIAN_FRONTEND=noninteractive
ARG POWERSHELL_VERSION=7.6.6
ARG POWERSHELL_SHA256=9585f38ab5a026c3fc0995486e26e12050777960fef47a22dca98b577c5d27a7
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl locales openssl; \
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen; \
    curl -fsSL -o /tmp/powershell.deb \
        "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell_${POWERSHELL_VERSION}-1.deb_amd64.deb"; \
    echo "${POWERSHELL_SHA256}  /tmp/powershell.deb" | sha256sum -c -; \
    apt-get install -y --no-install-recommends /tmp/powershell.deb; \
    apt-get purge -y --auto-remove curl; \
    rm -rf /tmp/powershell.deb /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 POWERSHELL_TELEMETRY_OPTOUT=1
WORKDIR /work
ENTRYPOINT ["pwsh", "-NoProfile"]
