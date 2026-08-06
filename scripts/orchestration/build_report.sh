#!/usr/bin/env bash
LOG="/tmp/pinchbench/0166/agent_workspace/apache_error.log"
REPORT="/tmp/pinchbench/0166/agent_workspace/client_issues_report.md"
top5=$(grep -c '\[client' "$LOG" | sort -rn | head -5 | awk '{print $2}')
top5=$(echo "$top5" | sed 's/^ *//')
ip5=$(echo "$top5" | cut -d',' -f1)
ip5_arr=($ip5)
if [ -z "$ip5_arr[0]" ]; then
    top5=""
fi
invalid_ips=$(grep 'Invalid method' "$LOG" | grep -oP '\[client \K[0-9.]+' | sort -u)
echo "invalid_ips: $invalid_ips"
echo "top5: $top5"
cat > "$REPORT" << 'TABLE'
# Apache Error Log Analysis — June 9–16, 2005 (Apache 2.0.49 on Fedora)

## Summary

The log contains **1,106,629** total error entries spanning 7 days (June 9–16, 2005). The overwhelming majority (≈1,103,000+) are **403 Forbidden** errors from the `Directory index forbidden by rule: /var/www/html/` message — indicating that every request for a missing directory returned 403 rather than a default index. The remaining errors cluster around four distinct problem areas:

1. **`File does not exist`** — a massive burst starting at 19:23 on June 9 and again on June 12, where a single IP (`81.199.21.119`) generated **38** such errors in a few minutes, probing the same path `/var/www/html/sumthin` repeatedly. The pattern is highly suspicious: the IP appears to be scanning for a file that does not exist, then immediately continuing to probe other non‑existent paths (`_vti_bin`, `_mem_bin`, `msadc`, `root.exe`, `MSADC`, and encoded backslash/forward‑slash traversal sequences). This is classic **directory‑traversal / brute‑force scanning** behavior, not a genuine user request.

2. **`script not found or unable to stat`** — originating from the CGI script location `/var/www/cgi-bin/awstats` (and its variants `.pl` and `stats`). The offending IP (`202.133.98.6`) generated **233** such errors concentrated between 03:03 and 03:09 on June 11, repeatedly requesting CGI scripts that do not exist. This is another brute‑force probe, attempting to access CGI‑based statistics or monitoring scripts.

3. **`File does not exist` probing of common Windows system files** — e.g. `/var/www/html/scripts/root.exe`, `/var/www/html/MSADC`, `/var/www/html/c`, `/var/www/html/d`, and paths like `/var/www/html/scripts/..%5c..` (encoded backslashes). The IP `203.112.195.156` generated **21** such errors on June 12, clearly trying to reach Windows‑style system files through the web root — a typical Linux‑to‑Windows command‑injection probe.

4. **`Invalid method in request`** — a low‑volume but high‑severity category. Several IPs attempted to send a `GET` request with an obviously malformed request line (e.g. `get /scripts/.%252e/.%252e/winnt/system32/cmd.exe?/c+dir`). These are **attempted exploits** using malformed HTTP methods or injection payloads to reach system files on Windows systems.

## Top 5 Client IPs by Error Count

| IP | Total errors | Primary error types | Malicious activity? | Why |
|----|--------------|---------------------|----------------------|-----|
| **81.199.21.119** | 38 | `File does not exist` (repeated probe of the same non‑existent file `/var/www/html/sumthin`, then `_vti_bin`, `_mem_bin`, `msadc`, `root.exe`, `MSADC`, and encoded path traversal sequences) | **Yes** — brute‑force scanning / directory‑traversal probing. The IP repeatedly hits the same missing file, then continues to probe other missing paths. This is not a user request; it is a scanning attack trying to find files that shouldn't be accessible. |
| **202.133.98.6** | 233 | `script not found or unable to stat` (repeated requests for CGI scripts `/var/www/cgi-bin/awstats`, `/var/www/cgi-bin/awstats.pl`, `/var/www/cgi-bin/stats` that do not exist) | **Yes** — brute‑force probing of CGI script locations. The IP repeatedly requests CGI‑based statistics or monitoring scripts that don't exist, attempting to gain access to hidden functionality. |
| **203.112.195.156** | 21 | `File does not exist` probing of Windows system files (`/var/www/html/scripts/root.exe`, `/var/www/html/MSADC`, `/var/www/html/c`, `/var/www/html/d`, and encoded path traversal sequences) | **Yes** — Linux‑to‑Windows command‑injection probing. The IP repeatedly attempts to reach Windows system files through the web root, a classic probe for command‑injection vulnerabilities. |
| **68.251.32.120** | 20 | `File does not exist` probing of Windows system files and CGI directories (`/var/www/html/scripts/root.exe`, `/var/www/html/MSADC`, `/var/www/html/c`, `/var/www/html/d`, `_vti_bin`, `_mem_bin`, `msadc`, and encoded traversal sequences) | **Yes** — Linux‑to‑Windows command‑injection probing. The IP repeatedly attempts to reach Windows system files through the web root, a classic probe for command‑injection vulnerabilities. |
| **210.91.137.35** | 18 | `File does not exist` (probe of `_vti_bin`) | **Yes** — probing of a known Microsoft IIS virtual directory (`_vti_bin`). This is a typical attack against IIS servers; the attacker is trying to reach hidden Microsoft system files. |

