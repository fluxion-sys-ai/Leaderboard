#!/bin/bash
# Auto-push daemon (~15h): every ~16 min, commit+push any COMPLETE new results so the live board
# stays current unattended. Safety: never commits the model currently loaded in llama-server (mid-write).
set -u
cd /home/aliixh/edge-intelligence-benchmark
L=/tmp/auto_push.log
say(){ echo "[auto-push] $(date -u +%T) $*" >> "$L"; }
echo "=== auto-push daemon start $(date -u) ===" > "$L"
for i in $(seq 1 56); do
  sleep 960
  # model currently being written (loaded in llama-server) — exclude from the commit
  cur=$(ps -eo cmd | grep '[l]lama-server' | grep -oE 'models/[a-z0-9.-]+/' | head -1 | sed 's#models/##;s#/##')
  git add configs/ leaderboard.html docs/index.html >> "$L" 2>&1
  git add results/scored results/raw >> "$L" 2>&1
  # unstage the in-write model (partial) if any
  [ -n "$cur" ] && git reset -q -- "results/scored/$cur" "results/raw/$cur" 2>/dev/null
  if git diff --cached --quiet; then say "nothing new (cur=$cur)"; continue; fi
  n=$(git diff --cached --name-only | wc -l)
  git -c user.name=aliixh -c user.email=aliixhuang@gmail.com commit -q -m "auto-push: board update ($(date -u +%H:%MZ), $n files; excl live=$cur)" >> "$L" 2>&1
  git push origin main >> "$L" 2>&1 && say "pushed $n files (excl $cur)" || say "push failed"
done
say "auto-push daemon done (15h elapsed)"
