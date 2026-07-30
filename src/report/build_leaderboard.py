"""Leaderboard builder — renders results/scored/ into one self-contained HTML page.

Mirrors the Fluxion Edge Leaderboard columns (Score, Agent score, Prefill,
Decode, Battery, Hardware) and layers on our richer data: every capability
dimension, click-to-expand category splits + failure reasons, and per-position
speculative-decode acceptance.

Battery + Hardware are device-specific (Fluxion's hardware axis) — we run on one
A100, so they show "—" as placeholders to keep the leaderboard shape aligned.

Reads only results/scored/*/*.json (+ results/spec/ for acceptance). Safe on
partial grids. Output: leaderboard.html at the repo root.
"""
from __future__ import annotations
import glob
import html
import json
import statistics

from ..utils.helpers import RESULTS, REPO_ROOT

# (key, short header, full label, TYPE) — grouped by capability type, in display order.
DIMENSIONS = [
    ("ifeval",          "IFEval",   "Instruction-Following (IFEval)",        "Instruction"),
    ("jsonschemabench", "Schema",   "Structured Output (JSONSchemaBench)",   "Instruction"),
    ("gsm8k",           "Math",     "Reasoning — GSM8K",                     "Reasoning"),
    ("mmlu_pro",        "Knowledge","Reasoning — MMLU-Pro",                  "Reasoning"),
    ("aime2026",        "AIME26",   "Reasoning — AIME 2026 (competition math)", "Reasoning"),
    ("zebralogic",      "Zebra",    "Reasoning — ZebraLogic (logic puzzles)","Reasoning"),
    ("gpqa_diamond",    "GPQA",     "Reasoning — GPQA Diamond (grad science)","Reasoning"),
    ("livecodebench",   "Code-Gen", "Coding — LiveCodeBench (code generation)", "Coding"),
    ("humaneval",       "HEval+",   "Coding — HumanEval+ (floor)",           "Coding"),
    ("cruxeval",        "Code-Rsn", "Coding — CruxEval (code reasoning)",    "Coding"),
    ("babilong",        "BABILong", "Long-context — BABILong (length scaling)","Long-context"),
    ("ruler",           "RULER",    "Long-context — RULER (retrieval @ 8k)", "Long-context"),
    ("writing",         "Writing",  "Writing — AlpacaEval (LLM-judge 1-10)", "Writing"),
    ("bfcl",            "BFCL",     "Agentic — BFCL (tool-use, single call)","Agentic"),
    ("pinchbench_clawd","Pinch-C",  "Agentic — PinchBench-Clawd (personal tasks, text)","Agentic"),
    ("pinchbench",      "PinchBench","Agentic — PinchBench (multi-turn agent; Fluxion's metric)","Agentic"),
    ("simpleqa",        "SimpleQA", "Factuality — SimpleQA (recall + calibration)","Factuality"),
]


# Benchmarks scored by the OFFICIAL reference package (not our in-repo scorer),
# because their scoring is too complex to reimplement comparably (code execution,
# AST match, nuanced constraint checks). Their score comes from results/scored_official/.
# The rest use our in-repo scorers (fine for easy extract-and-match scoring).
OFFICIAL_SCORERS = {"humaneval": "evalplus"}   # + ifeval, bfcl as they're wired


def load_cells() -> dict:
    """model -> {benchmark -> scored dict, plus '_spec' with acceptance if present}."""
    cells: dict = {}
    for f in glob.glob(str(RESULTS / "scored" / "*" / "*.json")):
        model, bench = f.split("/")[-2], f.split("/")[-1][:-5]
        try:
            cells.setdefault(model, {})[bench] = json.load(open(f))
        except (json.JSONDecodeError, OSError):
            pass
    # Override with official scores where we have them (keep in-repo perf/splits,
    # but the headline `score` and the ranking come from the reference package).
    for f in glob.glob(str(RESULTS / "scored_official" / "*" / "*.json")):
        model, bench = f.split("/")[-2], f.split("/")[-1][:-5]
        if bench not in OFFICIAL_SCORERS or model not in cells or bench not in cells[model]:
            continue
        try:
            off = json.load(open(f))
            cells[model][bench]["score"] = off["score"]
            cells[model][bench]["scorer"] = f"{OFFICIAL_SCORERS[bench]} (official)"
        except (json.JSONDecodeError, OSError, KeyError):
            pass
    for f in glob.glob(str(RESULTS / "spec" / "scored" / "*" / "*.json")):
        model = f.split("/")[-2]
        try:
            spec = json.load(open(f)).get("perf", {}).get("spec")
            if spec:
                cells.setdefault(model, {}).setdefault("_spec", spec)
        except (json.JSONDecodeError, OSError):
            pass
    return cells


