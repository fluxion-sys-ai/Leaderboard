#!/usr/bin/env python3
"""Judge pass for the Writing dimension — DeepSeek-Chat-v3.1 via OpenRouter.

Rates every model's writing responses 1-10 with a strong external judge (no GPU).
Runs on the cached responses, so it's fully decoupled from generation and can be
re-run anytime (swap the judge, re-score — no regeneration).

Key is read from .openrouter_key (gitignored). Usage: python judge_writing.py
"""
import json
import math
import os
import re
import statistics
import sys
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from src.benchmarks import get_benchmark
from src.utils.helpers import read_jsonl, write_json, scored_path, raw_path, RESULTS, load_yaml, REPO_ROOT

MODEL = "deepseek/deepseek-chat-v3.1"
KEY = open(os.path.join(os.path.dirname(__file__), ".openrouter_key")).read().strip()

JUDGE_PROMPT = (
    "You are grading the quality of an AI response for WRITING quality "
    "(helpfulness, clarity, depth, correctness).\n\n"
    "Instruction:\n{instr}\n\nResponse:\n{resp}\n\n"
    "Rate the response from 1 (terrible) to 10 (excellent). "
    "Output ONLY the integer score."
)


def _rate_one(instr: str, resp: str) -> float | None:
    body = json.dumps({"model": MODEL, "temperature": 0,
                       "messages": [{"role": "user",
                                     "content": JUDGE_PROMPT.format(instr=instr, resp=resp[:4000])}],
                       "max_tokens": 8}).encode()
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=body,
                                 headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    for attempt in range(3):
        try:
            r = json.loads(urllib.request.urlopen(req, timeout=90).read())
            txt = r["choices"][0]["message"]["content"]
            m = re.findall(r"\b(10|[1-9])\b", txt)
            return int(m[-1]) / 10.0 if m else None
        except Exception:
            if attempt == 2:
                return None


def main():
    bcfg = {b["name"]: b for b in load_yaml(REPO_ROOT / "configs" / "benchmarks.yaml")["benchmarks"]}
    if "writing" not in bcfg:
        print("no writing benchmark configured"); return
    tasks = {t.task_id: t for t in get_benchmark("writing", bcfg["writing"]).load()}

    import glob
    models = [p.split("/")[-2] for p in glob.glob(str(RESULTS / "raw" / "*" / "writing.jsonl"))]
    if not models:
        print("no writing responses to judge yet"); return

    # Only judge models that (a) aren't already judged — re-judging with an LLM would drift the
    # published scores — and (b) have a COMPLETE generation, so a still-running model's partial
    # writing.jsonl waits for the next sweep instead of locking in a short-count score.
    # Each model runs a fixed SAMPLE of the writing pool (not all len(tasks)), so "complete" =
    # having as many rows as the finished models do (the max row-count seen); a model still
    # generating has fewer and is deferred to the next sweep.
    counts = {m: sum(1 for r in read_jsonl(raw_path(m, "writing")) if r.get("task_id") in tasks)
              for m in models}
    expected = max(counts.values()) if counts else 0
    def _needs_judging(model):
        sp = scored_path(model, "writing")
        if os.path.exists(sp):
            try:
                d = json.load(open(sp))
                if d.get("score") is not None and not d.get("judge_pending"):
                    return False
            except Exception:
                pass
        return counts[model] >= expected
    todo = [m for m in models if _needs_judging(m)]
    if not todo:
        print("no NEW complete writing responses to judge"); return
    print(f"judging (new + complete only): {todo}", flush=True)
    models = todo

    for model in models:
        rows = [r for r in read_jsonl(raw_path(model, "writing")) if r["task_id"] in tasks]
        with ThreadPoolExecutor(max_workers=12) as ex:      # parallelize the API calls
            ratings = list(ex.map(lambda r: _rate_one(tasks[r["task_id"]].prompt, r["output"]), rows))
        ratings = [x for x in ratings if x is not None]
        score = round(sum(ratings) / len(ratings), 4) if ratings else 0.0
        # judge score is a MEAN of 1-10 ratings -> normal-approx CI (not Wilson, which is for pass rates)
        if len(ratings) > 1:
            se = statistics.pstdev(ratings) / math.sqrt(len(ratings))
            ci95 = [round(score - 1.96 * se, 4), round(score + 1.96 * se, 4)]
        else:
            ci95 = [score, score]
        write_json(scored_path(model, "writing"),
                   {"metric": "writing_judge_1to10", "score": score, "ci95": ci95, "n": len(ratings),
                    "judge_model": MODEL, "judge_pending": False})
        print(f"judged {model}: writing={score} (n={len(ratings)})", flush=True)
    print("WRITING JUDGE DONE", flush=True)


if __name__ == "__main__":
    main()
