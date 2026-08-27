"""Leaderboard builder — renders results/scored/ into one self-contained HTML page.

Three interactive views (tabs), light/dark, click-to-sort, size-ordered big→small:
  1. Benchmarks   — every individual score, per model.
  2. Dimensions   — individual scores grouped by dimension + per-dimension average.
  3. Averages     — flat average and dimension-weighted average.

See docs/leaderboard_design.md. Reads only results/scored/*/*.json (+ scored_official
overrides). Safe on partial grids. Output: leaderboard.html at the repo root.
"""
from __future__ import annotations
import glob
import html
import json
import re
import statistics
from itertools import groupby

from ..utils.helpers import RESULTS, REPO_ROOT

# Per-run specs: a universal block (shown up top) + per-(model,benchmark) overrides for scores
# produced under non-default settings (e.g. gpt-oss reruns at reasoning_effort=medium). Written by
# the run scripts (configs/score_specs.json); absent/empty is fine.
try:
    _SPECS = json.load(open(REPO_ROOT / "configs" / "score_specs.json"))
except Exception:
    _SPECS = {"universal": {}, "overrides": {}}
SPEC_UNIVERSAL = _SPECS.get("universal", {})
SPEC_OVERRIDES = _SPECS.get("overrides", {})   # {model: {benchmark: note}} — per-BENCH deviations

# Per-model non-universal toggles, from models.yaml — applied uniformly across a model's benches
# (one server per model). Shown on hover of ANY of that model's scores.
try:
    import yaml as _yaml
    _MODELS = {m["name"]: m for m in _yaml.safe_load(open(REPO_ROOT / "configs" / "models.yaml"))["models"]}
except Exception:
    _MODELS = {}

def _model_settings(model, key=None):
    m = _MODELS.get(model or "", {})
    tk = m.get("template_kwargs") or {}
    bits = []
    if m.get("no_think"):
        bits.append("no_think=true")
    if tk.get("reasoning_effort"):
        bits.append(f"reasoning_effort={tk['reasoning_effort']}")
    if m.get("max_tokens_mult"):
        bits.append(f"max_tokens_mult={m['max_tokens_mult']}")
    return " · ".join(bits) if bits else "model defaults (no toggles)"

def _has_override(model, key):
    return bool((SPEC_OVERRIDES.get(model or "", {}) or {}).get(key or ""))

def cell_title(model, key):
    """Full per-score settings for the hover/click: per-model toggles + any per-bench override."""
    base = _model_settings(model, key)
    override = (SPEC_OVERRIDES.get(model or "", {}) or {}).get(key or "")
    return f"{base} — {override}" if override else base

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
    ("pinchbench",      "PinchBench","Agentic — PinchBench (116-task multi-turn agent)","Agentic"),
    # Factuality/SimpleQA excluded from averages (2026-08-03) — everyone single-digit, no signal.
    # ("simpleqa",      "SimpleQA", "Factuality — SimpleQA","Factuality"),
]
DIM_TYPES = [t for t, _ in groupby(DIMENSIONS, key=lambda d: d[3])]   # ordered unique types
OFFICIAL_SCORERS = {"humaneval": "evalplus"}

# Param count (billions) for size ordering. Parsed from the name; overrides for odd ones.
SIZE_OVERRIDE = {"phi-4-mini-instruct": 3.8, "gemma-4-e4b": 4.0}


def model_size(name: str) -> float:
    if name in SIZE_OVERRIDE:
        return SIZE_OVERRIDE[name]
    m = re.findall(r"(\d+(?:\.\d+)?)b", name.lower())   # first "<n>b" token = total params
    return float(m[0]) if m else 0.0


def load_cells() -> dict:
    cells: dict = {}
    for f in glob.glob(str(RESULTS / "scored" / "*" / "*.json")):
        model, bench = f.split("/")[-2], f.split("/")[-1][:-5]
        try:
            cells.setdefault(model, {})[bench] = json.load(open(f))
        except (json.JSONDecodeError, OSError):
            pass
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
    return cells


def score_of(row: dict, key: str):
    c = row.get(key)
    return c.get("score") if c and c.get("score") is not None else None


# A SWE-bench run whose Docker eval completed almost no instances is a PIPELINE FAILURE (empty
# patches / crash), not a real 0% — showing it would be a false number. Require a minimum number
# of actually-evaluated instances before the cell displays; otherwise render blank (·, pending).
SWE_MIN_COMPLETED = 5

def swe_score_of(row: dict):
    c = row.get("swebench_lite")
    if not c or c.get("score") is None:
        return None
    completed = len((c.get("detail") or {}).get("completed_ids") or [])
    # `genuine_zero`: the run finished the full set but the MODEL produced 0 parseable patches
    # (e.g. Q4 35B-A3B emitted prose instead of the SEARCH/REPLACE edit format) — a real 0, NOT a
    # pipeline crash, so show it (with a footnote) rather than hide it behind the completed-count guard.
    if c.get("genuine_zero"):
        return c.get("score")
    # majority-vote rescore writes {score,resolved,total,selection} with resolved_ids only (no
    # completed_ids) — it's a finished, trusted score, so don't hide it behind the completed-count guard.
    if str(c.get("selection") or "").startswith("majority_vote"):
        return c.get("score")
    return c.get("score") if completed >= SWE_MIN_COMPLETED else None


def dim_avg(row: dict, typ: str):
    xs = [score_of(row, k) for k, _s, _l, t in DIMENSIONS if t == typ and score_of(row, k) is not None]
    return round(100 * statistics.mean(xs), 1) if xs else None


def flat_avg(row: dict):
    xs = [score_of(row, k) for k, *_ in DIMENSIONS if score_of(row, k) is not None]
    return round(100 * statistics.mean(xs), 1) if xs else None


def weighted_avg(row: dict):
    """Each dimension weighted equally: mean of per-dimension means ×100."""
    ds = [dim_avg(row, t) for t in DIM_TYPES]
    ds = [d for d in ds if d is not None]
    return round(statistics.mean(ds), 1) if ds else None


def heat(v):
    if v is None:
        return "background:transparent"
    # palette: warm red → amber (#D9A45E) → green (#4EC98F)
    stops = [(0.0, (194, 94, 94)), (0.5, (217, 164, 94)), (1.0, (78, 201, 143))]
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if v <= b:
            t = (v - a) / (b - a) if b > a else 0
            rgb = tuple(round(ca[i] + t * (cb[i] - ca[i])) for i in range(3))
            break
    else:
        rgb = stops[-1][1]
    return f"background:rgba({rgb[0]},{rgb[1]},{rgb[2]},.88);color:#0b0e13;font-weight:600"


def heat_rgb(v):
    """Same warm-red→amber→green palette as heat(), but returns a bare rgb() for SVG fills."""
    if v is None:
        return "var(--bd)"
    stops = [(0.0, (194, 94, 94)), (0.5, (217, 164, 94)), (1.0, (78, 201, 143))]
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if v <= b:
            t = (v - a) / (b - a) if b > a else 0
            rgb = tuple(round(ca[i] + t * (cb[i] - ca[i])) for i in range(3)); break
    else:
        rgb = stops[-1][1]
    return f"rgb({rgb[0]},{rgb[1]},{rgb[2]})"


def heat_bar(v):
    """In-cell horizontal data bar: colored fill from 0→v (heat palette), track after.
    Number is right-aligned (at the cell's edge) by the .bar CSS. v is 0..1."""
    if v is None:
        return "background:transparent"
    stops = [(0.0, (194, 94, 94)), (0.5, (217, 164, 94)), (1.0, (78, 201, 143))]
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if v <= b:
            t = (v - a) / (b - a) if b > a else 0
            rgb = tuple(round(ca[i] + t * (cb[i] - ca[i])) for i in range(3)); break
    else:
        rgb = stops[-1][1]
    pct = max(0.0, min(100.0, v * 100))
    return (f"background:linear-gradient(90deg,rgba({rgb[0]},{rgb[1]},{rgb[2]},.9) {pct:.1f}%,"
            f"var(--s2) {pct:.1f}%);color:var(--tx);font-weight:700")


