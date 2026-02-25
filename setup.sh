#!/usr/bin/env bash

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IPSET_NAME="tor"
IPSET_TMP_NAME="${IPSET_NAME}_new"
IPSET6_NAME="tor6"
IPSET6_TMP_NAME="${IPSET6_NAME}_new"

TOR_LIST_URL="https://check.torproject.org/torbulkexitlist"
TOR_ONIONOO_URL="https://onionoo.torproject.org/details?search=flag:exit&fields=exit_addresses"

IPV4_FILE="${SCRIPT_DIR}/tor_exit_nodes.txt"
IPV6_FILE="${SCRIPT_DIR}/tor_ipv6_exits.txt"
ADDITIONAL_SCRIPT="${SCRIPT_DIR}/additional-tor-nodes.sh"

MIN_IP_COUNT=100
MIN_IPV6_COUNT=20

LOCK_FILE="/var/lock/setup_tor_block.lock"
BACKUP_DIR="/var/backups/tor-block"
LATEST_BACKUP_FILE="${BACKUP_DIR}/latest.env"

INSTALL_DEPS=0
ROLLBACK_ONLY=0
PRECHECK_ONLY=0
SKIP_ADDITIONAL=0
DOMAIN=""

BACKUP_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_IPTABLES_FILE="${BACKUP_DIR}/iptables-${BACKUP_TIMESTAMP}.rules"
BACKUP_IP6TABLES_FILE="${BACKUP_DIR}/ip6tables-${BACKUP_TIMESTAMP}.rules"
BACKUP_IPSET_FILE="${BACKUP_DIR}/ipset-${BACKUP_TIMESTAMP}.save"
BACKUP_IPSET6_FILE="${BACKUP_DIR}/ipset6-${BACKUP_TIMESTAMP}.save"
BACKUP_META_FILE="${BACKUP_DIR}/backup-${BACKUP_TIMESTAMP}.env"
HAD_IPSET=0
HAD_IPSET6=0
HAD_DOCKER_USER=0
CHANGES_APPLIED=0

