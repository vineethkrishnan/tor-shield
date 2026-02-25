import json
import re
import sys
from typing import Set

def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: extract_onionoo.py <input_json>")
        sys.exit(1)
        
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    ips: Set[str] = set()
    for relay in data.get("relays", []):
        for addr in relay.get("exit_addresses", []):
            if not isinstance(addr, str):
                continue
            s = addr.strip()
            if s.startswith("[") and s.endswith("]"):
                s = s[1:-1]
            if ":" not in s:
                continue
            if "%" in s:
                s = s.split("%", 1)[0]
            if re.fullmatch(r"[0-9A-Fa-f:]+", s):
                ips.add(s.lower())

    for ip in sorted(ips):
        print(ip)

if __name__ == "__main__":
    main()
