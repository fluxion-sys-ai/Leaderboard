#!/bin/bash

LOG="/tmp/pinchbench/1072/agent_workspace/auth.log"

echo "=== FAILED ATTEMPT COUNTS BY IP ==="
# Count "Failed password" lines per IP
grep "Failed password" "$LOG" | \
  grep -oP 'from \K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
  sort | uniq -c | sort -rn

echo ""
echo "=== UNIQUE IPs WITH >10 FAILED ATTEMPTS ==="
grep "Failed password" "$LOG" | \
  grep -oP 'from \K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
  sort | uniq -c | sort -rn | awk '$1 > 10 {print $2, $1}'

