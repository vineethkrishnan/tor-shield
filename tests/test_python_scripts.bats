#!/usr/bin/env bats

setup() {
  export TEST_TEMP_DIR="$(mktemp -d)"
  export SCRIPT_DIR="${BATS_TEST_DIRNAME}/.."
}

teardown() {
  rm -rf "$TEST_TEMP_DIR"
}

@test "extract_onionoo.py correctly parses IPv6 from Onionoo JSON" {
  local mock_json="${TEST_TEMP_DIR}/onionoo.json"
  local output_file="${TEST_TEMP_DIR}/onionoo.txt"

  cat << 'EOF' > "$mock_json"
{
  "relays": [
    {
      "exit_addresses": [
        "192.168.1.1",
        "2001:db8:1234::1"
      ]
    },
    {
      "exit_addresses": [
        "2001:db8:1234::2",
        "invalid_ip"
      ]
    }
  ]
}
EOF

  run python3 "${SCRIPT_DIR}/src/extract_onionoo.py" "$mock_json"
  [ "$status" -eq 0 ]
  
  # Redirect output to file to test contents
  python3 "${SCRIPT_DIR}/src/extract_onionoo.py" "$mock_json" > "$output_file"
  
  local line_count=$(wc -l < "$output_file" | tr -d ' ')
  [ "$line_count" -eq 2 ]
  
  run grep "2001:db8:1234::1" "$output_file"
  [ "$status" -eq 0 ]
  
  run grep "2001:db8:1234::2" "$output_file"
  [ "$status" -eq 0 ]
  
  # Should not contain IPv4
  run grep "192.168.1.1" "$output_file"
  [ "$status" -eq 1 ]
}

@test "scrape_dan_nodes.py correctly parses IPs from HTML" {
  local mock_html="${TEST_TEMP_DIR}/dan.html"
  local output_file="${TEST_TEMP_DIR}/dan.txt"

  cat << 'EOF' > "$mock_html"
<html><body>
<p>Some text</p>
<!-- __BEGIN_TOR_NODE_LIST__ //-->
10.0.0.1|name1|9001|2|Exit|1000|0.4.7.13|contact1<br>
2001:db8::10|name2|9001|2|Guard|2000|0.4.8.5|contact2<br>
<!-- __END_TOR_NODE_LIST__ //-->
</body></html>
EOF

  run python3 "${SCRIPT_DIR}/src/scrape_dan_nodes.py" "$mock_html" "$output_file" --filter-flag Exit
  [ "$status" -eq 0 ]
  
  local line_count=$(wc -l < "$output_file" | tr -d ' ')
  [ "$line_count" -eq 1 ]
  
  run grep "10.0.0.1" "$output_file"
  [ "$status" -eq 0 ]
  
  run grep "2001:db8::10" "$output_file"
  [ "$status" -eq 1 ]
}