BIN_IPSET=""
BIN_IPTABLES=""
BIN_IPTABLES_SAVE=""
BIN_IPTABLES_RESTORE=""
BIN_IP6TABLES=""
BIN_IP6TABLES_SAVE=""
BIN_IP6TABLES_RESTORE=""
BIN_NETFILTER_PERSISTENT=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  arg="$1"
  case "$arg" in
    --install-deps)
      INSTALL_DEPS=1
      shift
      ;;
    --rollback)
      ROLLBACK_ONLY=1
      shift
      ;;
    --precheck)
      PRECHECK_ONLY=1
      shift
      ;;
    --skip-additional)
      SKIP_ADDITIONAL=1
      shift
      ;;
    --domain)
      if [[ $# -lt 2 ]]; then
        echo "--domain requires a value (e.g., --domain locaboo.com)"
        exit 1
      fi
      DOMAIN="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: $0 [--install-deps] [--rollback] [--precheck] [--skip-additional] [--domain <fqdn>]"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Root check & locking
# ---------------------------------------------------------------------------

if [[ "$(id -u)" -ne 0 && "${ROOT_BYPASS:-0}" != "1" ]]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

mkdir -p "$BACKUP_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another setup run is in progress. Aborting."
  exit 1
fi

# ---------------------------------------------------------------------------
# Temp files & cleanup
# ---------------------------------------------------------------------------

TMP_LIST_FILE="$(mktemp /tmp/tor_exit_nodes_v4.XXXXXX)"
TMP_LIST_FILE_V6="$(mktemp /tmp/tor_exit_nodes_v6.XXXXXX)"
TMP_ONIONOO_FILE="$(mktemp /tmp/tor_onionoo.XXXXXX)"

cleanup() {
  rm -f "$TMP_LIST_FILE" "$TMP_LIST_FILE_V6" "$TMP_ONIONOO_FILE"
  if resolve_bin ipset >/dev/null 2>&1; then
    "$(resolve_bin ipset)" destroy "$IPSET_TMP_NAME" >/dev/null 2>&1 || true
    "$(resolve_bin ipset)" destroy "$IPSET6_TMP_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

resolve_bin() {
  local cmd="$1"
  local resolved=""

  if resolved="$(command -v "$cmd" 2>/dev/null)"; then
    echo "$resolved"
    return 0
  fi

  for p in /usr/sbin /sbin /usr/bin /bin; do
    if [[ -x "${p}/${cmd}" ]]; then
      echo "${p}/${cmd}"
      return 0
    fi
  done

  return 1
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing dependency: $cmd"
    return 1
  fi
}

# Merge a source file of one-IP-per-line into a persistent target file,
# adding only IPs that are not already present. Works for both v4 and v6.
merge_ips_into_file() {
  local source_file="$1"
  local target_file="$2"
  local added=0

  touch "$target_file"

  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    [[ "$ip" =~ ^# ]] && continue
    if ! grep -qxF "$ip" "$target_file" 2>/dev/null; then
      echo "$ip" >>"$target_file"
      ((added++)) || true
    fi
  done <"$source_file"

  echo "$added"
}

extract_tor_ipv6_from_onionoo() {
  local source_json="$1"
  local target_file="$2"
  python3 "${SCRIPT_DIR}/src/extract_onionoo.py" "$source_json" >"$target_file"
}

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------

rollback_from_backup() {
  local iptables_file="$1"
  local ip6tables_file="$2"
  local ipset_file="$3"
  local ipset6_file="$4"
  local had_ipset="$5"
  local had_ipset6="$6"
  local ipset_bin="${BIN_IPSET:-}"
  local iptables_restore_bin="${BIN_IPTABLES_RESTORE:-}"
  local ip6tables_restore_bin="${BIN_IP6TABLES_RESTORE:-}"
  local netfilter_persistent_bin="${BIN_NETFILTER_PERSISTENT:-}"

  [[ -n "$ipset_bin" ]] || ipset_bin="$(resolve_bin ipset)"
  [[ -n "$iptables_restore_bin" ]] || iptables_restore_bin="$(resolve_bin iptables-restore)"
  [[ -n "$ip6tables_restore_bin" ]] || ip6tables_restore_bin="$(resolve_bin ip6tables-restore)"
  [[ -n "$netfilter_persistent_bin" ]] || netfilter_persistent_bin="$(resolve_bin netfilter-persistent)"

  echo "Rolling back firewall changes..."

  if [[ -f "$iptables_file" ]]; then
    "$iptables_restore_bin" <"$iptables_file"
  fi
  if [[ -f "$ip6tables_file" ]]; then
    "$ip6tables_restore_bin" <"$ip6tables_file"
  fi

  if [[ "$had_ipset" -eq 1 && -s "$ipset_file" ]]; then
    "$ipset_bin" destroy "$IPSET_NAME" >/dev/null 2>&1 || true
    "$ipset_bin" restore <"$ipset_file"
  else
    "$ipset_bin" destroy "$IPSET_NAME" >/dev/null 2>&1 || true
  fi
  if [[ "$had_ipset6" -eq 1 && -s "$ipset6_file" ]]; then
    "$ipset_bin" destroy "$IPSET6_NAME" >/dev/null 2>&1 || true
    "$ipset_bin" restore <"$ipset6_file"
  else
    "$ipset_bin" destroy "$IPSET6_NAME" >/dev/null 2>&1 || true
  fi

  "$ipset_bin" save >/etc/ipset.conf
  "$netfilter_persistent_bin" save
  echo "Rollback completed."
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  echo "Error at line ${line_no} (exit ${exit_code})."
  if [[ "$CHANGES_APPLIED" -eq 1 ]]; then
    rollback_from_backup \
      "$BACKUP_IPTABLES_FILE" \
      "$BACKUP_IP6TABLES_FILE" \
      "$BACKUP_IPSET_FILE" \
      "$BACKUP_IPSET6_FILE" \
      "$HAD_IPSET" \
      "$HAD_IPSET6" || true
  fi
  exit "$exit_code"
}

trap 'on_error $? $LINENO' ERR

# ---------------------------------------------------------------------------
# Precheck
# ---------------------------------------------------------------------------

run_precheck() {
  echo ""
  echo "========== PRECHECK =========="

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    echo "OS: ${PRETTY_NAME:-unknown}"
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "20.04" ]]; then
      echo "WARN: Script is tuned for Ubuntu 20.04; review before applying."
    fi
  fi

  echo ""
  echo "[Firewall baseline]"
  require_cmd iptables
  if "$BIN_IPTABLES" -S INPUT >/dev/null 2>&1; then
    INPUT_RULES_COUNT="$("$BIN_IPTABLES" -S INPUT | awk 'END {print NR+0}')"
    echo "- iptables INPUT rules: ${INPUT_RULES_COUNT}"
    if "$BIN_IPTABLES" -S INPUT | awk '$1=="-A" && $2=="INPUT" && $0 ~ / -j (DROP|REJECT)$/ {found=1} END {exit !found}'; then
      echo "- Existing INPUT drop/reject rules: yes"
    else
      echo "- Existing INPUT drop/reject rules: no"
    fi
  else
    echo "- iptables INPUT chain is not readable."
  fi

  if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS="$(ufw status 2>/dev/null | awk 'NR==1{print $2}')"
    echo "- UFW present: yes (status: ${UFW_STATUS:-unknown})"
  else
    echo "- UFW present: no"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    FIREWALLD_STATE="$(systemctl is-active firewalld 2>/dev/null || true)"
    echo "- firewalld active: ${FIREWALLD_STATE:-inactive}"
  fi

  if command -v nft >/dev/null 2>&1; then
    if nft list ruleset >/dev/null 2>&1; then
      NFT_LINES="$(nft list ruleset | awk 'END {print NR+0}')"
      echo "- nftables ruleset lines: ${NFT_LINES}"
    else
      echo "- nftables present but ruleset not readable"
    fi
  else
    echo "- nftables present: no"
  fi

  echo ""
  echo "[Abuse prevention]"
  if command -v fail2ban-client >/dev/null 2>&1; then
    if fail2ban-client status >/dev/null 2>&1; then
      JAILS="$(fail2ban-client status | awk -F: '/Jail list/ {gsub(/^[ \t]+/, "", $2); print $2}')"
      echo "- fail2ban active: yes (${JAILS:-no-jails-listed})"
    else
      echo "- fail2ban installed but not active"
    fi
  else
    echo "- fail2ban present: no"
  fi

  if command -v cscli >/dev/null 2>&1; then
    echo "- crowdsec present: yes"
  else
    echo "- crowdsec present: no"
  fi

  echo ""
  echo "[Container/network interplay]"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "- Docker engine reachable: yes"
    if "$BIN_IPTABLES" -S DOCKER-USER >/dev/null 2>&1; then
      DOCKER_USER_RULES="$("$BIN_IPTABLES" -S DOCKER-USER | awk 'END {print NR+0}')"
      echo "- DOCKER-USER chain exists (${DOCKER_USER_RULES} rules)"
    else
      echo "- DOCKER-USER chain exists: no"
    fi
  else
    echo "- Docker engine reachable: no"
  fi

  echo ""
  echo "[Persistent IP files]"
  if [[ -f "$IPV4_FILE" ]]; then
    echo "- ${IPV4_FILE}: $(wc -l <"$IPV4_FILE" | tr -d ' ') entries"
  else
    echo "- ${IPV4_FILE}: not yet created"
  fi
  if [[ -f "$IPV6_FILE" ]]; then
    echo "- ${IPV6_FILE}: $(wc -l <"$IPV6_FILE" | tr -d ' ') entries"
  else
    echo "- ${IPV6_FILE}: not yet created"
  fi
  if [[ -x "$ADDITIONAL_SCRIPT" ]]; then
    echo "- additional-tor-nodes.sh: present"
  else
    echo "- additional-tor-nodes.sh: not found (dan.me.uk enrichment will be skipped)"
  fi

  if [[ -n "$DOMAIN" ]]; then
    echo ""
    echo "[Cloud/WAF hints for ${DOMAIN}]"
    if command -v curl >/dev/null 2>&1; then
      HDR_FILE="$(mktemp /tmp/tor_precheck_hdr.XXXXXX)"
      if curl -sS -I --max-time 10 "https://${DOMAIN}" >"$HDR_FILE"; then
        if awk 'tolower($0) ~ /^cf-ray:/ {found=1} END {exit !found}' "$HDR_FILE"; then
          echo "- Cloudflare detected via cf-ray header: yes"
        else
          echo "- Cloudflare cf-ray header detected: no/unknown"
        fi
        if awk 'tolower($0) ~ /^server:/ {print "- upstream server header: " $0}' "$HDR_FILE"; then :; fi
      else
        echo "- Could not fetch headers from https://${DOMAIN}"
      fi
      rm -f "$HDR_FILE"
    fi
  else
    echo ""
    echo "[Cloud/WAF hints]"
    echo "- Tip: pass --domain <fqdn> to probe edge headers (Cloudflare/WAF indicators)."
  fi

  echo "========== END PRECHECK =========="
  echo ""
}

# ---------------------------------------------------------------------------
# Early binary resolution (needed by precheck)
# ---------------------------------------------------------------------------

BIN_IPTABLES="$(resolve_bin iptables || true)"
[[ -n "$BIN_IPTABLES" ]] || BIN_IPTABLES="iptables"

# ---------------------------------------------------------------------------
# Rollback-only mode
# ---------------------------------------------------------------------------

if [[ "$ROLLBACK_ONLY" -eq 1 ]]; then
  if [[ ! -f "$LATEST_BACKUP_FILE" ]]; then
    echo "No rollback metadata found at ${LATEST_BACKUP_FILE}."
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$LATEST_BACKUP_FILE"
  rollback_from_backup \
    "$ROLLBACK_IPTABLES_FILE" \
    "$ROLLBACK_IP6TABLES_FILE" \
    "$ROLLBACK_IPSET_FILE" \
    "$ROLLBACK_IPSET6_FILE" \
    "$ROLLBACK_HAD_IPSET" \
    "$ROLLBACK_HAD_IPSET6"
  exit 0
fi

# ---------------------------------------------------------------------------
# Precheck
# ---------------------------------------------------------------------------

run_precheck
if [[ "$PRECHECK_ONLY" -eq 1 ]]; then
  echo "Precheck-only mode complete. No firewall changes were made."
  exit 0
fi

# ===================================================================
#  MAIN ENTRYPOINT
# ===================================================================

main() {

  echo "========================================================"
  echo " Tor Exit Node Firewall Block Setup"
  echo " Ubuntu 20.04 - Production Safe Mode (IPv4 + IPv6)"
  echo "========================================================"
  echo ""
  echo "This script will:"
  echo "  1. Download Tor exit IPs from official sources"
  echo "  2. Merge with additional IPs from dan.me.uk (if available)"
  echo "  3. Build consolidated tor_exit_nodes.txt & tor_ipv6_exits.txt"
  echo "  4. Load into ipset and atomically replace '${IPSET_NAME}' / '${IPSET6_NAME}'"
  echo "  5. Ensure iptables + ip6tables DROP rules (INPUT & DOCKER-USER)"
  echo "  6. Persist firewall state"
  echo ""
  read -r -p "Proceed? Type 'yes' to continue: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi

  # ---------------------------------------------------------------------------
  # [1/12] Dependencies
  # ---------------------------------------------------------------------------

  if [[ "$INSTALL_DEPS" -eq 1 ]]; then
    echo "[1/12] Installing required packages..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y ipset iptables-persistent curl
  else
    echo "[1/12] Checking required commands..."
    require_cmd ipset
    require_cmd iptables
    require_cmd iptables-save
    require_cmd iptables-restore
    require_cmd ip6tables
    require_cmd ip6tables-save
    require_cmd ip6tables-restore
    require_cmd curl
    require_cmd python3
    require_cmd netfilter-persistent
  fi

  BIN_IPSET="$(resolve_bin ipset)" || {
    echo "Cannot resolve ipset binary."
    exit 1
  }
  BIN_IPTABLES="$(resolve_bin iptables)" || {
    echo "Cannot resolve iptables binary."
    exit 1
  }
  BIN_IPTABLES_SAVE="$(resolve_bin iptables-save)" || {
    echo "Cannot resolve iptables-save binary."
    exit 1
  }
  BIN_IPTABLES_RESTORE="$(resolve_bin iptables-restore)" || {
    echo "Cannot resolve iptables-restore binary."
    exit 1
  }
  BIN_IP6TABLES="$(resolve_bin ip6tables)" || {
    echo "Cannot resolve ip6tables binary."
    exit 1
  }
  BIN_IP6TABLES_SAVE="$(resolve_bin ip6tables-save)" || {
    echo "Cannot resolve ip6tables-save binary."
    exit 1
  }
  BIN_IP6TABLES_RESTORE="$(resolve_bin ip6tables-restore)" || {
    echo "Cannot resolve ip6tables-restore binary."
    exit 1
  }
  BIN_NETFILTER_PERSISTENT="$(resolve_bin netfilter-persistent)" || {
    echo "Cannot resolve netfilter-persistent binary."
    exit 1
  }

  # ---------------------------------------------------------------------------
  # [2/12] Firewall backups
  # ---------------------------------------------------------------------------

  echo "[2/12] Taking firewall backups..."
  "$BIN_IPTABLES_SAVE" >"$BACKUP_IPTABLES_FILE"
  "$BIN_IP6TABLES_SAVE" >"$BACKUP_IP6TABLES_FILE"

  if "$BIN_IPSET" list "$IPSET_NAME" >/dev/null 2>&1; then
    HAD_IPSET=1
    "$BIN_IPSET" save "$IPSET_NAME" >"$BACKUP_IPSET_FILE"
  else
    HAD_IPSET=0
    : >"$BACKUP_IPSET_FILE"
  fi

  if "$BIN_IPSET" list "$IPSET6_NAME" >/dev/null 2>&1; then
    HAD_IPSET6=1
    "$BIN_IPSET" save "$IPSET6_NAME" >"$BACKUP_IPSET6_FILE"
  else
    HAD_IPSET6=0
    : >"$BACKUP_IPSET6_FILE"
  fi

  cat >"$BACKUP_META_FILE" <<EOF
ROLLBACK_IPTABLES_FILE=${BACKUP_IPTABLES_FILE}
ROLLBACK_IP6TABLES_FILE=${BACKUP_IP6TABLES_FILE}
ROLLBACK_IPSET_FILE=${BACKUP_IPSET_FILE}
ROLLBACK_IPSET6_FILE=${BACKUP_IPSET6_FILE}
ROLLBACK_HAD_IPSET=${HAD_IPSET}
ROLLBACK_HAD_IPSET6=${HAD_IPSET6}
EOF
  cp "$BACKUP_META_FILE" "$LATEST_BACKUP_FILE"

  # ---------------------------------------------------------------------------
  # [3/12] Download official IPv4 exit list
  # ---------------------------------------------------------------------------

  echo "[3/12] Downloading official Tor IPv4 exit node list..."
  curl --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 60 --retry 3 \
    "$TOR_LIST_URL" -o "$TMP_LIST_FILE"

  if [[ ! -s "$TMP_LIST_FILE" ]]; then
    echo "WARN: Official IPv4 list download is empty. Continuing with existing file."
  fi

  # ---------------------------------------------------------------------------
  # [4/12] Download official IPv6 exit list (via Onionoo)
  # ---------------------------------------------------------------------------

  echo "[4/12] Downloading official Tor IPv6 exit nodes via Onionoo..."
  curl --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 60 --retry 3 \
    "$TOR_ONIONOO_URL" -o "$TMP_ONIONOO_FILE"
  extract_tor_ipv6_from_onionoo "$TMP_ONIONOO_FILE" "$TMP_LIST_FILE_V6"

  # ---------------------------------------------------------------------------
  # [5/12] Merge official downloads into persistent files
  # ---------------------------------------------------------------------------

  echo "[5/12] Merging official IPs into persistent files..."
  touch "$IPV4_FILE" "$IPV6_FILE"

  MERGED_V4=0
  if [[ -s "$TMP_LIST_FILE" ]]; then
    # Filter to valid IPv4 only before merging
    TMP_CLEAN_V4="$(mktemp /tmp/tor_clean_v4.XXXXXX)"
    awk '
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
      split($0, o, ".")
      ok=1
      for (i=1; i<=4; i++) if (o[i] < 0 || o[i] > 255) ok=0
      if (ok) print
    }
  ' "$TMP_LIST_FILE" >"$TMP_CLEAN_V4"
    MERGED_V4="$(merge_ips_into_file "$TMP_CLEAN_V4" "$IPV4_FILE")"
    rm -f "$TMP_CLEAN_V4"
  fi

  MERGED_V6=0
  if [[ -s "$TMP_LIST_FILE_V6" ]]; then
    MERGED_V6="$(merge_ips_into_file "$TMP_LIST_FILE_V6" "$IPV6_FILE")"
  fi

  echo "  - Official IPv4 newly merged: ${MERGED_V4}"
  echo "  - Official IPv6 newly merged: ${MERGED_V6}"

  # ---------------------------------------------------------------------------
  # [6/12] Run additional-tor-nodes.sh for dan.me.uk enrichment
  # ---------------------------------------------------------------------------

  if [[ "$SKIP_ADDITIONAL" -eq 1 ]]; then
    echo "[6/12] Skipping additional-tor-nodes.sh (--skip-additional flag)."
  elif [[ -x "$ADDITIONAL_SCRIPT" ]]; then
    echo "[6/12] Running additional-tor-nodes.sh for dan.me.uk enrichment..."
    if "$ADDITIONAL_SCRIPT"; then
      echo "  - dan.me.uk enrichment completed."
    else
      echo "  WARN: additional-tor-nodes.sh exited non-zero. Continuing with existing files."
    fi
  else
    echo "[6/12] additional-tor-nodes.sh not found or not executable. Skipping."
  fi

  # ---------------------------------------------------------------------------
  # [7/12] Validate consolidated IP files
  # ---------------------------------------------------------------------------

  echo "[7/12] Validating consolidated IP files..."

  VALID_IP_COUNT="$(awk '
  /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
    split($0, o, ".")
    ok=1
    for (i=1; i<=4; i++) if (o[i] < 0 || o[i] > 255) ok=0
    if (ok) c++
  }
  END { print c + 0 }
' "$IPV4_FILE")"

  VALID_IPV6_COUNT="$(awk 'NF && $0 !~ /^#/ {c++} END {print c + 0}' "$IPV6_FILE")"

  echo "  - Valid IPv4 entries: ${VALID_IP_COUNT}"
  echo "  - Valid IPv6 entries: ${VALID_IPV6_COUNT}"

  if [[ "$VALID_IP_COUNT" -lt "$MIN_IP_COUNT" ]]; then
    echo "ERROR: Only ${VALID_IP_COUNT} valid IPv4 IPs (minimum ${MIN_IP_COUNT})."
    echo "Refusing to update firewall to avoid bad source data."
    exit 1
  fi

  if [[ "$VALID_IPV6_COUNT" -lt "$MIN_IPV6_COUNT" ]]; then
    echo "ERROR: Only ${VALID_IPV6_COUNT} valid IPv6 IPs (minimum ${MIN_IPV6_COUNT})."
    echo "Refusing to update IPv6 firewall set to avoid bad source data."
    exit 1
  fi

  # ---------------------------------------------------------------------------
  # [8/12] Build temporary ipsets
  # ---------------------------------------------------------------------------

  echo "[8/12] Building temporary ipsets..."
  "$BIN_IPSET" destroy "$IPSET_TMP_NAME" >/dev/null 2>&1 || true
  "$BIN_IPSET" create "$IPSET_TMP_NAME" hash:ip family inet hashsize 4096 maxelem 262144

  "$BIN_IPSET" destroy "$IPSET6_TMP_NAME" >/dev/null 2>&1 || true
  "$BIN_IPSET" create "$IPSET6_TMP_NAME" hash:ip family inet6 hashsize 4096 maxelem 262144

  echo "[8/12] Loading IPv4 from ${IPV4_FILE}..."
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    [[ "$ip" =~ ^# ]] && continue
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      "$BIN_IPSET" add "$IPSET_TMP_NAME" "$ip" -exist
    fi
  done <"$IPV4_FILE"

  echo "[8/12] Loading IPv6 from ${IPV6_FILE}..."
  while IFS= read -r ip6; do
    [[ -z "$ip6" ]] && continue
    [[ "$ip6" =~ ^# ]] && continue
    "$BIN_IPSET" add "$IPSET6_TMP_NAME" "$ip6" -exist
  done <"$IPV6_FILE"

  TMP_COUNT="$("$BIN_IPSET" list "$IPSET_TMP_NAME" | awk '/^[0-9]+\./ {c++} END {print c + 0}')"
  TMP_COUNT6="$("$BIN_IPSET" list "$IPSET6_TMP_NAME" | awk 'NF && $1 ~ /:/ {c++} END {print c + 0}')"

  echo "  - IPv4 in ipset: ${TMP_COUNT}"
  echo "  - IPv6 in ipset: ${TMP_COUNT6}"

  if [[ "$TMP_COUNT" -lt "$MIN_IP_COUNT" ]]; then
    echo "ERROR: Temporary ipset has only ${TMP_COUNT} IPv4 entries. Aborting."
    exit 1
  fi
  if [[ "$TMP_COUNT6" -lt "$MIN_IPV6_COUNT" ]]; then
    echo "ERROR: Temporary ipset has only ${TMP_COUNT6} IPv6 entries. Aborting."
    exit 1
  fi

  # ---------------------------------------------------------------------------
  # [9/12] Atomically replace live ipsets
  # ---------------------------------------------------------------------------

  echo "[9/12] Atomically replacing '${IPSET_NAME}' and '${IPSET6_NAME}'..."
  CHANGES_APPLIED=1

  if "$BIN_IPSET" list "$IPSET_NAME" >/dev/null 2>&1; then
    "$BIN_IPSET" swap "$IPSET_TMP_NAME" "$IPSET_NAME"
    "$BIN_IPSET" destroy "$IPSET_TMP_NAME"
  else
    "$BIN_IPSET" rename "$IPSET_TMP_NAME" "$IPSET_NAME"
  fi

  if "$BIN_IPSET" list "$IPSET6_NAME" >/dev/null 2>&1; then
    "$BIN_IPSET" swap "$IPSET6_TMP_NAME" "$IPSET6_NAME"
    "$BIN_IPSET" destroy "$IPSET6_TMP_NAME"
  else
    "$BIN_IPSET" rename "$IPSET6_TMP_NAME" "$IPSET6_NAME"
  fi

  # ---------------------------------------------------------------------------
  # [10/12] Ensure iptables/ip6tables DROP rules
  # ---------------------------------------------------------------------------

  echo "[10/12] Ensuring firewall DROP rules..."

  # --- INPUT chain (host-level traffic) ---
  if ! "$BIN_IPTABLES" -C INPUT -m set --match-set "$IPSET_NAME" src -j DROP >/dev/null 2>&1; then
    "$BIN_IPTABLES" -I INPUT 1 -m set --match-set "$IPSET_NAME" src -j DROP
    echo "  - Added IPv4 INPUT DROP rule."
  else
    echo "  - IPv4 INPUT DROP rule already present."
  fi

  if ! "$BIN_IP6TABLES" -C INPUT -m set --match-set "$IPSET6_NAME" src -j DROP >/dev/null 2>&1; then
    "$BIN_IP6TABLES" -I INPUT 1 -m set --match-set "$IPSET6_NAME" src -j DROP
    echo "  - Added IPv6 INPUT DROP rule."
  else
    echo "  - IPv6 INPUT DROP rule already present."
  fi

  # --- DOCKER-USER chain (container-bound traffic bypasses INPUT) ---
  HAD_DOCKER_USER=0
  if "$BIN_IPTABLES" -L DOCKER-USER -n >/dev/null 2>&1; then
    HAD_DOCKER_USER=1
    if ! "$BIN_IPTABLES" -C DOCKER-USER -m set --match-set "$IPSET_NAME" src -j DROP >/dev/null 2>&1; then
      "$BIN_IPTABLES" -I DOCKER-USER 1 -m set --match-set "$IPSET_NAME" src -j DROP
      echo "  - Added IPv4 DOCKER-USER DROP rule."
    else
      echo "  - IPv4 DOCKER-USER DROP rule already present."
    fi
  fi

  if "$BIN_IP6TABLES" -L DOCKER-USER -n >/dev/null 2>&1; then
    if ! "$BIN_IP6TABLES" -C DOCKER-USER -m set --match-set "$IPSET6_NAME" src -j DROP >/dev/null 2>&1; then
      "$BIN_IP6TABLES" -I DOCKER-USER 1 -m set --match-set "$IPSET6_NAME" src -j DROP
      echo "  - Added IPv6 DOCKER-USER DROP rule."
    else
      echo "  - IPv6 DOCKER-USER DROP rule already present."
    fi
  fi

  # ---------------------------------------------------------------------------
  # [11/12] Persist firewall configuration
  # ---------------------------------------------------------------------------

  echo "[11/12] Persisting firewall configuration..."
  "$BIN_IPSET" save >/etc/ipset.conf
  "$BIN_NETFILTER_PERSISTENT" save

  # ---------------------------------------------------------------------------
  # [12/12] Verification with rollback on failure
  # ---------------------------------------------------------------------------

  echo "[12/12] Verifying applied rules..."
  VERIFY_FAILED=0

  if ! "$BIN_IPTABLES" -C INPUT -m set --match-set "$IPSET_NAME" src -j DROP >/dev/null 2>&1; then
    echo "  FAIL: IPv4 INPUT rule not found."
    VERIFY_FAILED=1
  fi

  if ! "$BIN_IP6TABLES" -C INPUT -m set --match-set "$IPSET6_NAME" src -j DROP >/dev/null 2>&1; then
    echo "  FAIL: IPv6 INPUT rule not found."
    VERIFY_FAILED=1
  fi

  if [[ "$HAD_DOCKER_USER" -eq 1 ]]; then
    if ! "$BIN_IPTABLES" -C DOCKER-USER -m set --match-set "$IPSET_NAME" src -j DROP >/dev/null 2>&1; then
      echo "  FAIL: IPv4 DOCKER-USER rule not found."
      VERIFY_FAILED=1
    fi
  fi

  LIVE_V4="$("$BIN_IPSET" list "$IPSET_NAME" 2>/dev/null | awk '/^[0-9]+\./ {c++} END {print c + 0}')"
  LIVE_V6="$("$BIN_IPSET" list "$IPSET6_NAME" 2>/dev/null | awk 'NF && $1 ~ /:/ {c++} END {print c + 0}')"

  if [[ "$LIVE_V4" -lt "$MIN_IP_COUNT" ]]; then
    echo "  FAIL: Live ipset '${IPSET_NAME}' has only ${LIVE_V4} entries."
    VERIFY_FAILED=1
  fi
  if [[ "$LIVE_V6" -lt "$MIN_IPV6_COUNT" ]]; then
    echo "  FAIL: Live ipset '${IPSET6_NAME}' has only ${LIVE_V6} entries."
    VERIFY_FAILED=1
  fi

  if [[ "$VERIFY_FAILED" -eq 1 ]]; then
    echo ""
    echo "Verification failed — initiating automatic rollback."
    rollback_from_backup \
      "$BACKUP_IPTABLES_FILE" \
      "$BACKUP_IP6TABLES_FILE" \
      "$BACKUP_IPSET_FILE" \
      "$BACKUP_IPSET6_FILE" \
      "$HAD_IPSET" \
      "$HAD_IPSET6"
    exit 1
  fi

  # ---------------------------------------------------------------------------
  # Summary
  # ---------------------------------------------------------------------------

  echo ""
  echo "========================================================"
  echo " Setup completed successfully"
  echo "========================================================"
  echo ""
  echo "  IPv4 blocked (${IPSET_NAME}): ${LIVE_V4}"
  echo "  IPv6 blocked (${IPSET6_NAME}): ${LIVE_V6}"
  echo ""
  echo "  Sources:"
  echo "    - Official bulk exit list:  ${TOR_LIST_URL}"
  echo "    - Onionoo IPv6 exits:      ${TOR_ONIONOO_URL}"
  if [[ -x "$ADDITIONAL_SCRIPT" && "$SKIP_ADDITIONAL" -eq 0 ]]; then
    echo "    - dan.me.uk node scraper:  ${ADDITIONAL_SCRIPT}"
  fi
  echo ""
  echo "  Persistent files:"
  echo "    - IPv4: ${IPV4_FILE}"
  echo "    - IPv6: ${IPV6_FILE}"
  echo ""
  echo "  Active rules:"
  "$BIN_IPTABLES" -S INPUT | awk '/--match-set tor / {print "    [iptables]  " $0}'
  "$BIN_IP6TABLES" -S INPUT | awk '/--match-set tor6 / {print "    [ip6tables] " $0}'
  if [[ "$HAD_DOCKER_USER" -eq 1 ]]; then
    "$BIN_IPTABLES" -S DOCKER-USER | awk '/--match-set tor / {print "    [docker-v4] " $0}'
    "$BIN_IP6TABLES" -S DOCKER-USER 2>/dev/null | awk '/--match-set tor6 / {print "    [docker-v6] " $0}'
  fi
  echo ""
  echo "  Rollback:"
  echo "    - Automatic on runtime failure after changes begin."
  echo "    - Manual: $0 --rollback"
  echo "    - Backups: ${BACKUP_DIR}/"
  echo ""

}

main "$@"