def _dim_barchart(items):
    """Horizontal bar chart for a dimension/bench: items = [(name, val_0_100), ...] pre-sorted desc.
    Mirrors the table ranking so table-left / chart-right read as one unit. Hover shows exact value."""
    items = [(n, v) for n, v in items if v is not None]
    if not items:
        return "<div class='mut' style='padding:20px'>no data</div>"
    n = len(items); rowh = 15; pl = 128; barw = 150; W = pl + barw + 34; H = n * rowh + 10
    P = [f'<svg viewBox="0 0 {W} {H}" class="dimbar" preserveAspectRatio="xMinYMin meet">']
    for i, (name, v) in enumerate(items):
        y = 8 + i * rowh; nm = name if len(name) <= 20 else name[:19] + "…"
        P.append(f'<text x="{pl-5}" y="{y+3.5:.0f}" text-anchor="end" fill="var(--mut)" font-size="9">{html.escape(nm)}</text>')
        P.append(f'<rect x="{pl}" y="{y-3:.0f}" width="{barw}" height="10" rx="2" fill="var(--s2)"/>')
        P.append(f'<rect x="{pl}" y="{y-3:.0f}" width="{max(2, v/100*barw):.0f}" height="10" rx="2" fill="{heat_rgb(v/100)}"><title>{html.escape(name)}: {v:.1f}</title></rect>')
        P.append(f'<text x="{pl+barw+4}" y="{y+3.5:.0f}" fill="var(--tx)" font-size="9" font-weight="600">{v:.1f}</text>')
    P.append('</svg>')
    return "".join(P)


EXCLUDED = {
    "nanbeige4.2-3b": "broken — b9892 can't load arch 'nanbeige'.",
}
# Temporarily hidden from ALL tables/charts — contaminated grids pending a clean rerun, or scores
# that are misleading and not readily fixable. File-driven so a rerun script un-hides a model the
# instant its grid comes back clean (see configs/hidden_models.json).
try:
    HIDDEN = json.load(open(REPO_ROOT / "configs" / "hidden_models.json"))
except Exception:
    HIDDEN = {}
_auto = RESULTS / "excluded.txt"
if _auto.exists():
    for name in _auto.read_text().split():
        EXCLUDED.setdefault(name.strip(), "auto-excluded: aborted as broken (below-random MCQ cell).")

# Universal run parameters — same for EVERY model, shown once at the top.
PARAMS = ("NVIDIA A100-SXM4-40GB · Q4_K_M GGUF · llama.cpp b9892 · greedy (temp 0) · grid n_ctx 20K "
          "(fits RULER 8K + BaBILong 16K) · PinchBench n_ctx 128K · judge DeepSeek-v3.1 · "
          "reasoning models no_think (direct) · gpt-oss reasoning_effort=low (default)")

def _universal_html():
    """Universal run settings as a readable grid of labelled cards (not a run-on string)."""
    cards = "".join(
        f'<div class="uv"><span class="uvk">{html.escape(k)}</span><span class="uvv">{html.escape(str(v))}</span></div>'
        for k, v in SPEC_UNIVERSAL.items())
    return (f'<div class="specgrid"><span class="pk">universal · same for every model unless ◆</span>'
            f'<div class="uvlist">{cards}</div></div>')


def _deviations_html():
    """A footnote listing every score produced under a NON-default spec (marked ◆ in the tables)."""
    items = [f'<li><code>{html.escape(m)}</code> · <b>{html.escape(b)}</b> — {html.escape(note)}</li>'
             for m, benches in SPEC_OVERRIDES.items() for b, note in (benches or {}).items()]
    if not items:
        return ""
    return (f'<div class="devs"><span class="pk">spec deviations ◆</span>'
            f'<ul>{"".join(items)}</ul></div>')

# Model-specific caveats — a ⚑ flag on the model name + a footnote. A score being
# "understated" means the true capability is higher; the low number is a known artifact.
NOTES = {
    "gemma-2-9b-it": "8K-native context: BaBILong-16k and PinchBench overflow it → those two are context-capped, not capability.",
    "mistral-nemo-12b": "PinchBench near-zero is a tool-call PARSE failure (harness doesn't execute its tool format), not incapability — agentic score understated.",
    "glm-4-9b-0414": "PinchBench near-zero is a tool-call PARSE failure (glm-toolfix pending), not incapability — agentic score understated.",
    "qwen3-8b": "BaBILong ~0 is an empty-output extraction bug (reasoning tokens stripped, no answer parsed) — long-context understated.",
    "deepseek-r1-distill-qwen-7b": "BaBILong ~0 is an empty-output extraction bug on this reasoning model — long-context understated.",
    "gpt-oss-20b": "Agentic (bfcl 0.34, PinchBench 0.05) + long-context (babilong 0.34) UNDERSTATED: harmony puts the answer in the analysis channel but the BFCL/PinchBench harness reads only the final channel → empty finals (60%/43% empty). NOT effort-fixable — a medium-effort rerun made it WORSE (zebra 12%→51% empty). Needs a harness channel-extraction fix; grid non-agentic scores (gsm8k 0.94, HEval+ 0.87) are clean.",
    "exaone-4.5-33b": "PinchBench EXCLUDED (agentic = BFCL only): its 0.005 was a transcript-not-found harness bug — the 'exaone-4.5'→'4-5' agent-name mangling skipped all 116 tasks, not a real score. Long-context IS a genuine weakness (RULER 0.02, BaBILong 0.41): repetition-degeneration on long retrieval (verified NOT empty). Short-context strong (IFEval 0.84, GSM8K 0.97).",
}

# Third-party finetunes → the base model they're built on. Renders a ⑂ badge on the
# model name; click it to see "<model> — finetune of <base>". Official first-party
# instruct/chat releases are NOT listed here (we treat those as the base entry).
FINETUNE = {
    "tess-4-9b": "Qwen3.5-9B",
    "ornith-1.0-9b": "Qwen3.5-9B",
    "llama-xlam-2-8b-fc": "Llama-3.1-8B",
    "deepseek-r1-distill-qwen-7b": "Qwen2.5-Math-7B",
}


# ── cell renderers (data-v drives client-side sort; -1 sinks blanks) ──
def sc(v, model=None, key=None, bar=False):   # 0..1 benchmark score — click shows this score's config
    if v is None:
        return '<td class="sc na" data-v="-1">·</td>'
    spec = cell_title(model, key) if (model and key) else ""
    over = ' ◆ non-default' if (model and key and _has_override(model, key)) else ""
    attrs = (f' title="{html.escape(spec)}" data-spec="{html.escape(spec + over)}"'
             f' data-mk="{html.escape((model or "") + " · " + (key or ""))}" onclick="showSpec(this,event)"') if spec else ""
    badge = ' <sup class="specflag">◆</sup>' if over else ""
    cls, style = ("sc bar", heat_bar(v)) if bar else ("sc", heat(v))
    return f'<td class="{cls}" data-v="{v:.4f}" style="{style}"{attrs}>{v:.3f}{badge}</td>'

def av(v, cls="av", bar=False):   # 0..100 average
    if v is None:
        return f'<td class="{cls} na" data-v="-1">·</td>'
    style, cls = (heat_bar(v / 100), cls + " bar") if bar else (heat(v / 100), cls)
    return f'<td class="{cls}" data-v="{v:.2f}" style="{style}">{v:.1f}</td>'

