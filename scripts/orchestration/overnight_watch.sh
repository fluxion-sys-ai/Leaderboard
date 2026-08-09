#!/bin/bash
# Overnight watchdog v2 — fixes the overnight bugs + adds self-recovery. Every ~15 min:
#  A) reap zombies + their hung parent run_benchmark (orphaned, != live model)  [fixes false 2-server alerts]
#  B) stall recovery: if the live model hasn't written raw in >60min, kill its server+run so the queue advances
#  C) enforce COMPLETENESS+cleanliness: re-hide any visible model missing a counted bench OR >25% empty
#     [fixes the incomplete-un-hide that put gemma-4-e4b on the board at 13/15]
#  D) rebuild + commit + push (exclude the in-write model)
#  E) health-log; server count EXCLUDES defunct (no more zombie false-alarms)
set -u
cd /home/ubuntu/edge-intelligence-benchmark
L=/tmp/overnight_watch.log
say(){ echo "[watch2] $(date -u +%T) $*" >> "$L"; }
say "=== watchdog v2 start: completeness-gate + stall-recovery + zombie-reap ==="
for i in $(seq 1 52); do
  sleep 900
  live=$(ps -eo cmd | grep '[l]lama-server' | grep -v defunct | grep -oE 'models/[a-z0-9.-]+/' | head -1 | sed 's#models/##;s#/##')

  # A) reap zombies + their orphaned hung parent (a run_benchmark whose model != live)
  for z in $(ps -eo pid,stat | awk '$2 ~ /^Z/ {print $1}'); do
    pp=$(ps -o ppid= -p "$z" 2>/dev/null | tr -d ' ')
    [ -z "$pp" ] && continue
    pcmd=$(ps -o cmd= -p "$pp" 2>/dev/null)
    pm=$(echo "$pcmd" | grep -oE 'models [a-z0-9.-]+' | awk '{print $2}')
    if echo "$pcmd" | grep -q run_benchmark && [ "$pm" != "$live" ]; then
      kill -9 "$pp" 2>/dev/null && say "reaped hung run_benchmark $pp (model=$pm)"
    fi
  done

  # B) stall recovery (>60min no raw write on the live model = stuck)
  if [ -n "$live" ]; then
    age=$(python3 -c "import glob,os,time;fs=glob.glob('results/raw/$live/*.jsonl');print(int((time.time()-max(os.path.getmtime(f) for f in fs))/60) if fs else 0)" 2>/dev/null)
    if [ "${age:-0}" -gt 60 ] 2>/dev/null; then
      pkill -f "[l]lama-server" 2>/dev/null; pkill -f "run_benchmark.py --models $live" 2>/dev/null
      say "STALL: $live no raw write ${age}min -> killed server+run (queue advances)"
    fi
  fi

  # C) enforce completeness + cleanliness (re-hide incomplete or contaminated visible models)
  rehid=$(python3 - "$live" <<'PY'
import json,os,glob,sys
live=sys.argv[1] if len(sys.argv)>1 else ''
def out(r): return str(r.get('output') or '')
HID=set(json.load(open('configs/hidden_models.json')))
KNOWN={'gpt-oss-20b','gemma-2-9b-it','exaone-4.5-33b'}
COUNTED="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl".split()
h=json.load(open('configs/hidden_models.json')); changed=[]
for d in glob.glob('results/scored/*'):
    m=os.path.basename(d)
    if m in HID or m==live: continue
    have={os.path.basename(f)[:-5] for f in glob.glob(f'{d}/*.json')}
    missing=[b for b in COUNTED if b not in have]
    dirty=False
    if m not in KNOWN:
        for b in COUNTED:
            rp=f'results/raw/{m}/{b}.jsonl'
            if not os.path.exists(rp): continue
            rows=[json.loads(l) for l in open(rp)]
            if rows and 100*sum(1 for r in rows if not out(r).strip())/len(rows)>25: dirty=True; break
    if missing or dirty:
        h[m]='watchdog re-hide: '+('incomplete(missing '+','.join(missing)+')' if missing else '')+(' contaminated' if dirty else '')
        changed.append(m)
if changed:
    json.dump(h,open('configs/hidden_models.json','w'),indent=1); print("REHIDE: "+", ".join(changed))
PY
)
  [ -n "$rehid" ] && say "$rehid"

  # C2) un-false-exclude: drop from excluded.txt any COMPLETE model with above-random MCQ (gemma-4-26b bug)
  if [ -s results/excluded.txt ]; then
    unexc=$(python3 - <<'PY'
import json,os,glob
COUNTED="ifeval jsonschemabench gsm8k aime2026 mmlu_pro zebralogic gpqa_diamond livecodebench humaneval cruxeval babilong ruler writing bfcl".split()
lines=[x.strip() for x in open('results/excluded.txt') if x.strip()]
keep=[]; freed=[]
for m in lines:
    have={os.path.basename(f)[:-5] for f in glob.glob(f'results/scored/{m}/*.json')}
    p=f'results/scored/{m}/mmlu_pro.json'
    mmlu=(json.load(open(p)).get('score') if os.path.exists(p) else 0) or 0
    if all(b in have for b in COUNTED) and mmlu>0.15: freed.append(m)   # above random -> not broken
    else: keep.append(m)
if freed:
    open('results/excluded.txt','w').write(("\n".join(keep)+"\n") if keep else "")
    print("UNEXCLUDE(false): "+", ".join(freed))
PY
)
    [ -n "$unexc" ] && say "$unexc"
  fi

  # D) rebuild + commit + push (exclude in-write model)
  python3 -m src.report.build_leaderboard >> "$L" 2>&1
  cp -f leaderboard.html docs/index.html 2>/dev/null; cp -f leaderboard.html /home/ubuntu/.openclaw/workspace/leaderboard.html 2>/dev/null
  git add configs/ src/report/build_leaderboard.py leaderboard.html docs/index.html results/scored results/raw >> "$L" 2>&1
  [ -n "$live" ] && git reset -q -- "results/scored/$live" "results/raw/$live" 2>/dev/null
  if ! git diff --cached --quiet; then
    n=$(git diff --cached --name-only|wc -l)
    git -c user.name=aliixh -c user.email=aliixhuang@gmail.com commit -q -m "watchdog: board update ($(date -u +%H:%MZ), $n files; live=$live)" >> "$L" 2>&1
    git push origin main >> "$L" 2>&1 && say "pushed $n (excl $live)" || say "push FAILED"
  fi

  # E) health — server count EXCLUDES defunct/zombies (no false alarms)
  srv=$(ps -eo stat,cmd | grep '[l]lama-server' | grep -v defunct | wc -l)
  fb=$(pgrep -f "[b]ash /tmp/fill_batch.sh"|wc -l); free=$(df --output=avail -BG /home/ubuntu|tail -1|tr -dc '0-9')
  [ "$srv" -gt 1 ] && say "ALERT: $srv REAL servers (solo-GPU broken)"
  [ "${free:-99}" -lt 15 ] && say "ALERT: only ${free}G disk"
  say "ok $i/52 · live=$live · realservers=$srv · fill_batch=$fb · disk=${free}G"
done
say "watchdog v2 done (13h)"
