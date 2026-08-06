#!/bin/bash

# Extract all IPs and categorize by source/destination role
echo "=== Extracting IP Statistics ==="

# Count total occurrences
total_ips=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' hdfs_datanode.log | wc -l)
echo "Total IP occurrences: $total_ips"

# Get unique IPs
unique_ips=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' hdfs_datanode.log | sort -u | wc -l)
echo "Unique IP addresses: $unique_ips"

# Count source IPs (src:)
src_ips=$(grep -oE 'src: /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' hdfs_datanode.log | sed 's/src: \///g' | sort | uniq -c | sort -rn | head -10)
echo ""
echo "=== Top 10 Source IPs ==="
echo "$src_ips"

# Count dest IPs (dest:)
dest_ips=$(grep -oE 'dest: /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' hdfs_datanode.log | sed 's/dest: \///g' | sort | uniq -c | sort -rn | head -10)
echo ""
echo "=== Top 10 Destination IPs ==="
echo "$dest_ips"

# Subnet analysis
subnet_count=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' hdfs_datanode.log | awk -F. '{print $1"."$2"."$3".x"}' | sort -u | wc -l)
echo ""
echo "=== Subnets in cluster: $subnet_count ==="