def agent_score(row: dict) -> float | None:
    """Average = each of the 6 capability DIMENSIONS weighted EQUALLY, 0-100.

    Benchmarks are averaged WITHIN a dimension first, then the dimensions are
    averaged. So 4 Reasoning benchmarks don't out-vote the 1 Long-context one —
    every capability gets an equal say, and the weighting isn't an accident of how
    many benchmarks a dimension happens to have. (DIMENSIONS is ordered by type, so
    groupby yields one group per dimension.)
    """
    from itertools import groupby
    dim_means = []
    for _typ, group in groupby(DIMENSIONS, key=lambda d: d[3]):
        xs = [row[k]["score"] for k, *_ in group if k in row and row[k].get("score") is not None]
        if xs:
            dim_means.append(statistics.mean(xs))
    return round(100 * statistics.mean(dim_means), 1) if dim_means else None


def perf_of(row: dict) -> dict:
    """Median speed/memory across a model's cells."""
    perfs = [c["perf"] for b, c in row.items() if isinstance(c, dict) and "perf" in c]
    if not perfs:
        return {}
    med = lambda k: round(statistics.median([p[k] for p in perfs if p.get(k)]), 1) \
        if any(p.get(k) for p in perfs) else None
    return {"decode_tps": med("decode_tps"), "prefill_tps": med("prefill_tps"),
            "ttft_ms": med("ttft_ms"), "peak_vram_mb": med("peak_vram_mb"),
            "gguf_mb": perfs[0].get("gguf_mb")}


def heat(v: float | None) -> str:
    if v is None:
        return "background:transparent;color:var(--mut)"
    stops = [(0.0, (198, 74, 74)), (0.5, (214, 161, 74)), (1.0, (42, 158, 122))]
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if v <= b:
            t = (v - a) / (b - a) if b > a else 0
            rgb = tuple(round(ca[i] + t * (cb[i] - ca[i])) for i in range(3))
            break
    else:
        rgb = stops[-1][1]
    return f"background:rgba({rgb[0]},{rgb[1]},{rgb[2]},0.85);color:#0b0e13;font-weight:600"


def _cell(v):
    return f'<td class="sc" style="{heat(v)}">{v:.3f}</td>' if v is not None else \
           '<td class="sc na">·</td>'


def _num(v, suffix=""):
    return f'<td class="pf">{v}{suffix}</td>' if v is not None else '<td class="pf na">·</td>'


def _detail_panel(row: dict) -> str:
    parts = []
    for key, _sh, label, _typ in DIMENSIONS:
        c = row.get(key)
        if not c:
            continue
        sc = c.get("score")
        sc_str = f"{sc:.3f}" if sc is not None else "pending judge"
        ci = c.get("ci95")
        ci_str = ""
        if ci and sc is not None and len(ci) == 2:
            ci_str = f' <span class="mut">±{(ci[1] - ci[0]) / 2:.3f} (95%)</span>'
        scorer = c.get("scorer", "in-repo scorer")
        bits = [f'<div class="dh">{html.escape(label)} — <b>{sc_str}</b>{ci_str} '
                f'<span class="mut">(n={c.get("n","?")}, {html.escape(scorer)})</span></div>']
        cats = c.get("by_category") or c.get("by_instruction_type")
        if cats:
            def _sv(d):
                return d.get("score", d.get("acc", 0.0))
            items = sorted(cats.items(), key=lambda x: _sv(x[1]))
            chips = "".join(
                f'<span class="chip" style="{heat(_sv(d))}">{html.escape(str(cat))} {_sv(d):.2f}</span>'
                for cat, d in items)
            bits.append(f'<div class="chips">{chips}</div>')
        if c.get("failure_breakdown"):
            fb = " · ".join(f"{k}: {v}" for k, v in c["failure_breakdown"].items())
            bits.append(f'<div class="fail">✗ {html.escape(fb)}</div>')
        parts.append(f'<div class="dblock">{"".join(bits)}</div>')
    spec = row.get("_spec")
    if spec and spec.get("per_pos_acceptance"):
        pp = ", ".join(f"{x:.2f}" for x in spec["per_pos_acceptance"])
        parts.append(f'<div class="dblock"><div class="dh">Speculative decoding — '
                     f'&tau;={spec.get("tau")}, accept-rate={spec.get("accept_rate")}</div>'
                     f'<div class="pp">acc per pos = ({pp})</div></div>')
    else:
        parts.append('<div class="dblock"><div class="dh">Speculative decoding</div>'
                     '<div class="mut">per-position acceptance pending the spec-decode pass '
                     '(<code>run_benchmark.py --spec</code>)</div></div>')
    return f'<tr class="detail" hidden><td colspan="99"><div class="dwrap">{"".join(parts)}</div></td></tr>'