def mlcell(name):
    flag = (f' <span class="flag" title="{html.escape(NOTES[name])}">⚑</span>'
            if name in NOTES else "")
    ft = ""
    if name in FINETUNE:
        info = f"{name} — finetune of {FINETUNE[name]}"
        ft = (f' <span class="ftbadge" title="{html.escape(info)}" data-ft="{html.escape(info)}"'
              f' onclick="showFT(this,event)">⑂</span>')
    return f'<td class="ml" data-v="{html.escape(name)}">{html.escape(name)}{flag}{ft}</td>'

def szcell(s):
    return f'<td class="sz" data-v="{s:.1f}">{s:g}B</td>'


def th_sort(short, label, cls="sc"):
    return f'<th class="{cls} so" onclick="sortT(this)" title="{html.escape(label)} — click to sort">{short}</th>'


def _rk(i):
    return f'<td class="rk">{i}</td>'

def _bench_table(rows):
    grp = "".join(f'<th colspan="{len(list(g))}">{t}</th>' for t, g in groupby(DIMENSIONS, key=lambda d: d[3]))
    sub = "".join(th_sort(sh, lbl) for _k, sh, lbl, _t in DIMENSIONS)
    body = []
    for name, row, size in rows:   # by-size browse table — NOT ranked, so no # column
        body.append("<tr>" + mlcell(name) + szcell(size)
                    + "".join(sc(score_of(row, k), name, k) for k, *_ in DIMENSIONS) + "</tr>")
    return f"""<table id="t1"><thead>
<tr class="grp"><th></th><th></th>{grp}</tr>
<tr><th class="ml so" onclick="sortT(this)">Model</th>
<th class="sz so" onclick="sortT(this)" title="params (B) — click to sort">Size</th>{sub}</tr>
</thead><tbody>{"".join(body)}</tbody></table>"""


def _single_bench_table(rows, key, short, label, tid, bar=False):
    """A standalone mini-leaderboard for ONE benchmark — only models that have it, ranked."""
    have = [(n, r, s) for n, r, s in rows if score_of(r, key) is not None]
    have.sort(key=lambda x: -score_of(x[1], key))
    body = "".join("<tr>" + _rk(i) + mlcell(n) + szcell(s) + sc(score_of(r, key), n, key, bar=bar) + "</tr>"
                   for i, (n, r, s) in enumerate(have, 1))
    return (len(have), f'<table id="{tid}"><thead><tr><th class="rk">#</th>'
            f'<th class="ml so" onclick="sortT(this)">Model</th>'
            f'<th class="sz so" onclick="sortT(this)">Size</th>{th_sort(short, label)}'
            f'</tr></thead><tbody>{body}</tbody></table>')


def _dim_tables(rows):
    """One SEPARATE table per dimension — its member benchmarks + the dimension avg,
    each defaulting to that dimension's ranking (Avg desc)."""
    out = []
    for i, t in enumerate(DIM_TYPES):
        members = [d for d in DIMENSIONS if d[3] == t]
        # Agentic: BFCL + PinchBench as SEPARATE side-by-side tables (PinchBench not on all models)
        if t == "Agentic":
            nb, bt = _single_bench_table(rows, "bfcl", "BFCL", "BFCL — tool-use, single call", "dAb", bar=False)
            npb, pt = _single_bench_table(rows, "pinchbench", "PinchBench", "PinchBench — 116-task multi-turn agent", "dAp", bar=False)
            out.append(
                f'<h3 class="dimh">Agentic<span class="mut"> · BFCL &amp; PinchBench (not every model runs PinchBench)</span></h3>'
                f'<div class="dimrow"><div class="dtab scroll"><div class="sbs-h">BFCL<span class="mut"> · {nb} models</span></div>{bt}</div>'
                f'<div class="dtab scroll"><div class="sbs-h">PinchBench<span class="mut"> · {npb} models</span></div>{pt}</div></div>')
            continue
        head = "".join(th_sort(sh, lbl) for _k, sh, lbl, _tt in members)
        ranked = sorted(rows, key=lambda r: (dim_avg(r[1], t) is not None, dim_avg(r[1], t) or -1), reverse=True)
        body = []
        for j, (name, row, size) in enumerate(ranked, 1):
            body.append("<tr>" + _rk(j) + mlcell(name) + szcell(size)
                        + "".join(sc(score_of(row, k), name, k) for k, *_ in members)
                        + av(dim_avg(row, t), "av big", bar=True) + "</tr>")
        plural = "s" if len(members) > 1 else ""
        table = (f'<table id="d{i}"><thead><tr><th class="rk">#</th>'
                 f'<th class="ml so" onclick="sortT(this)">Model</th>'
                 f'<th class="sz so" onclick="sortT(this)">Size</th>{head}'
                 f'<th class="av so" onclick="sortT(this)" title="{t} average — click to sort">Avg</th>'
                 f'</tr></thead><tbody>{"".join(body)}</tbody></table>')
        out.append(
            f'<h3 class="dimh">{t}<span class="mut"> · {len(members)} benchmark{plural} · ranked by avg</span></h3>'
            f'<div class="dimrow"><div class="dtab scroll">{table}</div></div>')
    return "".join(out)


def _avg_table(rows):
    # ranked table (by dimension-weighted avg desc) → # numbering IS meaningful here
    ranked = sorted(rows, key=lambda r: (weighted_avg(r[1]) is not None, weighted_avg(r[1]) or -1), reverse=True)
    body = []
    for i, (name, row, size) in enumerate(ranked, 1):
        body.append("<tr>" + _rk(i) + mlcell(name) + szcell(size)
                    + av(flat_avg(row), "av big") + av(weighted_avg(row), "av big") + "</tr>")
    return f"""<table id="t3"><thead><tr><th class="rk">#</th>
<th class="ml so" onclick="sortT(this)">Model</th>
<th class="sz so" onclick="sortT(this)">Size</th>
<th class="av so" onclick="sortT(this)" title="flat mean of all benchmarks — click to sort">Flat avg</th>
<th class="av so" onclick="sortT(this)" title="mean of the 7 dimension averages (each dimension equal) — click to sort">Dim-weighted</th>
</tr></thead><tbody>{"".join(body)}</tbody></table>"""


