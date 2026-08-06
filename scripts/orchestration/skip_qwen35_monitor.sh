#!/bin/bash
# Lever 1: skip the qwen3.5 thinking models. They're LAST in the main grid's frozen
# model list. When the grid reaches qwen3.5-9b, kill its run_benchmark so the wrapper
# (newmodels_run.sh) proceeds straight to its post-steps — skipping both qwen3.5s.
# Targets ONLY the main grid's run_benchmark (matched by its --models llama-xlam args),
# never the extra-watcher's later --benchmarks run.
set -u
while ! grep -q 'model: qwen3.5-9b' /tmp/newmodels.log 2>/dev/null; do
  # bail out if the main grid already finished without reaching qwen3.5 (e.g. it crashed)
  kill -0 1812216 2>/dev/null || { echo "[skip] main watcher gone before qwen3.5 — nothing to skip"; exit 0; }
  sleep 30
done
pkill -f 'run_benchmark.py --models llama-xlam'
echo "[skip] reached qwen3.5-9b -> killed main run_benchmark; qwen3.5-9b/4b SKIPPED $(date -u +%T)" >> /tmp/newmodels.log
