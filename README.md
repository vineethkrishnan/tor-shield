# TorShield

**Kernel-level Tor exit node firewall for Linux production servers.**

TorShield blocks all inbound traffic from known Tor exit nodes using `ipset` + `iptables`/`ip6tables` at the kernel packet-filter level — the fastest possible interception point. It covers IPv4, IPv6, host processes, and Docker containers, with automatic rollback on failure.

---

## Why

If your server has no legitimate reason to accept traffic from the Tor network (SaaS apps, APIs, internal tools), Tor exit nodes are an outsized source of abuse: credential stuffing, scraping, vulnerability scanning, and fraud. Blocking at the firewall is orders of magnitude faster than application-level detection and cannot be bypassed by rotating user agents or headers.

## How It Works

```
┌──────────────────────────────────────────────────────────────┐
│                       IP Sources                             │
│                                                              │
│  ┌─────────────────┐  ┌──────────────┐  ┌────────────────┐  │
│  │ Tor Project     │  │ Onionoo API  │  │ dan.me.uk      │  │
│  │ Bulk Exit List  │  │ (IPv6 exits) │  │ Full Node List │  │
│  │ (IPv4)          │  │              │  │ (IPv4 + IPv6)  │  │
│  └───────┬─────────┘  └──────┬───────┘  └───────┬────────┘  │
│          │                   │                   │           │
│          └───────────┬───────┘                   │           │
│                      ▼                           │           │
│          ┌───────────────────────┐               │           │
│          │  setup.sh             │               │           │
│          │  (merge + validate)   │◄──────────────┘           │
│          └───────────┬───────────┘  additional-tor-nodes.sh  │
│                      │                                       │
└──────────────────────┼───────────────────────────────────────┘
                       ▼
        ┌──────────────────────────────┐
        │   Persistent IP Files        │
        │                              │
        │   tor_exit_nodes.txt  (IPv4) │
        │   tor_ipv6_exits.txt  (IPv6) │
        └──────────────┬───────────────┘
                       │
                       ▼
        ┌──────────────────────────────┐
        │   Kernel ipset               │
        │                              │
        │   tor   (hash:ip, inet)      │
        │   tor6  (hash:ip, inet6)     │
        └──────────────┬───────────────┘
                       │  atomic swap
                       ▼
        ┌──────────────────────────────┐
        │   iptables / ip6tables       │
        │                              │
        │   INPUT       → DROP         │
        │   DOCKER-USER → DROP         │
        └──────────────────────────────┘
```

Three independent data sources are merged into two persistent text files. IPs are loaded into temporary ipsets, validated against minimum thresholds, then atomically swapped into the live sets — zero downtime, zero dropped legitimate packets during reload. If anything fails after changes begin, the entire firewall state is rolled back from timestamped backups.

## Quick Start

```bash
# 1. Clone
git clone https://github.com/youruser/tor-firewall.git
cd tor-firewall

# 2. Make scripts executable
chmod +x setup.sh additional-tor-nodes.sh

# 3. Dry-run precheck (no changes made)
sudo ./setup.sh --precheck

# 4. First run — install dependencies and apply
sudo ./setup.sh --install-deps
```

That's it. Your server is now blocking Tor exit nodes on IPv4 and IPv6, including traffic destined for Docker containers.

See the full [Getting Started Guide](docs/getting-started.md) for detailed walkthrough, cron automation, and verification steps.

## Repository Structure

```
tor-firewall/
├── setup.sh                  # Main setup & update script (run as root)
├── additional-tor-nodes.sh   # Supplementary dan.me.uk scraper
├── tor_exit_nodes.txt        # Generated — consolidated IPv4 list
├── tor_ipv6_exits.txt        # Generated — consolidated IPv6 list
├── install.sh                # Legacy quick-install (superseded by setup.sh)
├── README.md
└── docs/
    ├── getting-started.md    # Step-by-step manual
    └── architecture.md       # Technical deep-dive
```

