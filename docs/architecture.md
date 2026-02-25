# TorShield — Architecture

Technical deep-dive into the data pipeline, firewall mechanics, safety guarantees, and design decisions.

---

## Table of Contents

1. [Design Principles](#1-design-principles)
2. [Data Sources](#2-data-sources)
3. [Pipeline Stages](#3-pipeline-stages)
4. [Persistent IP Files](#4-persistent-ip-files)
5. [ipset Mechanics](#5-ipset-mechanics)
6. [iptables Rule Placement](#6-iptables-rule-placement)
7. [Docker-Safe Blocking](#7-docker-safe-blocking)
8. [Backup and Rollback](#8-backup-and-rollback)
9. [Concurrency and Locking](#9-concurrency-and-locking)
10. [Failure Modes](#10-failure-modes)

---

## 1. Design Principles

| Principle | Implementation |
|-----------|----------------|
| **Fail-safe** | Every firewall mutation is preceded by a timestamped backup. Any failure after changes begin triggers automatic rollback. |
| **Append-only accumulation** | IP files grow monotonically across runs. No run can truncate them. A bad download simply adds zero new entries. |
| **Atomic swap** | The live ipset is never flushed. A new set is built offline and swapped in a single kernel operation. |
| **Minimum thresholds** | The script refuses to apply if the consolidated list falls below 100 IPv4 or 20 IPv6 entries, preventing a bad upstream from clearing the blocklist. |
| **Idempotent** | Running setup.sh multiple times produces the same firewall state. Rules are checked before insertion; duplicates are never created. |

---

## 2. Data Sources

### Source 1: Tor Project Bulk Exit List

```
URL:    https://check.torproject.org/torbulkexitlist
Format: Plain text, one IPv4 address per line
Scope:  Exit nodes that can reach the public internet
Update: Refreshed by Tor Project every ~30 minutes
```

The authoritative source. Returns only nodes currently flagged as exits by the Tor directory authorities. IPv4 only.

### Source 2: Onionoo Relay Details API

```
URL:    https://onionoo.torproject.org/details?search=flag:exit&fields=exit_addresses
Format: JSON — relays[].exit_addresses[]
Scope:  Exit-flagged relays with their exit addresses (IPv4 + IPv6)
Update: Refreshed every ~75 minutes
```

The only official source for IPv6 exit addresses. The JSON is parsed with an inline Python script that extracts addresses containing `:`, strips bracket notation, validates hex format, and normalises to lowercase.

### Source 3: dan.me.uk Tor Node List

```
URL:    https://www.dan.me.uk/tornodes
Format: HTML page with embedded pipe-delimited data
Scope:  All Tor relays (guard, middle, exit) — IPv4 + IPv6
Update: Independently maintained, continuously updated
```

This source is scraped by `additional-tor-nodes.sh`. The page contains a hidden `<div>` with the node list between HTML comment markers:

```
<!-- __BEGIN_TOR_NODE_LIST__ //-->
IP|name|port|flag|flags|bandwidth|version|contact<br>
...
<!-- __END_TOR_NODE_LIST__ //-->
```

The Python extractor locates the markers, splits on `<br>`, and takes the first pipe-delimited field from each row.

**Why three sources?** The Tor Project list captures nodes currently flagged as exits. Onionoo provides IPv6. dan.me.uk captures the broader relay population including nodes that intermittently rotate the exit flag. Together they provide defence in depth.

---

## 3. Pipeline Stages

```
Stage 1     Stage 2     Stage 3        Stage 4       Stage 5
Download    Download    Merge +        Build         Apply
IPv4        IPv6        Enrich         ipset         Rules
  │           │           │              │             │
  ▼           ▼           ▼              ▼             ▼
┌─────┐   ┌─────┐   ┌──────────┐   ┌─────────┐   ┌─────────┐
│ tmp │   │ tmp │   │ persist  │   │ tmp set │   │ live    │
│ v4  │──▶│ v6  │──▶│ files +  │──▶│ (build  │──▶│ swap +  │
│     │   │     │   │ dan.me   │   │  & val) │   │ rules   │
└─────┘   └─────┘   └──────────┘   └─────────┘   └─────────┘
                                                       │
                                                  ┌────┴────┐
                                                  │ persist │
                                                  │ + verify│
                                                  └─────────┘
```

### Stage-by-stage breakdown

| Step | Operation | Failure behaviour |
|------|-----------|-------------------|
| 1/12 | Dependency check / install | Hard abort — cannot proceed without tools |
| 2/12 | Backup iptables, ip6tables, ipset state | Hard abort — cannot safely proceed without backup |
| 3/12 | Download IPv4 bulk exit list | Warn and continue — existing file used as-is |
| 4/12 | Download IPv6 via Onionoo + Python extraction | Warn and continue — existing file used as-is |
| 5/12 | Merge downloaded IPs into persistent files | Append-only merge; zero new = harmless no-op |
| 6/12 | Run `additional-tor-nodes.sh` | Non-fatal — warn and continue on error |
| 7/12 | Validate persistent files against thresholds | Hard abort if below minimums (100 v4 / 20 v6) |
| 8/12 | Create temp ipsets, load from persistent files | Hard abort on failure |
| 9/12 | Atomic swap of temp sets into live sets | `CHANGES_APPLIED=1` — rollback armed from here |
| 10/12 | Insert iptables/ip6tables DROP rules | Idempotent check-then-insert |
| 11/12 | Persist ipset + netfilter-persistent save | Ensures reboot survival |
| 12/12 | Verify all rules and ipset counts | Automatic rollback if any check fails |

---

## 4. Persistent IP Files

### `tor_exit_nodes.txt`

- One IPv4 address per line (`a.b.c.d`)
- Validated: each octet in 0-255 range
- Append-only: `merge_ips_into_file()` checks `grep -qxF` before appending
- No comments, no blank lines (enforced by writers)

### `tor_ipv6_exits.txt`

- One IPv6 address per line (lowercase, full or compressed notation)
- Append-only, same merge logic
- Case-insensitive duplicate detection (`grep -qixF`)

### Growth model

Each run adds IPs discovered since the last run. Over weeks the files accumulate a broader set than any single snapshot. This is intentional: exit nodes that were active yesterday may reappear tomorrow.

To reset and start fresh:

```bash
rm tor_exit_nodes.txt tor_ipv6_exits.txt
sudo ./setup.sh
```

---

## 5. ipset Mechanics

### Why ipset?

Matching packets against a linear iptables rule chain is O(n). ipset uses kernel hash tables — O(1) lookup regardless of set size. With thousands of Tor exit IPs, this matters.

### Set configuration

```
Name:      tor / tor6
Type:      hash:ip
Family:    inet / inet6
Hash size: 4096
Max elem:  262144
```

### Atomic swap sequence

```
1. ipset create tor_new  hash:ip family inet  ...
2. [load all IPs into tor_new]
3. ipset swap tor_new tor        ← single atomic kernel operation
4. ipset destroy tor_new          ← cleanup old data under new name
```

If the live set `tor` doesn't exist yet (first run), `ipset rename tor_new tor` is used instead.

The swap guarantees:
- Zero window where the set is empty
- Zero window where packets are unmatched
- No rule modification needed (iptables still references `tor` by name)

---

## 6. iptables Rule Placement

Rules are inserted at position 1 in the INPUT chain:

```bash
iptables  -I INPUT 1 -m set --match-set tor  src -j DROP
ip6tables -I INPUT 1 -m set --match-set tor6 src -j DROP
```

Position 1 ensures Tor traffic is dropped before any ACCEPT rules can match it. The `-C` (check) flag is used first to prevent duplicate insertions on re-runs.

### Interaction with other firewalls

| Firewall | Interaction |
|----------|-------------|
| UFW | UFW uses its own chains (ufw-before-input, etc.) jumped to from INPUT. TorShield's rule at position 1 fires first. Compatible. |
| firewalld | Similar chain-jump architecture. TorShield rule fires first. Compatible, but audit zone rules. |
| nftables | If running legacy iptables-nft backend, rules are translated. Pure nftables setups would need adaptation. |

---

## 7. Docker-Safe Blocking

### The Docker problem

Docker creates its own iptables chains (`DOCKER`, `DOCKER-ISOLATION-STAGE-1/2`, `DOCKER-USER`). Inbound traffic to published container ports is routed through the FORWARD chain via DNAT in the PREROUTING chain — **completely bypassing the INPUT chain**.

```
                    ┌─────────┐
  Packet ──────────▶│PREROUTING│
                    │  (DNAT) │
                    └────┬────┘
                         │
                    ┌────▼────┐
                    │ FORWARD │──▶ DOCKER chain ──▶ Container
                    └─────────┘
                         │
                    ┌────▼────────┐
                    │ DOCKER-USER │  ← TorShield inserts here
                    └─────────────┘
```

### The solution

Docker provides the `DOCKER-USER` chain specifically for user-defined rules that should apply to container-bound traffic. TorShield inserts DROP rules here:

```bash
iptables  -I DOCKER-USER 1 -m set --match-set tor  src -j DROP
ip6tables -I DOCKER-USER 1 -m set --match-set tor6 src -j DROP
```

This is only done if the DOCKER-USER chain exists (Docker is installed and running). The check is:

```bash
iptables -L DOCKER-USER -n >/dev/null 2>&1
```

---

## 8. Backup and Rollback

### Backup contents

Every run creates a timestamped backup set in `/var/backups/tor-block/`:

| File | Contents |
|------|----------|
| `iptables-TIMESTAMP.rules` | Full `iptables-save` output |
| `ip6tables-TIMESTAMP.rules` | Full `ip6tables-save` output |
| `ipset-TIMESTAMP.save` | `ipset save tor` (if set existed) |
| `ipset6-TIMESTAMP.save` | `ipset save tor6` (if set existed) |
| `backup-TIMESTAMP.env` | Metadata: paths to above files, flags for whether sets existed |
| `latest.env` | Copy of most recent metadata (used by `--rollback`) |

### Automatic rollback trigger

The `CHANGES_APPLIED` flag is set to `1` immediately before the first destructive operation (ipset swap). The ERR trap checks this flag:

```bash
trap 'on_error $? $LINENO' ERR

on_error() {
  if [[ "$CHANGES_APPLIED" -eq 1 ]]; then
    rollback_from_backup ...
  fi
}
```

### Rollback sequence

1. Restore iptables rules from backup (`iptables-restore`)
2. Restore ip6tables rules from backup (`ip6tables-restore`)
3. Destroy current ipset, restore from backup (`ipset restore`)
4. Same for ipset6
5. Save restored state to `/etc/ipset.conf` and `netfilter-persistent save`

### Manual rollback

```bash
sudo ./setup.sh --rollback
```

Reads `latest.env` to find the most recent backup files and executes the same restoration sequence.

---

## 9. Concurrency and Locking

```bash
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another setup run is in progress. Aborting."
  exit 1
fi
```

A non-blocking `flock` on `/var/lock/setup_tor_block.lock` prevents concurrent runs. This is critical because:

- Two simultaneous ipset swaps could corrupt state
- Two simultaneous iptables insertions could create duplicate rules
- Backup metadata could be overwritten mid-restore

The lock is held for the duration of the process (file descriptor 9) and automatically released on exit.

---

## 10. Failure Modes

| Scenario | What happens | Data loss? |
|----------|-------------|------------|
| Network down during download | Official list empty → warn, continue with existing persistent files | No |
| dan.me.uk rate-limited | `additional-tor-nodes.sh` exits non-zero → warn, continue | No |
| Downloaded list has < 100 IPs | Hard abort before any firewall changes | No |
| ipset swap fails | ERR trap fires → automatic rollback | No |
| iptables rule insertion fails | ERR trap fires → automatic rollback | No |
| Verification fails post-apply | Explicit rollback at step 12/12 | No |
| Machine reboots mid-run | Backup exists; `--rollback` recovers. ipset.conf has last persisted state. | Partial — last persist point |
| Lock file stale after crash | Manual `rm /var/lock/setup_tor_block.lock` then re-run | No |
| Persistent files deleted | Next run recreates them from fresh downloads | Previous accumulation lost |
| `/var/backups/tor-block/` deleted | Rollback unavailable; current live state unaffected | Backup history lost |
