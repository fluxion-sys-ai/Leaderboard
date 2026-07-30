#!/usr/bin/env python3
"""Print the top-N model names by dimension-weighted Average (one per line).

Used to scope expensive extra benchmarks (PinchBench, GPQA, RULER) to the actual
contenders instead of the whole matrix. Reuses build_leaderboard's scoring + the
EXCLUDED set, so it always reflects the current standings — including new models
that finished after this script was written. Usage: python scripts/top_models.py 8
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from src.report.build_leaderboard import load_cells, agent_score, EXCLUDED

n = int(sys.argv[1]) if len(sys.argv) > 1 else 8
cells = {m: r for m, r in load_cells().items() if m not in EXCLUDED}
ranked = sorted(((m, agent_score(r)) for m, r in cells.items()),
                key=lambda x: x[1] if x[1] is not None else -1, reverse=True)
for m, _ in ranked[:n]:
    print(m)
