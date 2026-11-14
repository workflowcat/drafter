"""LoRA on Andrii's writing, with the memory guard (the Mac froze on 2026-10-06 during a local model run).

    .venv/bin/python bench/train.py <iters> [extra mlx_lm.lora args]
Adapter goes to data/adapters/ (local only). Drafter's typing help must be paused while it runs."""
import os, runpy, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import guard
guard.start(float(os.environ.get("DRAFTER_TRAIN_CAP_GB", "6.0")))
iters = sys.argv[1] if len(sys.argv) > 1 else "20"
sys.argv = ["mlx_lm.lora", "--model", "mlx-community/Qwen3-1.7B-4bit", "--train", "--data", str(ROOT / "data/train"),
            "--adapter-path", str(ROOT / "data/adapters"), "--iters", iters, "--batch-size", "4", "--num-layers", "16",
            "--learning-rate", "1e-4", "--max-seq-length", "256", "--steps-per-report", "10",
            "--steps-per-eval", "200", "--val-batches", "20", "--save-every", "200", "--seed", "7", *sys.argv[2:]]
runpy.run_module("mlx_lm.lora", run_name="__main__")
