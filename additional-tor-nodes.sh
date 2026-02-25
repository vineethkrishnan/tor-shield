#!/usr/bin/env bash
#
# |--------------------------------------------------------------------------
# | Additional Tor Node Extraction — dan.me.uk Scraper
# |--------------------------------------------------------------------------
# |
# | The official Tor Project bulk exit list (check.torproject.org) and the
# | Onionoo relay search API only expose nodes that self-report as exits at
# | the moment of query. Nodes that rotate the Exit flag on and off, or
# | that briefly appear and vanish, may be missed between refresh windows.
# |
# | dan.me.uk/tornodes maintains an independently compiled, continuously
# | updated catalogue of *all* Tor relay nodes — including guard, middle,
# | and exit relays — giving significantly broader coverage. Merging its
# | data into our local IP lists closes the gap and hardens the firewall
# | against short-lived or intermittent exit nodes that the primary
# | sources alone would miss.
# |
# | This script is designed to be run as a supplementary step after the
# | main setup.sh has already populated tor_exit_nodes.txt and
# | tor_ipv6_exits.txt from the official sources. It will never remove
# | existing entries — only append IPs that are not yet present.
# |
# |--------------------------------------------------------------------------

set -euo pipefail

# |--------------------------------------------------------------------------
# | Configuration
# |--------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPV4_FILE="${SCRIPT_DIR}/tor_exit_nodes.txt"
IPV6_FILE="${SCRIPT_DIR}/tor_ipv6_exits.txt"
SOURCE_URL="https://www.dan.me.uk/tornodes"
TMP_HTML="$(mktemp /tmp/dan_tornodes_html.XXXXXX)"
TMP_EXTRACTED="$(mktemp /tmp/dan_tornodes_extracted.XXXXXX)"

cleanup() {
  rm -f "$TMP_HTML" "$TMP_EXTRACTED"
}
trap cleanup EXIT

# |--------------------------------------------------------------------------
# | Download the Tor node page from dan.me.uk
# |--------------------------------------------------------------------------
# | Main Execution
# |--------------------------------------------------------------------------

main() {

  echo "[additional-tor-nodes] Downloading node list from ${SOURCE_URL}..."
  curl --fail --silent --show-error --location \
    --connect-timeout 15 --max-time 90 --retry 3 \
    -H "User-Agent: tor-firewall-updater/1.0" \
    "$SOURCE_URL" -o "$TMP_HTML"

  if [[ ! -s "$TMP_HTML" ]]; then
    echo "[additional-tor-nodes] ERROR: Downloaded page is empty. Aborting."
    exit 1
  fi

  # |--------------------------------------------------------------------------
  # | Extract IPs from the hidden DOM block
  # |--------------------------------------------------------------------------
  # |
  # | The page embeds the full node list inside a hidden div, delimited by
  # | HTML comments:
  # |   <!-- __BEGIN_TOR_NODE_LIST__ //-->
  # |   ...pipe-delimited rows separated by <br>...
  # |   <!-- __END_TOR_NODE_LIST__ //-->
  # |
  # | Each row is formatted as:
  # |   IP|name|port|flags_num|flags_str|bandwidth|version|contact<br>
  # |
  # | We extract the block, split on <br>, and take the first pipe-field
  # | from each row to obtain the IP address.
  # |
  # |--------------------------------------------------------------------------

  echo "[additional-tor-nodes] Extracting IP addresses from page..."

  python3 "${SCRIPT_DIR}/src/scrape_dan_nodes.py" "$TMP_HTML" "$TMP_EXTRACTED"

  if [[ ! -s "$TMP_EXTRACTED" ]]; then
    echo "[additional-tor-nodes] ERROR: No IPs extracted. Aborting."
    exit 1
  fi

  # |--------------------------------------------------------------------------
  # | Classify extracted IPs into IPv4 and IPv6
  # |--------------------------------------------------------------------------

  touch "$IPV4_FILE" "$IPV6_FILE"

  ADDED_V4=0
  ADDED_V6=0
  SKIPPED_V4=0
  SKIPPED_V6=0
  INVALID=0

  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue

    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      if grep -qxF "$ip" "$IPV4_FILE" 2>/dev/null; then
        ((SKIPPED_V4++)) || true
      else
        echo "$ip" >>"$IPV4_FILE"
        ((ADDED_V4++)) || true
      fi
    elif [[ "$ip" =~ : ]]; then
      ip_lower="$(echo "$ip" | tr '[:upper:]' '[:lower:]')"
      if grep -qixF "$ip_lower" "$IPV6_FILE" 2>/dev/null; then
        ((SKIPPED_V6++)) || true
      else
        echo "$ip_lower" >>"$IPV6_FILE"
        ((ADDED_V6++)) || true
      fi
    else
      ((INVALID++)) || true
    fi
  done <"$TMP_EXTRACTED"

  # |--------------------------------------------------------------------------
  # | Summary
  # |--------------------------------------------------------------------------

  echo ""
  echo "[additional-tor-nodes] ── Summary ──────────────────────────"
  echo "  IPv4 added  : ${ADDED_V4}"
  echo "  IPv4 skipped: ${SKIPPED_V4} (already present)"
  echo "  IPv6 added  : ${ADDED_V6}"
  echo "  IPv6 skipped: ${SKIPPED_V6} (already present)"
  if [[ "$INVALID" -gt 0 ]]; then
    echo "  Invalid     : ${INVALID} (unrecognised format)"
  fi
  echo "  IPv4 total  : $(wc -l <"$IPV4_FILE" | tr -d ' ')"
  echo "  IPv6 total  : $(wc -l <"$IPV6_FILE" | tr -d ' ')"
  echo "[additional-tor-nodes] ─────────────────────────────────────"
  echo ""
  echo "[additional-tor-nodes] Done."

}

main "$@"
