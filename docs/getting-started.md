# Getting Started with TorShield

This guide walks you through every step — from a fresh Ubuntu server to a fully automated Tor exit node firewall with daily updates.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Installation](#2-installation)
3. [Pre-flight Check](#3-pre-flight-check)
4. [First Run](#4-first-run)
5. [Verify the Firewall](#5-verify-the-firewall)
6. [Automate with Cron](#6-automate-with-cron)
7. [Manual Update](#7-manual-update)
8. [Rollback](#8-rollback)
9. [Uninstall](#9-uninstall)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Prerequisites

### System

| Requirement | Minimum |
|-------------|---------|
| OS | Ubuntu 20.04 LTS (Debian 11+ also works) |
| Kernel | Linux 4.15+ with netfilter support |
| Architecture | x86_64, arm64 |
| Privileges | Root access (`sudo`) |
| Network | Outbound HTTPS to download IP lists |

### Packages

The following will be installed automatically if you pass `--install-deps`:

- `ipset` — kernel-level IP set management
- `iptables` / `ip6tables` — packet filter rules
- `iptables-persistent` — persists rules across reboots
- `curl` — downloads IP lists
- `python3` — parses Onionoo JSON and dan.me.uk HTML

### Verify manually (optional)

```bash
dpkg -l | grep -E 'ipset|iptables-persistent|curl'
python3 --version
```

---

## 2. Installation

### Option A: Clone from Git

```bash
cd /opt
sudo git clone https://github.com/youruser/tor-firewall.git
cd tor-firewall
sudo chmod +x setup.sh additional-tor-nodes.sh
```

### Option B: Copy files manually

```bash
sudo mkdir -p /opt/tor-firewall
# scp or copy setup.sh, additional-tor-nodes.sh into /opt/tor-firewall/
sudo chmod +x /opt/tor-firewall/*.sh
```

> **Recommended path:** `/opt/tor-firewall/`. The scripts are location-independent (they resolve their own directory), but `/opt` keeps things tidy on production servers.

---

## 3. Pre-flight Check

Before making any firewall changes, run the precheck to audit your current state:

```bash
sudo ./setup.sh --precheck
```

With domain probe:

```bash
sudo ./setup.sh --precheck --domain yourapp.com
```

**What it reports:**

- OS version and compatibility
- Current iptables/ip6tables rule counts
- Whether UFW, firewalld, or nftables are active
- Docker engine status and DOCKER-USER chain presence
- fail2ban / crowdsec status
- Existing persistent IP files (if any previous run occurred)
- Cloudflare / WAF detection (if `--domain` is provided)

**Example output:**

```
========== PRECHECK ==========
OS: Ubuntu 20.04.6 LTS

[Firewall baseline]
- iptables INPUT rules: 5
- Existing INPUT drop/reject rules: no
- UFW present: no
- firewalld active: inactive
- nftables present: no

[Abuse prevention]
- fail2ban active: yes (sshd)
- crowdsec present: no

[Container/network interplay]
- Docker engine reachable: yes
- DOCKER-USER chain exists (1 rules)

[Persistent IP files]
- /opt/tor-firewall/tor_exit_nodes.txt: not yet created
- /opt/tor-firewall/tor_ipv6_exits.txt: not yet created
- additional-tor-nodes.sh: present

[Cloud/WAF hints for yourapp.com]
- Cloudflare detected via cf-ray header: yes
========== END PRECHECK ==========
```

Review this output. If you see UFW or firewalld active, be aware that TorShield adds raw iptables rules — they coexist but you should understand the interaction.

---

## 4. First Run

### With automatic dependency installation

```bash
sudo ./setup.sh --install-deps
```

### If dependencies are already installed

```bash
sudo ./setup.sh
```

The script will display a summary of what it will do and ask for confirmation:

```
Proceed? Type 'yes' to continue:
```

Type `yes` and press Enter. The 12-step pipeline runs:

| Step | What happens |
|------|--------------|
| 1/12 | Check or install dependencies |
| 2/12 | Backup current iptables, ip6tables, and ipset state |
| 3/12 | Download official IPv4 exit list from Tor Project |
| 4/12 | Download IPv6 exits from Onionoo API |
| 5/12 | Merge downloaded IPs into persistent `tor_exit_nodes.txt` and `tor_ipv6_exits.txt` |
| 6/12 | Run `additional-tor-nodes.sh` to scrape dan.me.uk for broader coverage |
| 7/12 | Validate consolidated files meet minimum IP thresholds |
| 8/12 | Build temporary ipsets and load all IPs |
| 9/12 | Atomically swap temporary sets into live `tor` / `tor6` sets |
| 10/12 | Insert DROP rules in INPUT and DOCKER-USER chains |
| 11/12 | Persist firewall state to survive reboots |
| 12/12 | Verify every rule and ipset — rollback automatically on failure |

---

## 5. Verify the Firewall

### Check ipset contents

```bash
# IPv4 count
sudo ipset list tor | grep -c '^[0-9]'

# IPv6 count
sudo ipset list tor6 | grep -c ':'

# View first 10 IPv4 entries
sudo ipset list tor | grep '^[0-9]' | head -10
```

### Check iptables rules

```bash
# IPv4 INPUT
sudo iptables -S INPUT | grep 'match-set tor '

# IPv6 INPUT
sudo ip6tables -S INPUT | grep 'match-set tor6 '

# Docker (if applicable)
sudo iptables -S DOCKER-USER | grep 'match-set tor '
```

### Check persistent files

```bash
wc -l tor_exit_nodes.txt tor_ipv6_exits.txt
```

### End-to-end test

From a separate machine with Tor installed:

```bash
# Should timeout or be refused
curl --socks5-hostname 127.0.0.1:9050 https://your-server.com
```

Or check if a known Tor exit IP is in the set:

```bash
sudo ipset test tor 185.220.101.1
# Expected: 185.220.101.1 is in set tor.
```

---

## 6. Automate with Cron

Tor exit node lists change constantly. Set up automated updates:

```bash
sudo crontab -e
```

Add these lines:

```cron
# TorShield: Update from official sources twice daily (skip dan.me.uk to avoid rate limits)
0 3,15 * * * /opt/tor-firewall/setup.sh --skip-additional < /dev/null >> /var/log/torshield.log 2>&1

# TorShield: Full update with dan.me.uk enrichment every Sunday at 04:00
0 4 * * 0 /opt/tor-firewall/setup.sh < /dev/null >> /var/log/torshield.log 2>&1
```

**Key details:**

- `< /dev/null` makes the script non-interactive (skips the `yes` confirmation prompt since there's no TTY).
- `--skip-additional` prevents hitting dan.me.uk's rate limit on frequent runs.
- The weekly Sunday run includes full enrichment from all three sources.
- Logs go to `/var/log/torshield.log` for auditing.

### Log rotation (optional)

```bash
sudo tee /etc/logrotate.d/torshield <<'EOF'
/var/log/torshield.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
```

---

## 7. Manual Update

Run the full pipeline at any time:

```bash
sudo ./setup.sh
```

Or just refresh from official sources without dan.me.uk:

```bash
sudo ./setup.sh --skip-additional
```

Or enrich from dan.me.uk without touching the firewall:

```bash
sudo ./additional-tor-nodes.sh
```

---

## 8. Rollback

### Automatic rollback

If any step fails after firewall changes have begun (step 9 onwards), the script automatically restores iptables, ip6tables, and ipset from the timestamped backup taken at step 2.

### Manual rollback

```bash
sudo ./setup.sh --rollback
```

This restores the state captured during the most recent successful run.

### Backup location

All backups are stored in `/var/backups/tor-block/`:

```
/var/backups/tor-block/
├── iptables-20260225-030000.rules
├── ip6tables-20260225-030000.rules
├── ipset-20260225-030000.save
├── ipset6-20260225-030000.save
├── backup-20260225-030000.env
└── latest.env                        ← symlink used by --rollback
```

---

## 9. Uninstall

To completely remove TorShield's firewall rules:

```bash
# Remove iptables rules
sudo iptables  -D INPUT -m set --match-set tor  src -j DROP
sudo ip6tables -D INPUT -m set --match-set tor6 src -j DROP

# Remove DOCKER-USER rules (if present)
sudo iptables  -D DOCKER-USER -m set --match-set tor  src -j DROP 2>/dev/null
sudo ip6tables -D DOCKER-USER -m set --match-set tor6 src -j DROP 2>/dev/null

# Destroy ipsets
sudo ipset destroy tor
sudo ipset destroy tor6

# Persist the clean state
sudo ipset save > /etc/ipset.conf
sudo netfilter-persistent save

# Remove cron entries
sudo crontab -e   # delete the TorShield lines

# Remove files
sudo rm -rf /opt/tor-firewall /var/backups/tor-block /var/log/torshield.log
```

---

## 10. Troubleshooting

### "Another setup run is in progress. Aborting."

The script uses `flock` to prevent concurrent runs. If a previous run crashed without releasing the lock:

```bash
sudo rm -f /var/lock/setup_tor_block.lock
```

### "Only N valid IPs found (< 100). Refusing to update."

The upstream source returned too few IPs, likely due to a temporary outage or network issue. The script aborts to prevent accidentally flushing your blocklist. Retry later or check connectivity:

```bash
curl -sI https://check.torproject.org/torbulkexitlist
```

### "additional-tor-nodes.sh exited non-zero"

dan.me.uk may be rate-limiting your IP. This is non-fatal — the script continues with whatever IPs are already in the persistent files. Wait 24 hours before retrying, or use `--skip-additional`.

### Docker containers are still reachable from Tor

Verify the DOCKER-USER chain rule exists:

```bash
sudo iptables -S DOCKER-USER | grep 'match-set tor '
```

If missing, Docker may not be running when setup.sh ran. Restart Docker, then re-run setup.sh.

### Rules disappear after reboot

Ensure `iptables-persistent` is installed and enabled:

```bash
sudo systemctl status netfilter-persistent
sudo systemctl enable netfilter-persistent
```

Then verify ipset is restored at boot:

```bash
cat /etc/ipset.conf | head -5
```

If `/etc/ipset.conf` is empty, re-run `sudo ./setup.sh`.

### UFW is active — will TorShield conflict?

TorShield inserts raw iptables rules at position 1 in the INPUT chain. UFW manages its own chains (ufw-before-input, etc.). They coexist, but the TorShield DROP rule fires first. This is the desired behaviour — Tor IPs are dropped before UFW even sees them.
