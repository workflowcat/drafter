"""Run one model step under the memory watchdog (engine/guard.py), in this process only.

    .venv/bin/python -B bench/weights/guarded.py <cap GB> <script.py | -m module> [args ...]
The guard exits the process when its footprint stays over the cap for 2 s or ever passes cap + 0.5 GB (the Mac froze
on 2026-10-06 during a local model run)."""
import runpy, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import guard

cap, target, rest = float(sys.argv[1]), sys.argv[2], sys.argv[3:]
guard.start(cap)
if target == "-m":
    module, rest = rest[0], rest[1:]
    sys.argv = [module, *rest]
    runpy.run_module(module, run_name="__main__", alter_sys=True)
else:
    sys.path.insert(0, str(Path(target).resolve().parent))
    sys.argv = [target, *rest]
    runpy.run_path(target, run_name="__main__")
