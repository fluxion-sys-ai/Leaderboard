#!/bin/bash

# Total requests and errors
total=$(wc -l < nginx_access.log)
errors=$(jq -s '[.[] | select(.response | tonumber | (. >= 400 and . < 600))] | length' nginx_access.log)
echo "Total requests: $total"
echo "Total errors: $errors"
echo "Error rate: $(echo "scale=2; $errors * 100 / $total" | bc)%"

# Breakdown by status code
echo ""
echo "Error breakdown by status code:"
jq -s '
  [.[] | select(.response | tonumber | (. >= 400 and . < 600))] 
  | group_by(.response)
  | map({code: .[0], count: length})
  | sort_by(-.count)
' nginx_access.log

# 404 analysis
echo ""
echo "404 paths:"
jq -s '[.[] | select(.response == 404) | .request] | unique' nginx_access.log

# 403 analysis  
echo ""
echo "403 IPs:"
jq -s '[.[] | select(.response == 403) | .remote_ip] | unique' nginx_access.log

# Error by IP (top 10)
echo ""
echo "Top 10 IPs by error count:"
jq -s '[.[] | select(.response | tonumber | (. >= 400 and . < 600)) | .remote_ip] | group_by(.) | map({ip: .[0], count: length}) | sort_by(-.count) | .[0:10]'

# Error by path (top 10)
echo ""
echo "Top 10 paths by error count:"
jq -s '[.[] | select(.response | tonumber | (. >= 400 and . < 600)) | .request] | group_by(.) | map({path: .[0], count: length}) | sort_by(-.count) | .[0:10]'

# Temporal analysis - errors by hour
echo ""
echo "Errors by hour:"
jq -s '[.[] | select(.response | tonumber | (. >= 400 and . < 600)) | .time | split(":") | .[1] | tonumber] | group_by(.) | map({hour: .[0], count: length}) | sort_by(-.count)' nginx_access.log