# Models whose runs are known-bad and must NOT pollute the board. Raw data is kept
# on disk for investigation; they're just hidden from ranking. Reason is documented.
EXCLUDED = {
    "gemma-4-12b": "broken run — scored 3x below its own 4B sibling and BELOW RANDOM on "
                   "MMLU-Pro (0.071 < 0.10); likely chat-template / arch mismatch on b9892. "
                   "Raw kept in results/; needs re-run on a newer binary.",
    "qwen3.5-9b": "deferred — thinking model, under-scores without max_tokens_mult (like "
                  "ornith); skipped this pass, pending a corrective re-run with the right cap.",
    "qwen3.5-4b": "deferred — thinking model, same reason as qwen3.5-9b.",
    "nanbeige4.2-3b": "broken — b9892 can't load it ('unknown model architecture: nanbeige'); "
                      "fail-fasted at load (0 cells). Needs a newer llama.cpp binary.",
}
# models the runner auto-aborted as broken (below-random on an MCQ cell) land here
_auto = RESULTS / "excluded.txt"
if _auto.exists():
    for name in _auto.read_text().split():
        EXCLUDED.setdefault(name.strip(), "auto-excluded: aborted as broken (below-random on a multiple-choice cell)")


def build() -> str:
    cells = {m: r for m, r in load_cells().items() if m not in EXCLUDED}
    # sort by Agent (capability composite). No blended Score — Fluxion's own blend
    # weights aren't published and 2 of its inputs (price/battery) are device-specific.
    rows = [(m, r, agent_score(r), perf_of(r)) for m, r in cells.items()]
    rows.sort(key=lambda x: x[2] if x[2] is not None else -1, reverse=True)

    from itertools import groupby
    dim_head = "".join(f'<th class="sc" title="{html.escape(lbl)}">{sh}</th>'
                       for _, sh, lbl, _t in DIMENSIONS)
    # capability columns grouped by TYPE (Instruction / Reasoning / Coding / …)
    cap_groups = "".join(f'<th colspan="{len(list(g))}">{t}</th>'
                         for t, g in groupby(DIMENSIONS, key=lambda d: d[3]))
    body = []
    for rank, (model, row, agent, p) in enumerate(rows, 1):
        spec = row.get("_spec") or {}
        body.append(
            f'<tr class="row" onclick="tog(this)">'
            f'<td class="rk">{rank}</td>'
            f'<td class="ml">{html.escape(model)}</td>'
            f'<td class="agent">{agent if agent is not None else "·"}</td>'
            + "".join(_cell(row[k]["score"] if k in row else None) for k, *_ in DIMENSIONS)
            + _num(p.get("prefill_tps")) + _num(p.get("decode_tps")) + _num(p.get("ttft_ms"), " ms")
            + _num(p.get("peak_vram_mb")) + _num(p.get("gguf_mb"))
            + '<td class="pf na" title="device-specific — Fluxion hardware axis">—</td>'   # Battery
            + '<td class="pf na" title="device-specific — Fluxion hardware axis">—</td>'   # Hardware
            + _num(spec.get("tau"))                                                        # τ (spec)
            + '<td class="exp">▾</td></tr>'
            + _detail_panel(row))

    n_cells = sum(len([b for b in r if not b.startswith("_")]) for _, r in cells.items())
    return f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Edge Intelligence Leaderboard</title><style>{CSS}</style></head><body>
