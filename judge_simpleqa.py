#!/usr/bin/env python3
"""Judge pass for SimpleQA (Factuality) — DeepSeek-Chat-v3.1 via OpenRouter.

Grades each cached answer into one of three buckets against the gold, the official
SimpleQA way:
    CORRECT       — matches the gold fact
    INCORRECT     — attempts an answer but it's wrong (a hallucination)
    NOT_ATTEMPTED — declines / says it doesn't know (the honest, non-hallucinating case)

Headline score = accuracy = correct / total. We ALSO report not_attempted rate, because
two models with equal accuracy differ hugely if one abstains and the other fabricates.
Objective classification (not subjective quality), so temp 0 -> reproducible. No GPU.

Runs on cached results/raw/<model>/simpleqa.jsonl. Usage: python judge_simpleqa.py
"""
import glob
import json
import os
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from src.benchmarks import get_benchmark
from src.utils.helpers import read_jsonl, write_json, scored_path, raw_path, RESULTS, load_yaml, REPO_ROOT

MODEL = "deepseek/deepseek-chat-v3.1"
KEY = open(os.path.join(os.path.dirname(__file__), ".openrouter_key")).read().strip()

GRADER_PROMPT = (
    "Grade the predicted answer to a fact-seeking question against the gold answer. "
    "Reply with EXACTLY one word:\n"
    "  CORRECT       - the prediction contains the gold answer / is factually equivalent\n"
    "  INCORRECT     - the prediction gives a different/wrong answer\n"
    "  NOT_ATTEMPTED - the prediction declines, says it doesn't know, or gives no answer\n\n"
    "Question: {q}\nGold answer: {gold}\nPredicted answer: {pred}\n\nGrade:"
)


def _grade(q: str, gold: str, pred: str) -> str | None:
    body = json.dumps({"model": MODEL, "temperature": 0, "max_tokens": 4,
                       "messages": [{"role": "user",
                                     "content": GRADER_PROMPT.format(q=q, gold=gold, pred=pred[:2000])}]}).encode()
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=body,
                                 headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    for attempt in range(3):
        try:
            r = json.loads(urllib.request.urlopen(req, timeout=90).read())
            txt = r["choices"][0]["message"]["content"].upper()
            if "NOT_ATTEMPTED" in txt or "NOT ATTEMPTED" in txt:
                return "not_attempted"
            if re.search(r"\bINCORRECT\b", txt):
                return "incorrect"
            if re.search(r"\bCORRECT\b", txt):
                return "correct"
            return None
        except Exception:
            if attempt == 2:
                return None


def main():
    bcfg = {b["name"]: b for b in load_yaml(REPO_ROOT / "configs" / "benchmarks.yaml")["benchmarks"]}
    if "simpleqa" not in bcfg:
        print("no simpleqa benchmark configured"); return
    tasks = {t.task_id: t for t in get_benchmark("simpleqa", bcfg["simpleqa"]).load()}
    models = [p.split("/")[-2] for p in glob.glob(str(RESULTS / "raw" / "*" / "simpleqa.jsonl"))]
    if not models:
        print("no simpleqa responses to judge yet"); return

    for model in models:
        rows = [r for r in read_jsonl(raw_path(model, "simpleqa")) if r["task_id"] in tasks]
        with ThreadPoolExecutor(max_workers=12) as ex:
            grades = list(ex.map(
                lambda r: _grade(tasks[r["task_id"]].prompt, tasks[r["task_id"]].meta["gold"], r["output"]),
                rows))
        grades = [g for g in grades if g is not None]
        n = len(grades)
        correct = grades.count("correct")
        not_att = grades.count("not_attempted")
        score = round(correct / n, 4) if n else 0.0
        write_json(scored_path(model, "simpleqa"), {
            "metric": "simpleqa_accuracy", "score": score, "n": n,
            "correct": correct, "incorrect": grades.count("incorrect"), "not_attempted": not_att,
            "not_attempted_rate": round(not_att / n, 4) if n else 0.0,
            "judge_model": MODEL, "judge_pending": False})
        print(f"judged {model}: simpleqa acc={score} (correct={correct}, not_attempted={not_att}, n={n})", flush=True)
    print("SIMPLEQA JUDGE DONE", flush=True)


if __name__ == "__main__":
    main()