def _pareto_svg(rows):
    """Scatter: model size (x) vs weighted-avg (y); Pareto frontier (max score, min size) drawn."""
    pts = [(model_size(n), weighted_avg(rw), n) for n, rw, _s in rows if weighted_avg(rw) is not None]
    if not pts:
        return "<div class='mut'>no data yet</div>"
    W, H, pl, pr, pt, pb = 740, 430, 52, 104, 16, 46
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    xmin, xmax = 0, max(xs) + 4
    ymin, ymax = max(0, min(ys) - 6), max(ys) + 6
    X = lambda v: pl + (v - xmin) / (xmax - xmin) * (W - pl - pr)
    Y = lambda v: H - pb - (v - ymin) / (ymax - ymin) * (H - pt - pb)
    # Pareto-optimal: no other model is both <= size and >= score
    front = [p for p in pts if not any(q != p and q[0] <= p[0] and q[1] >= p[1]
                                       and (q[0] < p[0] or q[1] > p[1]) for q in pts)]
    front.sort()
    fset = set(front)
    P = []
    for v in range(int(ymin // 10 * 10), int(ymax) + 10, 10):
        if v < ymin or v > ymax: continue
        y = Y(v)
        P.append(f'<line x1="{pl}" y1="{y:.0f}" x2="{W-pr}" y2="{y:.0f}" stroke="var(--bd)" stroke-width="1"/>')
        P.append(f'<text x="{pl-8}" y="{y+3:.0f}" text-anchor="end" fill="var(--mut)" font-size="10">{v}</text>')
    for v in range(4, int(xmax), 4):
        P.append(f'<text x="{X(v):.0f}" y="{H-pb+15:.0f}" text-anchor="middle" fill="var(--mut)" font-size="10">{v}B</text>')
    # NO connecting line — a rising line reads as "bigger is better", the opposite of the edge story.
    # Orientation cue instead: up-and-left (smaller + more capable) is the goal.
    P.append(f'<text x="{pl+6}" y="{pt+14}" fill="var(--acc2)" font-size="10.5" font-weight="600">'
             f'↖ smaller + more capable = better</text>')
    for s, y_, n in pts:
        cx, cy = X(s), Y(y_)
        if (s, y_, n) in fset:
            P.append(f'<circle cx="{cx:.0f}" cy="{cy:.0f}" r="6" fill="var(--acc2)">'
                     f'<title>{html.escape(n)} — {y_:.1f} @ {s:g}B (frontier)</title></circle>')
        else:
            lbl = f'{n} — {y_:.1f} @ {s:g}B'
            # visible dot + a bigger transparent hit-circle so it's easy to hover
            P.append(f'<circle cx="{cx:.0f}" cy="{cy:.0f}" r="5" fill="var(--acc)" opacity="0.6" class="ndot"/>')
            P.append(f'<circle cx="{cx:.0f}" cy="{cy:.0f}" r="13" fill="transparent" style="cursor:pointer" '
                     f'data-lbl="{html.escape(lbl)}" onmouseover="dotIn(this)" onmouseout="dotOut()">'
                     f'<title>{html.escape(lbl)}</title></circle>')
    # frontier labels with vertical anti-collision (push down if within 12px; leader line if nudged)
    last_y = -99.0
    for s, y_, n in sorted(front, key=lambda t: Y(t[1])):
        cx, cy = X(s), Y(y_)
        ly = max(cy + 3, last_y + 12); last_y = ly
        if ly - (cy + 3) > 6:
            P.append(f'<line x1="{cx+6:.0f}" y1="{cy:.0f}" x2="{cx+9:.0f}" y2="{ly-3:.0f}" stroke="var(--mut)" stroke-width="0.6"/>')
        P.append(f'<text x="{cx+10:.0f}" y="{ly:.0f}" fill="var(--tx)" font-size="10" font-weight="600">{html.escape(n)}</text>')
    midx = (pl + W - pr) / 2; midy = (pt + H - pb) / 2
    P.append(f'<text x="{midx:.0f}" y="{H-5}" text-anchor="middle" fill="var(--mut)" font-size="11">model size (B params) →</text>')
    P.append(f'<text x="13" y="{midy:.0f}" text-anchor="middle" fill="var(--mut)" font-size="11" transform="rotate(-90 13 {midy:.0f})">capability (weighted avg) →</text>')
    return f'<svg viewBox="0 0 {W} {H}" class="chart" preserveAspectRatio="xMidYMid meet">{"".join(P)}</svg>'


def _bars_html(rows):
    """Horizontal ranked bars of the dimension-weighted average."""
    data = sorted([(n, weighted_avg(rw)) for n, rw, _s in rows if weighted_avg(rw) is not None],
                  key=lambda x: -x[1])
    out = []
    for i, (n, v) in enumerate(data, 1):
        out.append(f'<div class="bar-row" title="{html.escape(n)} — {v}"><span class="bar-rk">{i}</span>'
                   f'<span class="bar-lab">{html.escape(n)}</span>'
                   f'<div class="bar-track"><div class="bar-fill" style="width:{v:.0f}%;{heat(v/100)}"></div></div>'
                   f'<span class="bar-val">{v:.1f}</span></div>')
    return f'<div class="bars">{"".join(out)}</div>'


# PinchBench scores that ran below 128K (context-broken) — hidden from the board until redone
# at 128K. Removing the cell drops them from the PinchBench table AND the Agentic average
# (which then falls back to BFCL only), so a stale 32K score never counts.
STALE_PINCHBENCH = {"gemma-2-9b-it", "glm-4-9b-0414", "mistral-nemo-12b",
                    "qwen3-8b", "exaone-4.5-33b", "gpt-oss-20b"}   # qwen2.5-7b un-staled 2026-08-07: fresh 128K pinch 0.199 (clamp-guard verified).
# exaone added 2026-08-09: its pinch 0.005 was the transcript-not-found harness bug (agent name "exaone-4.5"→"4-5" mangling skipped all 116 tasks), not a real score.
# gpt-oss-20b added 2026-08-12: pinch 0.050 is an ARTIFACT — by_category shows ANALYSIS 0.57 (model IS capable) but 7/9 categories collapsed to exactly 0.00 (harmony/reasoning format failing to parse on those task types), not genuine inability. Agentic = BFCL only. (gemma-4-12b 0.239 + nemotron-30b 0.194 were CHECKED and KEPT — real spread across 7-8/9 categories.)


def _terminal_sample() -> list:
    """The fixed stratified-by-difficulty 24-task subset (seed 42). Empty if the file is absent."""
    try:
        return [l.strip() for l in open(REPO_ROOT / "configs" / "terminal_sample.txt") if l.strip()]
    except Exception:
        return []


def _terminal_min() -> int:
    """Min completed TerminalBench tasks before a cell is shown (hide partial runs). Matches the
    stratified sample size (configs/terminal_sample.txt) when present, else the full 80."""
    n = len(_terminal_sample())
    return n or 80


def _terminal_sample_acc(d: dict):
    """Score a TerminalBench results.json over the fixed 24-task stratified sample so EVERY model is
    compared on the same denominator. Full runs (80 tasks) are filtered down to the 24; native 24-task
    runs are unchanged (their ids == the sample). Falls back to the raw accuracy if the sample file is
    absent or the run doesn't cover all 24 sample tasks (partial → caller's _terminal_min guard hides it)."""
    samp = _terminal_sample()
    if not samp:
        return d.get("accuracy")
    resolved = set(d.get("resolved_ids", []))
    ran = resolved | set(d.get("unresolved_ids", []))
    if not set(samp).issubset(ran):        # not every sample task present → don't understate; fall back
        return d.get("accuracy")
    return sum(1 for t in samp if t in resolved) / len(samp)


# ── Frontier tab: the exact params behind each cell (click a number to inspect) ──
_FR_SAMP = {   # vendor-recommended sampling knobs, from the run scripts
    "muse":   "top_p 0.95 · top_k 64",
    "gemma":  "top_p 0.95 · top_k 64",
    "qwen27": "top_p 0.95 · top_k 20 · min_p 0 · presence_penalty 0",
    "qwen35": "top_p 0.95 · top_k 20 · min_p 0 · presence_penalty 0 (1.5 on Terminal)",
    "qwen38": "top_p 0.95 · top_k 20 · min_p 0 · presence_penalty 0",
}
_FR_FULL_SERVE = {   # full-precision serving (OpenRouter provider + quant pin)
    "muse":   "OpenRouter · bf16 (DeepInfra)",
    "gemma":  "OpenRouter · bf16 (CoreWeave/Novita)",
    "qwen27": "OpenRouter · fp8", "qwen35": "OpenRouter · fp8", "qwen38": "OpenRouter · fp8",
}
_FR_BENCH = {   # benchmark harness — same regardless of model; (label, thinking)
    "ifbench":    ("IFBench · instruction-following · rec sampling", "ON"),
    "aime2026":   ("AIME 2026 · 30 problems (competition math) · rec sampling", "ON"),
    "pinchbench": ("PinchBench · 116-task multi-turn agent · n_ctx 128K · judge DeepSeek-v3.1", "OFF (no_think — thinking zeroes agentic)"),
    "tau3":       ("τ³-bank · terminus agent · max_steps 100 · 97 tasks", "ON"),
    "terminal":   ("TerminalBench · terminus-2 agent · terminal-bench-core 0.1.1", "ON"),
    "swe":        ("SWE-bench Lite · Agentless pipeline (localize → repair → select → Docker eval)", "ON (localize/repair)"),
}
_FR_DISP = {"ifbench": "IFBench", "aime2026": "AIME26", "pinchbench": "PinchBench",
            "tau3": "τ³-bank", "terminal": "TerminalBench", "swe": "SWE-Lite"}
def _fr_spec(model_key, bench, precision):
    """Composed params HTML for one Frontier cell. Every knob is tagged REC (vendor-recommended)
    or DEF (vendor/model default) so it's explicit which values produced this score."""
    # Clean, scannable card: precision · sampling(+thinking) · timeout · task set. All values are
    # vendor-recommended (REC) — nothing custom.
    samp = _FR_SAMP.get(model_key, "")
    serve = (_FR_FULL_SERVE.get(model_key, "OpenRouter") if precision == "full" else "local A100 · Q4_K_M")
    _, think = _FR_BENCH.get(bench, (bench, "ON"))
    if bench == "swe" and model_key == "muse" and precision == "full":
        samp += " · reasoning xhigh"
    temp = "localize 0 · repair 0.8" if bench == "swe" else "1.0"
    parts = [
        f'<b>precision:</b> {precision.upper()} · {serve}',
        f'<b>sampling:</b> temp {temp} · {samp} · thinking {think} <span class="rd">REC</span>',
    ]
    _TIMEOUT = {
        "terminal":   "2× global timeout (backfill-corrected); muse = native (2× provider outage)",
        "pinchbench": "per-task 180s (up to 300s)",
        "swe":        "per-call 900s · Docker eval",
        "ifbench":    "up to 81,920 gen tokens",
        "aime2026":   "up to 81,920 gen tokens",
        "tau3":       "max 100 agent steps",
    }
    if bench in _TIMEOUT:
        parts.append(f'<b>timeout:</b> {_TIMEOUT[bench]}')
    if bench == "terminal":
        full80 = False
        if precision == "q4":
            q4dir = {"qwen38": "qwen3.8-27b-q4f", "muse": "muse-glimmer-30b-q4f",
                     "qwen27": "qwen3.6-27b-q4f", "qwen35": "qwen3.5-35b-a3b-q4f",
                     "gemma": "gemma-4-31b-q4f"}.get(model_key)
            full80 = bool(q4dir and (REPO_ROOT / "results" / "scored" / q4dir / "terminal_full.json").exists())
        parts.append('<b>task set:</b> ' + ('full 79/80 (play-zork excluded — broken container)'
                                            if full80 else '24-task stratified sample'))
    if bench == "swe":
        inst = "51 (strat51)" if precision == "q4" else "20 (strat50)"
        # Read the ACTUAL selection method recorded in this cell's score so the card always matches the
        # number shown (majority-vote vs the full repair-10 + repro-tests-40 + rerank pipeline).
        _swedir = {"qwen38": "qwen3.8-27b", "muse": "muse-glimmer-30b", "qwen27": "qwen3.6-27b",
                   "qwen35": ("qwen3.5-35b-a3b" if precision == "q4" else "qwen3.6-35b-a3b"),
                   "gemma": "gemma-4-31b"}.get(model_key, "")
        _prec = "q4f" if precision == "q4" else "full"
        _selraw = ""
        try:
            _selraw = str(json.load(open(REPO_ROOT / "results" / "scored" / f"{_swedir}-{_prec}"
                                         / "swebench_lite.json")).get("selection") or "")
        except Exception:
            pass
        _repro = "reproduction" in _selraw
        _wf = "whole-function" in _selraw or "wholefunc" in _selraw
        parts.append('<b>pipeline:</b> Agentless — 3-stage localize (file→related→line) → repair → '
                     + ('regression + reproduction-test rerank' if _repro else 'select') + ' → SWE-bench Docker eval')
        parts.append('<b>repair samples:</b> 10 / bug (1 greedy + 9 @ temp 0.8) '
                     '<span class="rd">DEF</span> — repair.py --max_samples 10')
        if _repro:
            parts.append('<b>reproduction tests:</b> 40 / bug (1 greedy + 39) '
                         '<span class="rd">DEF</span> — generate_reproduction_tests.py --max_samples 40')
            parts.append('<b>selection:</b> rerank.py --regression --reproduction (test-based, full Agentless)')
        else:
            parts.append('<b>reproduction tests:</b> not used (Agentless default = --max_samples 40)')
            parts.append('<b>selection:</b> ' + ('whole-function code-fence recovery + majority vote' if _wf
                                                 else 'majority vote over non-empty patches'))
        parts.append('<b>localize:</b> temp 0 · 1 sample set · top_n 3 files · context ±10 lines')
        parts.append('<b>max_tokens:</b> repair 1024 (non-thinking) / 32,768 (thinking) · localize ≤ 8,192')
        parts.append(f'<b>instances:</b> {inst} · eval: SWE-bench Docker harness (retry-on-error)')
    if bench == "pinchbench" and precision == "q4":
        parts.append('<span class="sp-note">~300s Q4 timeout depresses this on long-context tasks</span>')
    return '<br>'.join(parts)


def _frontier_tab() -> str:
    """Frontier tab — Muse Glimmer reproduction: full-precision (OpenRouter) vs Q4 (local),
    on the recommended-limit benches. Renders whatever is scored so far; '·' = still running."""
    allc = load_cells()
    FR = [  # (display, full-precision dir, Q4 dir, tau3 key, footnote)
        ("Muse Glimmer 30B", "muse-glimmer-30b-full", "muse-glimmer-30b-q4f", "muse",
         "Q4 runs on a newer llama.cpp build (b10433) that implements the muse-glimmer arch"),
        ("Qwen3.8-27B", "qwen3.8-27b-full", "qwen3.8-27b-q4f", "qwen38",
         "NEW (Aug 2026); full-precision = self-hosted fp8 via vLLM (not on OpenRouter)"),
        ("Qwen3.6-27B", "qwen3.6-27b-full", "qwen3.6-27b-q4f", "qwen27", ""),
        ("Qwen3.6-35B-A3B", "qwen3.6-35b-a3b-full", "qwen3.5-35b-a3b-q4f", "qwen35",
         "Q4 row uses the older 3.5-35B GGUF (no 3.6-35B GGUF yet). Q4 SWE=0: the Q4 MoE emitted prose "
         "explanations instead of the SEARCH/REPLACE edit format → 0 parseable patches (real 0, not a pipeline error)."),
        ("Gemma-4-31B", "gemma-4-31b-full", "gemma-4-31b-q4f", "gemma", ""),
    ]

    def _tau3(key):
        # Returns (score, is_bad). Prefer the CORRECTED run (97 tasks, max_steps 100,
        # full sampling+thinking) once it has enough sims; otherwise fall back to the
        # OLD wrong-param run (20 tasks, max_steps 40) — shown but FLAGGED invalid (✗).
        def rd(p):
            try:
                d = json.load(open(p))
                rs = [s.get("reward_info", {}).get("reward") for s in d.get("simulations", [])
                      if isinstance(s.get("reward_info", {}).get("reward"), (int, float))]
                return (statistics.mean(rs), len(rs)) if rs else None
            except Exception:
                return None
        new = rd(REPO_ROOT / "results" / "tau3_banking" / key / "results.json")
        if new and new[1] >= 90:                       # corrected full run complete → trust it
            return (new[0], False)
        old = rd(REPO_ROOT / "results" / "_tau3_20task40step_backup" / key / "results.json")
        if old:
            return (old[0], True)                      # wrong-param run → flag ✗
        return (None, False)

    def _terminal(key):
        # TerminalBench (terminus-2, terminal-bench-core==0.1.1) accuracy, full-precision, at the 2×
        # global timeout (backfill-corrected side-dir run). Falls back to the native run if a model has
        # no 2× data (e.g. muse — its OpenRouter provider was unavailable during the 2× run).
        rid = {"qwen38": "or2x", "qwen27": "qwen272x", "qwen35": "qwen352x", "gemma": "gemma2x"}.get(key)
        if rid:
            try:
                d = json.load(open(REPO_ROOT / "results" / "terminalbench" / f"{key}_2x_full" / rid / "results.json"))
                if (d.get("n_resolved",0)+d.get("n_unresolved",0)) >= _terminal_min():
                    return _terminal_sample_acc(d)
            except Exception:
                pass
        try:
            d = json.load(open(REPO_ROOT / "results" / "terminalbench" / key / key / "results.json"))
            if (d.get("n_resolved",0)+d.get("n_unresolved",0)) < _terminal_min(): return None  # hide partials
            return _terminal_sample_acc(d)   # score over the 24-task stratified sample (subset of the 80)
        except Exception:
            return None

    def _terminal_q4(key):
        # TerminalBench Q4-local (terminus-2 vs local llama-server) accuracy.
        # FULL-80 override: if a full-run score exists (results/scored/<q4dir>/terminal_full.json,
        # written by tb_full80_supervisor once the 24-sample + backfill are merged), show that instead
        # of the 24-sample — it's the more robust full-set number. Currently only qwen3.8 (mk qwen38).
        try:
            q4dir = {"qwen38": "qwen3.8-27b-q4f", "muse": "muse-glimmer-30b-q4f",
                     "qwen27": "qwen3.6-27b-q4f", "qwen35": "qwen3.5-35b-a3b-q4f",
                     "gemma": "gemma-4-31b-q4f"}.get(key)
            if q4dir:
                fp = REPO_ROOT / "results" / "scored" / q4dir / "terminal_full.json"
                if fp.exists():
                    return json.load(open(fp)).get("score")
        except Exception:
            pass
        # 2× global-timeout run (Q4 local) — currently only qwen3.8 (gpu2x). Prefer it over native.
        if key == "qwen38":
            try:
                d = json.load(open(REPO_ROOT / "results" / "terminalbench_q4" / "qwen38_2x24" / "gpu2x" / "results.json"))
                if (d.get("n_resolved",0)+d.get("n_unresolved",0)) >= _terminal_min():
                    return _terminal_sample_acc(d)
            except Exception:
                pass
        try:
            d = json.load(open(REPO_ROOT / "results" / "terminalbench_q4" / key / key / "results.json"))
            if (d.get("n_resolved",0)+d.get("n_unresolved",0)) < _terminal_min(): return None  # hide partials until complete
            return _terminal_sample_acc(d)   # same 24-task stratified sample as full, for consistency
        except Exception:
            return None

    def cell(v, bar=False, mk=None, spec=None):
        if v is None:
            return '<td class="sc na" data-v="-1">·</td>'
        style = heat_bar(v) if bar else heat(v)
        a = (f' data-mk="{html.escape(mk)}" data-spec="{html.escape(spec)}" onclick="showSpec(this,event)"'
             if spec else "")
        cur = ";cursor:pointer" if spec else ""
        return f'<td class="{"sc bar" if bar else "sc"}" data-v="{v:.4f}" style="{style}{cur}"{a}>{v * 100:.1f}</td>'

    def tau3_cell(res, mk=None, spec=None):
        v, bad = res
        if v is None:
            return '<td class="sc na" data-v="-1">·</td>'
        if bad:  # wrong-param run: struck-through + ✗ + tooltip, no heat-bar (it's invalid)
            return ('<td class="sc" data-v="-1" title="INVALID — ran with wrong params '
                    '(max_steps 40 not 100, only 20 of 97 tasks, missing top_k/min_p and Muse/Gemma '
                    'thinking). Corrected run in progress; this cell auto-updates when it finishes.">'
                    f'<span style="text-decoration:line-through;opacity:.5">{v * 100:.1f}</span> '
                    '<span class="flag">✗</span></td>')
        a = (f' data-mk="{html.escape(mk)}" data-spec="{html.escape(spec)}" onclick="showSpec(this,event)"'
             if spec else "")
        cur = ";cursor:pointer" if spec else ""
        return f'<td class="sc bar" data-v="{v:.4f}" style="{heat_bar(v)}{cur}"{a}>{v * 100:.1f}</td>'

    # ── Table 1: full-precision (OpenRouter). τ³-bank column TEMPORARILY HIDDEN (user request,
    #    2026-08-24 — tau3 runs are incomplete/paused). Re-add the <th>τ³-bank</th> header + the
    #    tau3_cell(...) line below to restore it. ──
    full_head = ('<tr><th class="ml">Model</th><th>IFBench</th><th>AIME 2026</th>'
                 '<th>PinchBench</th><th>Terminal-Bench</th>'
                 '<th>SWE-bench Lite</th></tr>')
    full_body = []
    for disp, full, q4, tkey, note in FR:
        cf = allc.get(full, {})
        def fc(b, v):   # full-precision cell with clickable params (bar styling unchanged from before)
            return cell(v, mk=f"{disp} · {_FR_DISP.get(b, b)} · full", spec=_fr_spec(tkey, b, "full")) if v is not None else cell(v)
        full_body.append('<tr>'
                         f'<td class="ml">{disp}</td>'
                         + fc("ifbench", score_of(cf, "ifbench")) + fc("aime2026", score_of(cf, "aime2026"))
                         + fc("pinchbench", score_of(cf, "pinchbench"))
                         # + tau3_cell(_tau3(tkey), mk=f"{disp} · τ³-bank · full", spec=_fr_spec(tkey, "tau3", "full"))  # HIDDEN
                         + fc("terminal", _terminal(tkey))
                         + fc("swe", swe_score_of(cf))   # SWE-bench Lite (Agentless, strat-50)
                         + '</tr>')

    # ── Table 2: Q4-local (A100). IFBench + AIME + PinchBench (no Q4 τ³). ──
    q4_head = ('<tr><th class="ml">Model</th><th>IFBench</th><th>AIME 2026</th><th>PinchBench</th>'
               '<th>Terminal-Bench</th><th>SWE-bench Lite</th></tr>')
    q4_body = []
    for disp, full, q4, tkey, note in FR:
        ft = f' <span class="flag" title="{html.escape(note)}">⚑</span>' if note else ''
        cq = allc.get(q4, {})
        def qc(b, v):   # Q4 cell with clickable params
            return cell(v, mk=f"{disp} · {_FR_DISP.get(b, b)} · Q4", spec=_fr_spec(tkey, b, "q4")) if v is not None else cell(v)
        q4_body.append('<tr>'
                       f'<td class="ml">{disp}{ft}</td>'
                       + qc("ifbench", score_of(cq, "ifbench")) + qc("aime2026", score_of(cq, "aime2026"))
                       # real PinchBench at RECOMMENDED params — the greedy board's numbers were
                       # temp0+no_think (NOT rec), so they're pulled; this reads the rec-params redo.
                       + qc("pinchbench", score_of(cq, "pinchbench"))
                       + qc("terminal", _terminal_q4(tkey))
                       + qc("swe", swe_score_of(cq))
                       + '</tr>')

    sub = 'font-weight:600;margin:16px 0 4px;font-size:13px'
    return (
        '<h3 class="dimh">Frontier — Muse Glimmer reproduction'
        '<span class="mut"> · vendor-recommended sampling · scores ×100 · '
        '<b>click a number to see its exact params</b></span></h3>'
        f'<div style="{sub};margin-top:6px">Full precision <span class="mut">· OpenRouter (bf16 / fp8)</span></div>'
        f'<table id="vfr-full"><thead>{full_head}</thead><tbody>{"".join(full_body)}</tbody></table>'
        f'<div style="{sub}">Q4 quantized <span class="mut">· local A100 · llama.cpp</span></div>'
        f'<table id="vfr-q4"><thead>{q4_head}</thead><tbody>{"".join(q4_body)}</tbody></table>')


def build() -> str:
    # Frontier reproductions (`*-full` = OpenRouter full/fp8, `*-q4f` = local Q4) run at
    # VENDOR-DEFAULT params and belong ONLY to the Frontier tab (which reads raw cells
    # directly). The main Benchmarks/Dimensions/Averages tabs are the EQUAL-PARAMS greedy
    # board — keep the two apart so a model isn't double-listed under two param regimes.
    cells = {m: r for m, r in load_cells().items()
             if m not in EXCLUDED and m not in HIDDEN
             and not m.endswith("-full") and not m.endswith("-q4f")}
    for m in STALE_PINCHBENCH:
        if m in cells:
            cells[m].pop("pinchbench", None)
    # default order: size DESC (big → small)
    rows = sorted(((m, r, model_size(m)) for m, r in cells.items()), key=lambda x: -x[2])
    n_cells = sum(len([b for b in r if not b.startswith("_")]) for _, r in cells.items())
    return f"""<!DOCTYPE html><html lang="en" data-theme="dark"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Edge Intelligence Leaderboard</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Sora:wght@400;600;700&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
<style>{CSS}</style></head><body>
<div class="wrap">
<header>
<div class="brand"><span class="dot"></span><h1>Edge Intelligence Leaderboard</h1></div>
<button id="tg" onclick="theme()" title="light / dark">◐</button>
</header>
<div class="meta">{len(rows)} models · {n_cells} cells · click a header to sort · a score for its config</div>
{_universal_html()}
{_deviations_html()}
<nav>
<button class="tab on" data-v="v4" onclick="tab(this)">Frontier · full vs Q4</button>
<button class="tab" data-v="v1" onclick="tab(this)">Benchmarks</button>
<button class="tab" data-v="v2" onclick="tab(this)">Dimensions</button>
<button class="tab" data-v="v3" onclick="tab(this)">Averages &amp; charts</button>
</nav>
<div id="v4" class="view on"><div class="scroll">{_frontier_tab()}</div></div>
<div id="v1" class="view"><div class="scroll">{_bench_table(rows)}</div></div>
<div id="v2" class="view">{_dim_tables(rows)}</div>
<div id="v3" class="view">
<h3 class="dimh">Capability vs size<span class="mut"> · green = best at its size</span></h3>
{_pareto_svg(rows)}
<h3 class="dimh">Ranked by dimension-weighted average</h3>
{_bars_html(rows)}
<h3 class="dimh">Averages table</h3>
<div class="scroll">{_avg_table(rows)}</div>
</div>
<div class="legend">
<span class="lg" style="{heat(0.15)}">low</span>
<span class="lg" style="{heat(0.5)}">mid</span>
<span class="lg" style="{heat(0.9)}">high</span>
<span class="mut">· shade is per-cell · · = no score</span>
</div>
</div>
<script>{JS}</script></body></html>"""


CSS = """
:root,[data-theme=dark]{--bg:#0a0d12;--s1:#12171f;--s2:#1a212b;--tx:#e8ecf2;--mut:#7e8798;--bd:#242d3a;--acc:#7CBDF2;--acc2:#4EC98F}
[data-theme=light]{--bg:#F5F7FA;--s1:#ffffff;--s2:#EEF1F6;--tx:#1b2430;--mut:#5c6675;--bd:#dbe1ea;--acc:#1B4E7A;--acc2:#17925A}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);
 font:13px/1.45 'Sora',-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:1600px;margin:0 auto;padding:28px 18px 72px}
header{display:flex;align-items:center;gap:12px}
.brand{display:flex;align-items:center;gap:10px;flex:1}
.dot{width:9px;height:9px;border-radius:50%;background:var(--acc2);box-shadow:0 0 10px var(--acc2)}
h1{font-size:22px;font-weight:700;margin:0;letter-spacing:-.01em}
#tg{background:var(--s2);color:var(--tx);border:1px solid var(--bd);border-radius:9px;width:36px;height:36px;font-size:16px;cursor:pointer}
#tg:hover{border-color:var(--acc)}
.meta{color:var(--mut);font-size:12px;margin:6px 0 18px}
.mono{font-family:'JetBrains Mono',ui-monospace,Menlo,monospace;color:var(--acc);font-size:11.5px}
nav{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:14px}
.tab{background:var(--s1);color:var(--mut);border:1px solid var(--bd);border-radius:9px;padding:8px 16px;font-family:'Sora',sans-serif;font-size:12.5px;font-weight:600;cursor:pointer}
.tab:hover{color:var(--tx)}
.tab.on{background:var(--acc);color:#0a0d12;border-color:var(--acc)}
[data-theme=light] .tab.on{color:#fff}
.view{display:none}.view.on{display:block}
.dimh{font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.08em;color:var(--acc);margin:22px 0 8px}
.dimrow{display:flex;gap:16px;align-items:flex-start;margin-bottom:8px;flex-wrap:wrap}
.dtab{flex:1 1 460px;min-width:0}
/* dimension tab: score/avg cells render as in-cell horizontal data bars (fill ∝ value, number at the edge) */
.sc.bar,.av.bar{text-align:right;font-variant-numeric:tabular-nums;text-shadow:0 1px 2px rgba(0,0,0,.6)}
.dchart{flex:1 1 340px;min-width:280px;background:var(--s1);border:1px solid var(--bd);border-radius:8px;padding:10px 8px;align-self:stretch}
.dimbar{width:100%;height:auto;display:block}
.dimh:first-child{margin-top:4px}
.scroll{overflow-x:auto;border:1px solid var(--bd);border-radius:11px;background:var(--s1)}
table{border-collapse:separate;border-spacing:0;width:auto;max-width:100%;white-space:nowrap}
th,td{padding:6px 5px;text-align:right;border-bottom:1px solid var(--bd)}
tbody tr:last-child td{border-bottom:none}
th{position:sticky;top:0;background:var(--s2);font-size:9.5px;font-weight:600;color:var(--mut);white-space:normal;line-height:1.2;
 text-transform:uppercase;letter-spacing:.04em;z-index:2}
th.so{cursor:pointer;user-select:none}th.so:hover{color:var(--acc)}
th[data-dir=desc]::after{content:" ▾";color:var(--acc)}th[data-dir=asc]::after{content:" ▴";color:var(--acc)}
tr.grp th{background:var(--s1);text-align:center;color:var(--acc2);position:static;font-size:9.5px}
th.ml,td.ml{text-align:left;width:1%;white-space:nowrap;padding-right:14px}
td{font-family:'JetBrains Mono',ui-monospace,Menlo,monospace;font-variant-numeric:tabular-nums;font-size:12px}
td.ml{font-family:'Sora',sans-serif;font-weight:600;font-size:12.5px}
td.sz{color:var(--mut);font-weight:500}
td.sc{width:38px;border-radius:5px}
td.av{font-weight:700;background:var(--s2);border-radius:5px}
td.av.big{font-size:13.5px}
.na{color:var(--mut)!important;background:transparent!important;font-weight:400!important}
tbody tr:hover td{outline:1px solid var(--acc);outline-offset:-1px}
.legend{margin-top:16px;color:var(--mut);font-size:11.5px;display:flex;align-items:center;gap:7px;flex-wrap:wrap}
.lg{padding:1px 9px;border-radius:4px;color:#0a0d12;font-weight:700;font-family:'JetBrains Mono',monospace;font-size:10.5px}
.mut{color:var(--mut);font-weight:400;text-transform:none;letter-spacing:0}
.params{font-family:'JetBrains Mono',ui-monospace,Menlo,monospace;font-size:11px;color:var(--mut);
 background:var(--s1);border:1px solid var(--bd);border-radius:8px;padding:7px 11px;margin-bottom:16px;white-space:normal}
.pk{color:var(--acc2);font-weight:700;text-transform:uppercase;letter-spacing:.06em;margin-right:8px;font-size:9.5px}
.specflag{color:var(--acc);cursor:pointer;font-size:10px;margin-left:1px;vertical-align:super}
.specgrid{margin-top:10px}
.uvlist{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}
.uv{display:flex;flex-direction:column;background:var(--s1);border:1px solid var(--bd);border-radius:7px;padding:5px 9px;min-width:118px}
.uvk{color:var(--mut);font-size:9px;text-transform:uppercase;letter-spacing:.05em;font-weight:600}
.uvv{color:var(--tx);font-size:11.5px;margin-top:2px}
.sc{cursor:pointer}
#specpop{position:absolute;z-index:60;max-width:305px;background:var(--s2);border:1px solid var(--acc);border-radius:8px;padding:8px 11px;font-size:11px;color:var(--tx);box-shadow:0 6px 22px rgba(0,0,0,.45);display:none;line-height:1.5}
#specpop .sp-h{color:var(--acc);font-weight:700;font-size:10px;margin-bottom:4px;text-transform:uppercase;letter-spacing:.05em}
#specpop .sp-src{color:var(--mut);font-size:10px;margin-bottom:5px;padding-bottom:4px;border-bottom:1px solid rgba(128,128,128,.28)}
#specpop .rd{display:inline-block;font-size:8.5px;font-weight:700;padding:0 4px;border-radius:4px;background:var(--acc);color:#fff;margin-left:3px;letter-spacing:.04em;vertical-align:middle}
#specpop .rd.df{background:var(--mut)}
.devs{margin-top:9px;font-size:11.5px;color:var(--mut)}
.devs ul{margin:5px 0 0;padding-left:2px;list-style:none}
.devs li{margin:3px 0}
.devs code{font-family:'JetBrains Mono',ui-monospace,monospace;color:var(--acc);font-size:11px}
.devs b{color:var(--tx)}
.flag{color:var(--acc2);cursor:help;font-size:11px}
.ftbadge{color:var(--acc2);cursor:pointer;font-size:11px;margin-left:3px;border:1px solid var(--acc2);border-radius:4px;padding:0 3px;line-height:1.4;opacity:.75}
.ftbadge:hover{opacity:1}
#ftpop{position:absolute;z-index:60;max-width:240px;background:var(--s2);border:1px solid var(--acc2);border-radius:8px;padding:7px 10px;font-size:11px;color:var(--tx);box-shadow:0 6px 22px rgba(0,0,0,.45);display:none;line-height:1.45}
#dotpop{position:absolute;z-index:60;max-width:200px;background:var(--s2);border:1px solid var(--acc);border-radius:7px;padding:5px 9px;font-size:11px;font-weight:600;color:var(--tx);box-shadow:0 6px 22px rgba(0,0,0,.45);display:none;white-space:nowrap;pointer-events:none}
.ndot{transition:r .08s,opacity .08s}
.notes{margin-top:12px;background:var(--s1);border:1px solid var(--bd);border-radius:9px;padding:11px 13px}
.nh{color:var(--tx);font-size:12px;font-weight:600;margin-bottom:7px}
.fn{color:var(--mut);font-size:11.5px;line-height:1.65}
.fn b{color:var(--acc);font-family:'JetBrains Mono',monospace;font-weight:600}
td.rk,th.rk{width:30px;text-align:right;color:var(--mut);font-family:'JetBrains Mono',monospace;font-weight:500;padding-right:10px}
td.rk{font-size:11px}
.sbs{display:flex;gap:16px;flex-wrap:wrap;align-items:flex-start}
.sbs-col{flex:1 1 380px;min-width:300px}
.sbs-h{font-family:'Sora',sans-serif;font-size:12.5px;font-weight:700;color:var(--tx);margin-bottom:6px}
.chart{width:100%;max-width:760px;height:auto;margin:2px 0 10px;display:block}
.bars{max-width:760px;display:flex;flex-direction:column;gap:4px;margin-bottom:8px}
.bar-row{display:flex;align-items:center;gap:9px;font-size:12px}
.bar-rk{width:20px;text-align:right;color:var(--mut);font-family:'JetBrains Mono',monospace;font-size:11px}
.bar-lab{width:158px;font-family:'Sora',sans-serif;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bar-track{flex:1;background:var(--s2);border-radius:5px;height:16px;overflow:hidden}
.bar-fill{height:100%;border-radius:5px 4px 4px 5px;min-width:2px}
.bar-val{width:38px;text-align:right;font-family:'JetBrains Mono',monospace;font-weight:700}
"""

JS = """
(function(){var s=localStorage.getItem('lb-th');
document.documentElement.dataset.theme=s||(matchMedia('(prefers-color-scheme: light)').matches?'light':'dark');})();
function theme(){var h=document.documentElement,t=h.dataset.theme==='light'?'dark':'light';
h.dataset.theme=t;localStorage.setItem('lb-th',t);}
function showSpec(td,ev){ev.stopPropagation();var p=document.getElementById('specpop');
if(!p){p=document.createElement('div');p.id='specpop';document.body.appendChild(p);}
p.innerHTML='<div class="sp-h">'+td.dataset.mk+'</div>'+td.dataset.spec;
var r=td.getBoundingClientRect();
p.style.left=Math.min(r.left+window.scrollX,window.scrollX+window.innerWidth-270)+'px';
p.style.top=(r.bottom+window.scrollY+5)+'px';p.style.display='block';}
document.addEventListener('click',function(e){var p=document.getElementById('specpop');
if(p&&!(e.target.classList&&e.target.classList.contains('sc')))p.style.display='none';});
function showFT(el,ev){ev.stopPropagation();var p=document.getElementById('ftpop');
if(!p){p=document.createElement('div');p.id='ftpop';document.body.appendChild(p);}
p.textContent=el.dataset.ft;var r=el.getBoundingClientRect();
p.style.left=Math.min(r.left+window.scrollX,window.scrollX+window.innerWidth-250)+'px';
p.style.top=(r.bottom+window.scrollY+5)+'px';p.style.display='block';}
document.addEventListener('click',function(e){var p=document.getElementById('ftpop');
if(p&&!(e.target.classList&&e.target.classList.contains('ftbadge')))p.style.display='none';});
function dotIn(el){var p=document.getElementById('dotpop');
if(!p){p=document.createElement('div');p.id='dotpop';document.body.appendChild(p);}
p.textContent=el.getAttribute('data-lbl');
var r=el.getBoundingClientRect();
p.style.left=Math.min(r.left+r.width/2+window.scrollX+8,window.scrollX+window.innerWidth-190)+'px';
p.style.top=(r.top+r.height/2+window.scrollY-10)+'px';p.style.display='block';}
function dotOut(){var p=document.getElementById('dotpop');if(p)p.style.display='none';}
function tab(b){document.querySelectorAll('.tab').forEach(x=>x.classList.remove('on'));
document.querySelectorAll('.view').forEach(x=>x.classList.remove('on'));
b.classList.add('on');document.getElementById(b.dataset.v).classList.add('on');}
function sortT(th){var tb=th.closest('table').tBodies[0],
idx=[].indexOf.call(th.parentNode.children,th),
dir=th.dataset.dir==='desc'?'asc':'desc';
th.closest('table').querySelectorAll('th').forEach(h=>h.removeAttribute('data-dir'));
th.dataset.dir=dir;
[].slice.call(tb.rows).sort(function(a,b){
var x=a.cells[idx].dataset.v,y=b.cells[idx].dataset.v,xn=parseFloat(x),yn=parseFloat(y),
c=(!isNaN(xn)&&!isNaN(yn))?xn-yn:(x<y?-1:x>y?1:0);return dir==='asc'?c:-c;})
.forEach(function(r){tb.appendChild(r);});
var n=1;[].slice.call(tb.rows).forEach(function(r){var c=r.cells[0];
if(c&&c.className.indexOf('rk')>-1){c.textContent=n++;}});}
"""


def main():
    out = REPO_ROOT / "leaderboard.html"
    out.write_text(build())
    print("wrote", out)


if __name__ == "__main__":
    main()
