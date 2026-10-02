#!/usr/bin/env bash
#
# Entrypoint for the integration test domain controller: provisions a throwaway Samba Active
# Directory domain on first start, then runs samba in the foreground.
#
# The container runs without extra privileges. Samba normally stores NT ACLs in security.*
# extended attributes, which need CAP_SYS_ADMIN, so the xattr_tdb VFS module keeps them in a
# TDB file instead. This is fine for a test domain and not how a production DC should be set up.

set -euo pipefail

: "${SAMBA_REALM:=CORP.ITOPS.TEST}"
: "${SAMBA_DOMAIN:=CORP}"
: "${SAMBA_ADMIN_PASSWORD:?Set SAMBA_ADMIN_PASSWORD (tests/integration/run.sh generates one per run).}"

if [[ ! -f /var/lib/samba/private/sam.ldb ]]; then
    echo "Provisioning test domain $SAMBA_REALM"
    rm -f /etc/samba/smb.conf
    samba-tool domain provision \
        --realm="$SAMBA_REALM" \
        --domain="$SAMBA_DOMAIN" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass="$SAMBA_ADMIN_PASSWORD" \
        --option='dns forwarder = 127.0.0.11' \
        --option='vfs objects = dfs_samba4 acl_xattr xattr_tdb' \
        --option='xattr_tdb:file = /var/lib/samba/xattr.tdb' \
        >/var/log/samba-provision.log
    echo "Provisioned $SAMBA_REALM"
fi

exec samba --foreground --no-process-group --debug-stdout