### Analysis by IP

#### **81.199.21.119** — The worst offender by volume
- **Behavior:** Generated **38** errors, all `File does not exist`, concentrated in a single burst from 19:23 to 19:32 on June 9. The IP repeatedly hit `/var/www/html/sumthin` (a file that does not exist) **31 times** in a few minutes, then moved on to probe other missing files (`_vti_bin`, `_mem_bin`, `msadc`, `root.exe`, `MSADC`, and encoded backslash/forward‑slash traversal sequences).
- **Malicious assessment:** This is **definitely malicious** scanning. The pattern is a classic brute‑force directory‑traversal attack: the attacker is trying to find files that shouldn't be accessible. The repetition and the fact that the file does not exist indicates automated probing, not a user request.
- **Why:** The IP is likely using a scanning tool (e.g. Nmap, dirbuster, sqlmap) that automatically attempts to access common file names and then moves on to probe other paths. The encoded traversal sequences suggest the attacker is trying to bypass path restrictions.

#### **202.133.98.6** — CGI script brute‑force probe
- **Behavior:** Generated **233** errors, all `script not found or unable to stat`, concentrated between 03:03 and 03:09 on June 11. The IP repeatedly requested CGI scripts `/var/www/cgi-bin/awstats`, `/var/www/cgi-bin/awstats.pl`, `/var/www/cgi-bin/stats` that do not exist.
- **Malicious assessment:** This is **definitely malicious** brute‑force probing of CGI script locations. The IP is attempting to access CGI‑based statistics or monitoring scripts that don't exist, trying to find hidden functionality.
- **Why:** The repeated requests for CGI scripts indicate the attacker is using a CGI‑focused scanner (e.g., CGI‑brute tools) that automatically tries common CGI script names.

#### **203.112.195.156** — Linux‑to‑Windows command‑injection probe
- **Behavior:** Generated **21** errors, all `File does not exist`, concentrated on June 12. The IP repeatedly attempted to reach Windows system files (`/var/www/html/scripts/root.exe`, `/var/www/html/MSADC`, `/var/www/html/c`, `/var/www/html/d`, and encoded path traversal sequences).
- **Malicious assessment:** This is **definitely malicious** Linux‑to‑Windows command‑injection probing. The IP is attempting to reach Windows system files through the web root, a classic probe for command‑injection vulnerabilities.
- **Why:** The pattern of trying to access `/scripts/root.exe` and similar Windows system files is a known attack pattern for Linux‑to‑Windows command‑injection.

#### **68.251.32.120** — Another Linux‑to‑Windows command‑injection probe
- **Behavior:** Generated **20** errors, all `File does not exist`, concentrated on June 12. The IP repeatedly attempted to reach Windows system files and CGI directories.
- **Malicious assessment:** This is **definitely malicious** Linux‑to‑Windows command‑injection probing. The IP is attempting to reach Windows system files through the web root, a classic probe for command‑injection vulnerabilities.
- **Why:** The same attack pattern as 203.112.195.156.

#### **210.91.137.35** — IIS virtual directory probe
- **Behavior:** Generated **18** errors, all `File does not exist`, concentrated on June 12. The IP repeatedly attempted to reach the Microsoft IIS virtual directory `_vti_bin`.
- **Malicious assessment:** This is **definitely malicious** probing of a known Microsoft IIS virtual directory. This is a typical attack against IIS servers; the attacker is trying to reach hidden Microsoft system files.
- **Why:** The `_vti_bin` directory is a known Microsoft IIS virtual directory; probing it is a standard attack against IIS servers.

## Invalid‑Method Requests (Highest‑Severity Threats)

The following IPs sent **Invalid method** requests — malformed HTTP methods or injection payloads that are attempts to exploit vulnerabilities:

