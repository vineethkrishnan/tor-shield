import sys
import re

def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: scrape_dan_nodes.py <input_html> <output_txt>")
        sys.exit(1)
        
    html_path = sys.argv[1]
    out_path  = sys.argv[2]

    with open(html_path, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    begin_marker = "<!-- __BEGIN_TOR_NODE_LIST__ //-->"
    end_marker   = "<!-- __END_TOR_NODE_LIST__ //-->"

    start = content.find(begin_marker)
    end   = content.find(end_marker)

    if start == -1 or end == -1:
        print("[additional-tor-nodes] ERROR: Could not locate node list markers in page.")
        sys.exit(1)

    # Note: slice indexing string based on start and lengths
    block_start = start + len(begin_marker)
    block = content[block_start:end]
    rows = re.split(r"<br\s*/?>", block, flags=re.IGNORECASE)

    ips = []
    for row in rows:
        row = row.strip()
        if not row or row.startswith("<!--"):
            continue
        fields = row.split("|")
        if not fields:
            continue
        ip = fields[0].strip()
        if not ip:
            continue
        ips.append(ip)

    with open(out_path, "w") as f:
        for ip in ips:
            f.write(ip + "\n")

    print(f"[additional-tor-nodes] Extracted {len(ips)} IP addresses.")

if __name__ == "__main__":
    main()