| File | Purpose |
|------|---------|
| `setup.sh` | Downloads from official Tor sources, merges into persistent files, invokes the supplementary scraper, builds ipsets, applies iptables rules, persists state. Full backup/rollback on failure. |
| `additional-tor-nodes.sh` | Scrapes dan.me.uk/tornodes for broader relay coverage (specifically filtering for Exit nodes). Appends missing IPs to the persistent files. Called automatically by `setup.sh`. |
| `tor_exit_nodes.txt` | One IPv4 address per line. Accumulates across runs — never truncated, only appended. |
| `tor_ipv6_exits.txt` | One IPv6 address per line. Same append-only behaviour. |

## CLI Reference

### `setup.sh`

Must be run as root.

```
sudo ./setup.sh [OPTIONS]
```

| Flag | Description |
|------|-------------|
| *(no flags)* | Full run: download, merge, build ipset, apply rules, persist. |
| `--install-deps` | Install `ipset`, `iptables-persistent`, `curl` via apt before running. |
| `--precheck` | Audit firewall state, Docker, UFW, fail2ban — then exit without changes. |
| `--rollback` | Restore firewall to the most recent backup and exit. |
| `--skip-additional` | Skip the dan.me.uk supplementary scraper. |
| `--domain <fqdn>` | Probe the domain for Cloudflare/WAF headers during precheck. |

### `additional-tor-nodes.sh`

No flags. Run standalone to enrich the IP files without touching the firewall:

```bash
sudo ./additional-tor-nodes.sh
```

Or let `setup.sh` call it automatically (default behaviour).

## Automated Updates (Cron)

Tor exit node lists change constantly. Schedule a daily or twice-daily update:

```bash
# Edit root's crontab
sudo crontab -e

# Run at 03:00 and 15:00 daily, log output
0 3,15 * * * /opt/tor-firewall/setup.sh --skip-additional < /dev/null >> /var/log/torshield.log 2>&1

# Weekly full run with dan.me.uk enrichment (Sundays at 04:00)
0 4 * * 0 /opt/tor-firewall/setup.sh < /dev/null >> /var/log/torshield.log 2>&1
```

The `< /dev/null` bypasses the interactive confirmation prompt. In non-interactive mode the script detects no TTY and proceeds automatically.

> **Note:** dan.me.uk rate-limits requests. Running the full enrichment more than once per day may result in temporary blocks from their server. The `--skip-additional` flag avoids this for frequent cron runs.

## Safety Guarantees

| Concern | How TorShield handles it |
|---------|--------------------------|
| **Bad download** | Refuses to apply if fewer than 100 IPv4 or 20 IPv6 IPs pass validation. |
| **Mid-run failure** | Automatic rollback restores iptables, ip6tables, and ipset state from timestamped backup. |
| **Concurrent runs** | `flock` ensures only one instance runs at a time. |
| **Docker bypass** | DROP rules are inserted into both `INPUT` and `DOCKER-USER` chains. |
| **Zero downtime** | Temporary ipset is built offline, then atomically swapped into the live set. |
| **Manual recovery** | `sudo ./setup.sh --rollback` restores the last known-good state at any time. |

## Verification

After setup, confirm everything is active:

```bash
# Count blocked IPs
sudo ipset list tor  | grep -c '^[0-9]'
sudo ipset list tor6 | grep -c ':'

# Confirm iptables rules
sudo iptables  -S INPUT       | grep 'match-set tor '
sudo ip6tables -S INPUT       | grep 'match-set tor6 '
sudo iptables  -S DOCKER-USER | grep 'match-set tor '   # if Docker is present

# Test against a known Tor exit (from another machine)
# curl --socks5-hostname 127.0.0.1:9050 https://your-server.com
# Expected: connection timeout / refused
```

## Requirements

- **OS:** Ubuntu 20.04+ (tested), Debian 11+ (compatible)
- **Kernel:** Linux with netfilter/iptables support
- **Packages:** `ipset`, `iptables`, `ip6tables`, `iptables-persistent`, `curl`, `python3`
- **Privileges:** Root (`sudo`)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test on a staging server — never push untested firewall changes
4. Open a pull request with a clear description of what changed and why

## License

MIT
