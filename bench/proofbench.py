"""What the proofreader would change in his own sent lines (data/typed.jsonl): each kept fix as old -> new, so false
fixes show. Lines go to Claude through his `claude` CLI, as the live chip does.

    .venv/bin/python bench/proofbench.py [n] [model]
"""
import json, random, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import proofread

n = int(sys.argv[1]) if len(sys.argv) > 1 else 60
model = sys.argv[2] if len(sys.argv) > 2 else "sonnet"
seen, lines = set(), []
for l in (ROOT / "data/typed.jsonl").read_text().splitlines():
    try: j = json.loads(l)
    except Exception: continue
    t = (j.get("text") or "").strip()
    if len(t.split()) >= 5 and t not in seen: seen.add(t); lines.append((j.get("app", ""), t))
random.seed(7)
pick = random.sample(lines, min(n, len(lines)))
uk = sum(1 for _, t in pick if any("а" <= c.lower() <= "я" or c in "іїєґ" for c in t))
ms, fixes, with_fix = [], 0, 0
for app, t in pick:
    r = proofread.check(t, app, model=model)
    if not r: print("  (no answer)"); continue
    ms.append(r["ms"])
    if r["edits"]:
        with_fix += 1; fixes += len(r["edits"])
        print(f"{app[:10]:10} " + " · ".join(f"{e['old']} -> {e['new']}" for e in r["edits"]))
ms.sort()
print(f"\n{len(pick)} lines ({uk} with Ukrainian), {with_fix} with fixes, {fixes} fixes; ms p50 {ms[len(ms)//2] if ms else 0}, p90 {ms[int(len(ms)*0.9)] if ms else 0}; {proofread.stats()}")
