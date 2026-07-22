#!/usr/bin/env bash
#
# pve-node-restore.sh
#
# Companion to pve-node-backup.sh. Lists / extracts / (optionally) applies
# node config backed up to Proxmox Backup Server.
#
# Safety model:
#   - By default this script only EXTRACTS the backup to a local review
#     directory. It never touches live system files unless you pass --apply.
#   - /etc/pve is clustered config replicated by pmxcfs. On a healthy cluster
#     you almost never want to restore it directly onto a live node - just
#     let it rejoin the cluster and resync. So node-config (network, ssh,
#     corosync, apt, cron...) can be applied with --apply, but etc-pve.pxar
#     is extraction-only unless you pass --force-pve-restore, which requires
#     a typed confirmation. Use that only for real disaster-recovery
#     scenarios (e.g. rebuilding the last surviving node of a dead cluster).
#   - --apply always backs up whatever it's about to overwrite first.
#
# ---------------------------------------------------------------------------
set -euo pipefail

### ------------------------- CONFIGURATION --------------------------------
PBS_REPOSITORY="${PBS_REPOSITORY:-user@pbs@pbs.example.com:datastore-name}"
# export PBS_PASSWORD=... (or an API token secret) before running.

BACKUP_ID="${BACKUP_ID:-$(hostname -s)}"
NAMESPACE="${NAMESPACE:-}"
BACKUP_TYPE="host"

RESTORE_ROOT="/var/tmp/pve-node-restore"
LIVE_BACKUP_ROOT="/root/pve-node-restore-backups"
LOG_TAG="pve-node-restore"

### --------------------------------------------------------------------------

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/${LOG_TAG}.log; }
die()  { log "ERROR: $*"; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  pve-node-restore.sh --list [--backup-id ID]
  pve-node-restore.sh --extract [--snapshot SNAP|latest] [--backup-id ID] [--out DIR]
  pve-node-restore.sh --apply --snapshot SNAP [--files LIST] [--yes]
  pve-node-restore.sh --extract --snapshot SNAP --force-pve-restore [--yes]

Options:
  --list                  Show available snapshots for this backup-id.
  --extract               Extract a snapshot's archives into a review directory
                           (default action if no other mode given).
  --apply                 Extract AND copy selected node-config files onto the
                           live system, backing up existing files first.
  --snapshot SNAP         Snapshot name (as shown by --list), or "latest".
  --files LIST            Comma-separated categories to apply. One or more of:
                           network,ssh,corosync,apt,cron,sysctl,fstab,timezone,all
                           Default: all (except pve, see below).
  --force-pve-restore     Also copy /etc/pve contents from the backup onto the
                           live filesystem. DANGEROUS on a running cluster node.
                           Requires typed confirmation unless --yes is given.
  --backup-id ID          Override backup-id (default: this host's hostname).
  --out DIR               Directory to extract into (default: timestamped dir
                           under /var/tmp/pve-node-restore).
  --yes                   Skip interactive confirmations (for automation).
  -h, --help              Show this help.

Examples:
  pve-node-restore.sh --list
  pve-node-restore.sh --extract --snapshot latest
  pve-node-restore.sh --apply --snapshot latest --files network,ssh
EOF
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "This script must be run as root."
}

check_prereqs() {
    command -v proxmox-backup-client >/dev/null 2>&1 \
        || die "proxmox-backup-client not found. Install with: apt install proxmox-backup-client"
    [[ -n "${PBS_PASSWORD:-}" ]] || die "PBS_PASSWORD is not set. Export it (or an API token secret) first."
    [[ "$PBS_REPOSITORY" != *example.com* ]] \
        || die "PBS_REPOSITORY still points at the placeholder - edit the script or export PBS_REPOSITORY."
}

ns_args() {
    if [[ -n "$NAMESPACE" ]]; then
        echo "--ns $NAMESPACE"
    fi
}

# ---------------------------------------------------------------------------
list_snapshots() {
    log "Snapshots for backup-id '$BACKUP_ID':"
    # shellcheck disable=SC2046
    proxmox-backup-client snapshot list \
        --repository "$PBS_REPOSITORY" \
        $(ns_args) \
        | grep -E "host/${BACKUP_ID}/|^┌|^│|^└" || true
}

resolve_snapshot() {
    local snap="$1"
    if [[ "$snap" == "latest" || -z "$snap" ]]; then
        # shellcheck disable=SC2046
        snap=$(proxmox-backup-client snapshot list \
                --repository "$PBS_REPOSITORY" \
                --output-format json \
                $(ns_args) \
            | python3 -c "
import json,sys
data = json.load(sys.stdin)
items = [d for d in data if d.get('backup-id') == '${BACKUP_ID}' and d.get('backup-type') == '${BACKUP_TYPE}']
items.sort(key=lambda d: d.get('backup-time', 0))
if not items:
    sys.exit(1)
b = items[-1]
print(f\"host/{b['backup-id']}/{__import__('datetime').datetime.utcfromtimestamp(b['backup-time']).strftime('%Y-%m-%dT%H:%M:%SZ')}\")
") || die "Could not determine latest snapshot for backup-id '$BACKUP_ID'."
    fi
    echo "$snap"
}

# ---------------------------------------------------------------------------
extract_snapshot() {
    local snap out
    snap=$(resolve_snapshot "${SNAPSHOT:-latest}")
    out="${OUT_DIR:-${RESTORE_ROOT}/$(date +%Y%m%d-%H%M%S)}"
    mkdir -p "$out"/{node-config,etc-pve}

    log "Restoring snapshot: $snap"

    log "Extracting node-config.pxar -> $out/node-config"
    # shellcheck disable=SC2046
    proxmox-backup-client restore \
        "$snap" node-config.pxar "$out/node-config" \
        --repository "$PBS_REPOSITORY" \
        $(ns_args)

    log "Extracting etc-pve.pxar -> $out/etc-pve (review only)"
    # shellcheck disable=SC2046
    proxmox-backup-client restore \
        "$snap" etc-pve.pxar "$out/etc-pve" \
        --repository "$PBS_REPOSITORY" \
        $(ns_args)

    log "Extraction complete: $out"
    echo "$out"
}

# ---------------------------------------------------------------------------
confirm() {
    local prompt="$1"
    [[ "${ASSUME_YES:-0}" -eq 1 ]] && return 0
    read -r -p "$prompt [type 'yes' to continue]: " reply
    [[ "$reply" == "yes" ]]
}

backup_live_file() {
    local target="$1" ts="$2"
    if [[ -e "$target" ]]; then
        mkdir -p "${LIVE_BACKUP_ROOT}/${ts}$(dirname "$target")"
        cp -a "$target" "${LIVE_BACKUP_ROOT}/${ts}$(dirname "$target")/"
    fi
}

apply_category() {
    local category="$1" src_root="$2" ts="$3"
    local -a paths=()

    case "$category" in
        network) paths=(/etc/network/interfaces /etc/network/interfaces.d /etc/resolv.conf) ;;
        ssh)     paths=(/etc/ssh) ;;
        corosync) paths=(/etc/corosync) ;;
        apt)     paths=(/etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/trusted.gpg.d) ;;
        cron)    paths=(/etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /var/spool/cron/crontabs) ;;
        sysctl)  paths=(/etc/sysctl.conf /etc/sysctl.d) ;;
        fstab)   paths=(/etc/fstab) ;;
        timezone) paths=(/etc/timezone /etc/localtime) ;;
        hosts)   paths=(/etc/hosts /etc/hostname) ;;
        *) die "Unknown category: $category" ;;
    esac

    for p in "${paths[@]}"; do
        local src="${src_root}${p}"
        [[ -e "$src" ]] || continue
        log "Applying $p"
        backup_live_file "$p" "$ts"
        mkdir -p "$(dirname "$p")"
        cp -a "$src" "$(dirname "$p")/"
    done
}

