"""Import smoke check: no service, model load, provider calls or personal data.

Reviewed side effects: actions loads definitions, snippets reads cue configuration,
voice reads data/words.json and starts its watchdog, claude_type starts an
idle reaper. All children exit promptly; server is never imported.
"""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
env = {**os.environ, "PYTHONPATH": str(ROOT / "engine"), "PYTHONDONTWRITEBYTECODE": "1",
       "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "DRAFTER_CAP_GB": "3"}
failed = []
for path in sorted((ROOT / "engine").glob("*.py")):
    if path.stem == "server":
        print("SKIP server: starts model and service workers", flush=True)
        continue
    result = subprocess.run([sys.executable, "-X", "importtime", "-c", f"import {path.stem}"],
                            cwd=ROOT, env=env, capture_output=True, text=True, timeout=45)
    print(f'{"FAIL" if result.returncode else "PASS"} {path.stem}', flush=True)
    # Full timing records go to stderr, suitable for a local evidence file.
    sys.stderr.write(f"\n=== {path.stem} ===\n" + result.stderr)
    if result.returncode:
        failed.append(path.stem)
print("Failed imports:", ", ".join(failed) or "none")
sys.exit(bool(failed))
