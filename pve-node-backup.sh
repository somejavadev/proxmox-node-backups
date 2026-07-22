#!/usr/bin/env bash
#
# pve-node-backup.sh
#
# Backs up the essential, node-specific configuration of a Proxmox VE host
# that is a member of a cluster, using proxmox-backup-client.
#
# This does NOT back up VMs/CTs (use vzdump / PBS VM backups for that) and
# does NOT do a full disk image. It captures:
#   - /etc/pve (clustered config - already replicated, but nice to snapshot)
#   - Node-specific files that only exist on this host (network, ssh, corosync,
#     apt sources, cron, installed-package list, etc.)
#
# Requires: proxmox-backup-client installed and network access to a PBS server.
#
# ---------------------------------------------------------------------------
set -euo pipefail

### ------------------------- CONFIGURATION --------------------------------
# You can also export these as environment variables before running the
# script instead of editing here (PBS_REPOSITORY / PBS_PASSWORD /
# PBS_FINGERPRINT are recognized natively by proxmox-backup-client).

PBS_REPOSITORY="${PBS_REPOSITORY:-user@pbs@pbs.example.com:datastore-name}"
# PBS_PASSWORD can be set here, but it's more secure to export it in the
# calling environment or use an API token instead:
#   export PBS_PASSWORD="....."
# Or, preferred: use an API token
#   export PBS_REPOSITORY="user@pbs!tokenname@pbs.example.com:datastore-name"
#   export PBS_PASSWORD="the-token-secret"

BACKUP_ID="$(hostname -s)"          # shows up as the "backup ID" in PBS
NAMESPACE="${NAMESPACE:-}"          # e.g. "cluster1/nodes" - leave empty for root ns
BACKUP_TYPE="host"                  # PBS backup-type for this kind of backup
STAGING_DIR="/var/tmp/pve-node-backup-staging"
LOG_TAG="pve-node-backup"

### --------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/${LOG_TAG}.log
}

die() {
    log "ERROR: $*"
    exit 1
}

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root (needs to read /etc/ssh, /etc/corosync, etc.)"
    fi
}

check_prereqs() {
    command -v proxmox-backup-client >/dev/null 2>&1 \
        || die "proxmox-backup-client not found. Install with: apt install proxmox-backup-client"

    if [[ -z "${PBS_PASSWORD:-}" ]]; then
        die "PBS_PASSWORD is not set. Export it (or an API token secret) before running."
    fi

    if [[ "$PBS_REPOSITORY" == *example.com* ]]; then
        die "PBS_REPOSITORY still points at the placeholder value - edit the script or export PBS_REPOSITORY."
    fi
}

# Copy a path into the staging dir, preserving its absolute path structure.
# Silently skips paths that don't exist (e.g. optional cron dirs).
stage() {
    local src="$1"
    if [[ -e "$src" ]]; then
        mkdir -p "${STAGING_DIR}$(dirname "$src")"
        cp -a "$src" "${STAGING_DIR}$(dirname "$src")/"
    fi
}

build_staging_area() {
    log "Building staging area at $STAGING_DIR"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"

    # --- Networking ---
    stage /etc/network/interfaces
    stage /etc/network/interfaces.d
    stage /etc/hosts
    stage /etc/hostname
    stage /etc/resolv.conf

    # --- SSH host identity ---
    stage /etc/ssh

    # --- Cluster membership / quorum config ---
    # (also present under /etc/pve/corosync.conf, but the local copy is
    #  what corosync actually reads at boot)
    stage /etc/corosync

    # --- Package sources & selections ---
    stage /etc/apt/sources.list
    stage /etc/apt/sources.list.d
    stage /etc/apt/trusted.gpg.d

    # --- Cron ---
    stage /etc/cron.d
    stage /etc/cron.daily
    stage /etc/cron.hourly
    stage /etc/cron.weekly
    stage /var/spool/cron/crontabs

    # --- Misc node identity / firewall / kernel tuning ---
    stage /etc/pve-firewall.cfg   # legacy path on some setups
    stage /etc/sysctl.conf
    stage /etc/sysctl.d
    stage /etc/modprobe.d
    stage /etc/fstab
    stage /etc/timezone
    stage /etc/localtime

    # --- Dynamic system info, useful for a bare-metal rebuild ---
    mkdir -p "${STAGING_DIR}/system-info"
    {
        echo "# Generated $(date)"
        echo "# Installed packages (dpkg selections)"
        dpkg --get-selections
    } > "${STAGING_DIR}/system-info/dpkg-selections.txt" 2>/dev/null || true

    pvecm status > "${STAGING_DIR}/system-info/pvecm-status.txt" 2>/dev/null || true
    pvecm nodes  > "${STAGING_DIR}/system-info/pvecm-nodes.txt" 2>/dev/null || true
    ip a         > "${STAGING_DIR}/system-info/ip-addr.txt" 2>/dev/null || true
    ip r         > "${STAGING_DIR}/system-info/ip-route.txt" 2>/dev/null || true
    pveversion -v > "${STAGING_DIR}/system-info/pveversion.txt" 2>/dev/null || true

    log "Staging area built."
}

run_backup() {
    log "Starting proxmox-backup-client backup for host '$BACKUP_ID'..."

    local ns_arg=()
    if [[ -n "$NAMESPACE" ]]; then
        ns_arg=(--ns "$NAMESPACE")
    fi

    proxmox-backup-client backup \
        etc-pve.pxar:/etc/pve \
        node-config.pxar:"$STAGING_DIR" \
        --repository "$PBS_REPOSITORY" \
        --backup-id "$BACKUP_ID" \
        --backup-type "$BACKUP_TYPE" \
        "${ns_arg[@]}"

    log "Backup completed successfully."
}

main() {
    require_root
    check_prereqs
    build_staging_area
    run_backup
}

main "$@"
