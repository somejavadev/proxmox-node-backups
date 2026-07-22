# pve-node-backup

Backup and restore scripts for **Proxmox VE node configuration** (the host
itself, not VMs/CTs) using [Proxmox Backup Server](https://pbs.proxmox.com/)
(`proxmox-backup-client`).

This is aimed at nodes that are members of a Proxmox cluster. It does **not**
back up guest VMs/containers (use `vzdump` / PBS VM backups for that) and it
does **not** create a full disk image. Instead it captures the small set of
files that are unique to each host and can't simply be resynced from the
cluster:

- `/etc/network/interfaces`, `/etc/hosts`, `/etc/hostname`, `/etc/resolv.conf`
- `/etc/ssh` (host keys, `sshd_config`)
- `/etc/corosync`
- `/etc/apt/sources.list*`, trusted keyrings
- `/etc/cron.*`, user crontabs
- `/etc/sysctl.conf` / `/etc/sysctl.d`
- `/etc/fstab`, timezone, and a snapshot of `dpkg --get-selections`,
  `pvecm status`, `ip a`, `pveversion -v` for reference during a rebuild
- `/etc/pve` — the cluster-wide config filesystem (`pmxcfs`). This is already
  replicated across every node via corosync, so it's low-risk, but it's
  backed up too for an extra safety net / point-in-time history.

## Why not just image the whole disk?

A dead cluster node is normally best recovered by **reinstalling Proxmox VE
fresh and rejoining it to the cluster** — `/etc/pve` and all VM configs
resync automatically from the other quorate nodes. Restoring a full disk
image back into a live cluster risks stale corosync state and node-ID
conflicts. So the scripts here focus on the handful of files that are
genuinely local to the host and would otherwise be lost.

## Contents

| File | Purpose |
|---|---|
| `pve-node-backup.sh` | Stages node-specific files + `/etc/pve`, sends them to PBS |
| `pve-node-restore.sh` | Lists / extracts / (optionally) applies a backup |
| `examples/pve-node-backup.env.example` | Template for PBS credentials |
| `examples/pve-node-backup.service` | systemd service unit to run the backup |
| `examples/pve-node-backup.timer` | systemd timer for nightly scheduling |

## Requirements

- `proxmox-backup-client` installed on each node (`apt install proxmox-backup-client`)
- Network access from each node to your PBS server
- A PBS datastore + user or, preferably, an **API token** scoped to that datastore
- Run as root (needs to read `/etc/ssh`, `/etc/corosync`, etc.)

## Setup

1. Copy `pve-node-backup.sh` and `pve-node-restore.sh` to each node, e.g.:
   ```bash
   install -m 750 pve-node-backup.sh  /usr/local/bin/pve-node-backup.sh
   install -m 750 pve-node-restore.sh /usr/local/bin/pve-node-restore.sh
   ```
2. Create a PBS API token for backups (recommended over a raw user password):
   ```bash
   # On the PBS server
   proxmox-backup-manager user generate-token backup@pbs pve-node-backup
   ```
   Grant it `DatastoreBackup` (and `DatastoreReader` if you also want restores
   with the same token) on the target datastore.
3. Set the repository/credentials, either by editing the top of the scripts
   or — better — via environment variables. Each node uses its own hostname
   as the backup ID automatically, so **the same credentials and script can
   be reused unchanged across all nodes**.

## Manual usage

```bash
export PBS_REPOSITORY="user@pbs!pve-node-backup@pbs.example.com:datastore-name"
export PBS_PASSWORD="the-token-secret"

./pve-node-backup.sh
```

List and inspect backups:

```bash
./pve-node-restore.sh --list
./pve-node-restore.sh --extract --snapshot latest
# review files under /var/tmp/pve-node-restore/<timestamp>/
```

Apply specific files back onto a (freshly rebuilt) node:

```bash
./pve-node-restore.sh --apply --snapshot latest --files network,ssh
```

`--apply` always backs up whatever it's about to overwrite to
`/root/pve-node-restore-backups/<timestamp>/` first. Restoring `/etc/pve`
itself onto a live system requires the explicit `--force-pve-restore` flag
plus a typed confirmation — see the script's `--help` and the comments at
the top of `pve-node-restore.sh` for when that's actually appropriate
(essentially only: rebuilding the last surviving node of a lost cluster).

## Scheduling the backup

You have two straightforward options. **systemd timers are recommended**
over cron because they let you keep credentials out of the crontab and out
of `ps` output, and they log to the journal.

### Option A: systemd timer (recommended)

1. Store credentials in a root-only env file:
   ```bash
   cp examples/pve-node-backup.env.example /etc/pve-node-backup.env
   chmod 600 /etc/pve-node-backup.env
   $EDITOR /etc/pve-node-backup.env
   ```
2. Install the unit files:
   ```bash
   cp examples/pve-node-backup.service /etc/systemd/system/
   cp examples/pve-node-backup.timer   /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable --now pve-node-backup.timer
   ```
3. Check it:
   ```bash
   systemctl list-timers pve-node-backup.timer
   journalctl -u pve-node-backup.service
   ```

The provided timer runs daily at 03:00 with up to 10 minutes of random
jitter (`RandomizedDelaySec`), which is enough to avoid every node in the
cluster hitting PBS at the exact same second without you having to hand-pick
per-node times. If you'd rather stagger explicitly, set a different
`OnCalendar=` per node (e.g. `03:00`, `03:05`, `03:10`).

Repeat this setup — same files, same credentials — on every node in the
cluster; each one backs up independently under its own hostname (see
"Do all nodes need to run at the same time?" below).

### Option B: cron

If you'd rather use cron, put credentials in a file the crontab sources
rather than inline in the crontab itself:

```bash
# /etc/cron.d/pve-node-backup
0 3 * * * root . /etc/pve-node-backup.env && /usr/local/bin/pve-node-backup.sh >> /var/log/pve-node-backup-cron.log 2>&1
```

Stagger nodes a few minutes apart if you're not using the systemd timer's
built-in jitter, e.g. `0 3`, `5 3`, `10 3` for node1/node2/node3.

### Do all nodes need to run at the same time?

No. Each node backs up under its own `--backup-id` (its hostname), so
there's no shared state or race condition between nodes. `/etc/pve` is
identical across nodes anyway (it's the replicated cluster filesystem), so
it doesn't matter which node's copy — or when — it gets captured. Run each
node on a similar daily cadence; exact synchronization isn't required, only
mild staggering to spread load on the PBS server.

## Restoring after a node rebuild

Typical flow for replacing a dead node in an otherwise healthy cluster:

```bash
# On a healthy remaining node:
pvecm delnode <dead-node-name>

# Reinstall Proxmox VE fresh on the replacement, same hostname, then:
pvecm add <cluster-ip>

# On the new node, pull back just the node-specific bits:
./pve-node-restore.sh --apply --snapshot latest --files network,ssh
```

`/etc/pve` is left to resync naturally from the quorate cluster rather than
being restored from backup.

## Security notes

- Prefer an **API token** scoped to just the backup datastore over a full
  user password.
- `pve-node-backup.env` / any file holding `PBS_PASSWORD` should be
  `chmod 600`, root-owned.
- The backup includes SSH **host keys** — treat PBS access to this datastore
  as sensitive, equivalent to root access on your nodes.
- `--force-pve-restore` is intentionally awkward to invoke. Don't script
  around the confirmation prompt.

## License

MIT; no warranty.
