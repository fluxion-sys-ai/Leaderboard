"""Benchmark registry: name (from benchmarks.yaml) -> Benchmark subclass.

Adding a benchmark = write the module, import it, add one line here. The CLI
never grows an if/else — it just asks the registry.
"""
from .base import Benchmark, Task
from .ifeval import IFEval
from .gsm8k import GSM8K
from .mmlu_pro import MMLUPro
from .cruxeval import CruxEval
from .jsonschema_bench import JSONSchemaBench
from .humaneval import HumanEvalPlus
from .livecodebench import LiveCodeBench
from .competition_math import AIME2026
from .zebra_logic import ZebraLogic
from .babilong import BABILong
from .bfcl import BFCL
from .writing import Writing
from .gpqa import GPQADiamond      # dormant: registered but NOT in benchmarks.yaml (gated dataset)
from .pinchbench_clawd import PinchBenchClawd
from .ruler import Ruler
from .simpleqa import SimpleQA

BENCHMARKS = {
    IFEval.name: IFEval,
    GSM8K.name: GSM8K,
    MMLUPro.name: MMLUPro,
    CruxEval.name: CruxEval,
    JSONSchemaBench.name: JSONSchemaBench,
    HumanEvalPlus.name: HumanEvalPlus,
    LiveCodeBench.name: LiveCodeBench,
    AIME2026.name: AIME2026,
    ZebraLogic.name: ZebraLogic,
    BABILong.name: BABILong,
    BFCL.name: BFCL,
    Writing.name: Writing,
    GPQADiamond.name: GPQADiamond,   # runnable once benchmarks.yaml entry is uncommented + HF token set
    PinchBenchClawd.name: PinchBenchClawd,
    Ruler.name: Ruler,
    SimpleQA.name: SimpleQA,
}


def get_benchmark(name: str, cfg: dict) -> Benchmark:
    if name not in BENCHMARKS:
        raise KeyError(f"unknown benchmark '{name}'. Known: {list(BENCHMARKS)}")
    return BENCHMARKS[name](cfg)


# Public surface of the package (Benchmark/Task are the shared base types).
__all__ = ["BENCHMARKS", "get_benchmark", "Benchmark", "Task"]