apply_restore() {
    [[ -n "${SNAPSHOT:-}" ]] || die "--apply requires --snapshot SNAP (or 'latest')"
    local out ts categories
    out=$(extract_snapshot)
    ts=$(date +%Y%m%d-%H%M%S)

    categories="${FILES:-network,ssh,corosync,apt,cron,sysctl,fstab,timezone,hosts}"
    if [[ "$categories" == "all" ]]; then
        categories="network,ssh,corosync,apt,cron,sysctl,fstab,timezone,hosts"
    fi

    log "About to APPLY the following categories to the live system: $categories"
    log "Existing files will be backed up to: ${LIVE_BACKUP_ROOT}/${ts}"
    confirm "Proceed with applying node-config to this live system?" \
        || die "Aborted by user."

    IFS=',' read -r -a cats <<< "$categories"
    for c in "${cats[@]}"; do
        apply_category "$c" "${out}/node-config" "$ts"
    done

    log "Node-config apply complete. Backups of overwritten files: ${LIVE_BACKUP_ROOT}/${ts}"
    log "Review network/ssh/corosync changes and reboot or restart affected services as needed."
    log "(e.g. systemctl restart networking / systemctl restart sshd / systemctl restart corosync)"

    if [[ "${FORCE_PVE_RESTORE:-0}" -eq 1 ]]; then
        log "!!! --force-pve-restore requested: about to overwrite /etc/pve contents !!!"
        log "!!! This is only appropriate when rebuilding the last surviving node of a lost cluster. !!!"
        confirm "Type 'yes' to CONFIRM you understand this can corrupt a live cluster's config" \
            || die "Aborted --force-pve-restore."
        mkdir -p "${LIVE_BACKUP_ROOT}/${ts}/etc-pve-original"
        cp -a /etc/pve/. "${LIVE_BACKUP_ROOT}/${ts}/etc-pve-original/" 2>/dev/null || true
        cp -a "${out}/etc-pve/." /etc/pve/
        log "/etc/pve restored from backup. Original content saved to ${LIVE_BACKUP_ROOT}/${ts}/etc-pve-original"
    fi
}

# ---------------------------------------------------------------------------
MODE=""
SNAPSHOT=""
OUT_DIR=""
FILES=""
FORCE_PVE_RESTORE=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) MODE="list"; shift ;;
        --extract) MODE="extract"; shift ;;
        --apply) MODE="apply"; shift ;;
        --snapshot) SNAPSHOT="$2"; shift 2 ;;
        --backup-id) BACKUP_ID="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --files) FILES="$2"; shift 2 ;;
        --force-pve-restore) FORCE_PVE_RESTORE=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

[[ -n "$MODE" ]] || MODE="extract"

require_root
check_prereqs

case "$MODE" in
    list)    list_snapshots ;;
    extract) extract_snapshot ;;
    apply)   apply_restore ;;
    *) die "Unknown mode: $MODE" ;;
esac