<div class="wrap">
<h1>Edge Intelligence Leaderboard</h1>
<div class="sub">{len(rows)} edge models &middot; judge-free &middot; Q4_K_M GGUF on llama.cpp &middot;
{n_cells} cells &middot; click a row for category splits, failure reasons &amp; per-position acceptance</div>
<div class="scroll"><table>
<thead>
<tr class="grp"><th colspan="2"></th><th colspan="1">Headline</th>
{cap_groups}
<th colspan="5">Speed &amp; memory</th><th colspan="2">Hardware axis</th><th colspan="1">Spec</th><th></th></tr>
<tr><th>#</th><th class="ml">Model</th>
<th class="agent" title="mean of capability scores, 0-100">Average</th>{dim_head}
<th title="prompt-eval tok/s">Prefill</th><th title="generation tok/s">Decode</th>
<th title="time to first token">TTFT</th><th title="peak VRAM (MB)">VRAM</th><th title="on-disk (MB)">Size</th>
<th title="device-specific">Battery</th><th title="device-specific">Hardware</th>
<th title="accepted tokens/round (spec decode)">&tau;</th><th></th></tr></thead>
<tbody>
{chr(10).join(body)}
</tbody></table></div>
<div class="legend">
<b>Average</b> = the 6 capability dimensions weighted equally ×100 (benchmarks averaged within a dimension first, so Reasoning's 4 benchmarks don't out-vote a 1-benchmark dimension). Ranking metric. Cell shade
<span class="lg" style="{heat(0.2)}">low</span>
<span class="lg" style="{heat(0.5)}">mid</span>
<span class="lg" style="{heat(0.9)}">high</span> (not comparable across columns).
<b>Battery / Hardware</b> are device-specific (Fluxion hardware axis) — N/A on a single dev box.
<b>&tau; / per-position acceptance</b> fill in after the spec-decode pass.</div>
</div>
<script>{JS}</script></body></html>"""


CSS = """
:root{--bg:#0b0e13;--s1:#141a22;--s2:#1c2530;--tx:#e6eaf0;--mut:#8a94a6;--bd:#28313f}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);
 font:12px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.wrap{max-width:1500px;margin:0 auto;padding:30px 16px 70px}
h1{font-size:25px;margin:0 0 4px}
.sub{color:var(--mut);font-size:13px;margin-bottom:20px}
.scroll{overflow-x:auto;border:1px solid var(--bd);border-radius:10px}
table{border-collapse:separate;border-spacing:0;width:100%;font-variant-numeric:tabular-nums;white-space:nowrap}
th,td{padding:6px 6px;text-align:right;border-bottom:1px solid var(--bd)}
th{position:sticky;top:0;background:var(--s2);font-size:10.5px;font-weight:600;color:var(--mut);z-index:2}
tr.grp th{background:var(--s1);color:var(--mut);font-size:10.5px;text-transform:uppercase;
 letter-spacing:.05em;text-align:center;border-bottom:1px solid var(--bd);position:static}
th.ml,td.ml{text-align:left}
.rk{color:var(--mut)}
td.ml{font-weight:600}
.score{font-weight:800;font-size:15px;color:#8fd0a0}
.agent{font-weight:700;color:#7cc4ff}
td.sc{width:46px;border-radius:5px}
.pf{color:var(--tx)}
.na{color:var(--mut)!important;background:transparent!important;font-weight:400!important}
.row{cursor:pointer}.row:hover td{background:rgba(255,255,255,.03)}
.exp{color:var(--mut)}
.detail td{background:var(--s1);padding:0;white-space:normal}
.dwrap{padding:14px 16px;display:flex;flex-wrap:wrap;gap:16px}
.dblock{flex:1 1 340px;background:var(--s2);border:1px solid var(--bd);border-radius:9px;padding:11px 13px}
.dh{font-size:12.5px;color:var(--tx);margin-bottom:8px}
.mut{color:var(--mut)}
.chips{display:flex;flex-wrap:wrap;gap:4px}
.chip{font-size:11px;padding:2px 6px;border-radius:4px;color:#0b0e13}
.fail{margin-top:8px;font-size:12px;color:#e0857f}
.pp{font-family:ui-monospace,Menlo,monospace;font-size:12px;color:#7cc4ff;word-break:break-word}
.legend{margin-top:16px;color:var(--mut);font-size:12px;line-height:1.7}
.lg{padding:1px 7px;border-radius:4px;margin:0 2px;color:#0b0e13}
"""

JS = """
function tog(r){var d=r.nextElementSibling;if(d&&d.classList.contains('detail')){
d.hidden=!d.hidden;r.querySelector('.exp').textContent=d.hidden?'\\u25be':'\\u25b4';}}
"""


def main():
    out = REPO_ROOT / "leaderboard.html"
    out.write_text(build())
    print("wrote", out)


if __name__ == "__main__":
    main()
