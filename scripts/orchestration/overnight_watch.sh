#!/bin/bash
# Overnight watchdog (~13h): every ~18 min — AUDIT numbers, SAFE auto-hide any contamination that
# slipped onto the board, rebuild, commit+push (excl in-write model), and health-log. Detect-and-log
# for anything risky (never kills procs). Replaces the finished auto_push + adds active number-checking.
set -u
cd /home/ubuntu/edge-intelligence-benchmark
L=/tmp/overnight_watch.log
say(){ echo "[watch] $(date -u +%T) $*" >> "$L"; }
echo "=== overnight watchdog start $(date -u) ===" > "$L"
for i in $(seq 1 44); do
  sleep 1080
  cur=$(ps -eo cmd | grep '[l]lama-server' | grep -oE 'models/[a-z0-9.-]+/' | head -1 | sed 's#models/##;s#/##')

  # 1) AUDIT + safe auto-hide (visible model, cell >25% empty, not known-flagged, not in-write)
  hid=$(python3 - "$cur" <<'PY'
import json,os,glob,sys
cur=sys.argv[1] if len(sys.argv)>1 else ''
def out(r): return str(r.get('output') or '')
HID=set(json.load(open('configs/hidden_models.json')))
KNOWN={'gpt-oss-20b','gemma-2-9b-it','exaone-4.5-33b'}
GRID="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl".split()
newly=[]; alert=[]
for d in glob.glob('results/scored/*'):
    m=os.path.basename(d)
    if m in HID or m in KNOWN or m==cur: continue
    for b in GRID:
        p=f'{d}/{b}.json'; rp=f'results/raw/{m}/{b}.jsonl'
        if not os.path.exists(p): continue
        try: s=json.load(open(p)).get('score')
        except: continue
        if s is not None and not(0<=s<=1): alert.append(f"{m}/{b} OUT-OF-RANGE {s}")
        if not os.path.exists(rp): continue
        rows=[json.loads(l) for l in open(rp)]
        pe=100*sum(1 for r in rows if not out(r).strip())/len(rows) if rows else 0
        if pe>25: newly.append(m); break
if newly or alert:
    h=json.load(open('configs/hidden_models.json'))
    for m in set(newly):
        h[m]=f'auto-hidden by watchdog: contaminated cell detected'
    json.dump(h,open('configs/hidden_models.json','w'),indent=1)
    print("AUTOHIDE:"+",".join(set(newly))+" ALERT:"+";".join(alert))
PY
)
  [ -n "$hid" ] && say "$hid"

  # 2) rebuild + commit + push (exclude in-write model)
  python3 -m src.report.build_leaderboard >> "$L" 2>&1
  cp -f leaderboard.html docs/index.html 2>/dev/null
  cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
  git add configs/ src/report/build_leaderboard.py leaderboard.html docs/index.html >> "$L" 2>&1
  git add results/scored results/raw >> "$L" 2>&1
  [ -n "$cur" ] && git reset -q -- "results/scored/$cur" "results/raw/$cur" 2>/dev/null
  if ! git diff --cached --quiet; then
    n=$(git diff --cached --name-only | wc -l)
    git -c user.name=aliixh -c user.email=aliixhuang@gmail.com commit -q -m "overnight watch: board update ($(date -u +%H:%MZ), $n files; live=$cur)" >> "$L" 2>&1
    git push origin main >> "$L" 2>&1 && say "pushed $n files (excl $cur)" || say "push FAILED"
  fi

  # 3) health log (detect-only; never kills)
  srv=$(pgrep -xc llama-server); fb=$(pgrep -f "[b]ash /tmp/fill_batch.sh" | wc -l)
  free=$(df --output=avail -BG /home/ubuntu | tail -1 | tr -dc '0-9')
  [ "$srv" -gt 1 ] && say "ALERT: $srv llama-servers (solo-GPU broken?)"
  [ "${free:-99}" -lt 15 ] && say "ALERT: only ${free}G disk free"
  [ "$fb" -eq 0 ] && say "note: fill_batch not running (done, or died — check /tmp/fill_batch.log)"
  say "ok · cycle $i/44 · live=$cur · servers=$srv · fill_batch=$fb · disk=${free}G"
done
say "overnight watchdog done (13h)"
