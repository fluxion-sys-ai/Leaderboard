#!/bin/bash
LOG="/tmp/pinchbench/1072/agent_workspace/auth.log"

for ip in 183.62.140.253 187.141.143.180 103.99.0.122 112.95.230.3 5.188.10.180 185.190.58.151; do
  echo "=== IP: $ip ==="
  
  # Get all timestamps of failed attempts
  echo "--- Timestamps (first and last) ---"
  grep "Failed password.*$ip" "$LOG" | head -1 | awk '{print $1, $2, $3}'
  grep "Failed password.*$ip" "$LOG" | tail -1 | awk '{print $1, $2, $3}'
  
  # Usernames tried
  echo "--- Usernames tried ---"
  grep "Failed password.*$ip" "$LOG" | \
    grep -oP '(for (invalid user )?\K\w+)' | \
    sort | uniq -c | sort -rn
  
  echo ""
done
