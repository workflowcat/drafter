"""The Claude gate (2026-11-01, Andrii: "build the filter that cuts unlikely words"): his own model (the running
engine, route /score) reads Claude's guess word by word; the guess is cut before the first word it finds unlikely.
Replays the saved Claude answers at the 184 pause spots (data/bench/claude-sonnet[-long].jsonl, bench/claudebench.py)
and scores each cut rule like Tab word by word. Rules are picked on one half of the messages and checked on the other.

    .venv/bin/python bench/claudegate.py            # needs Drafter's engine running; scores cached in data/bench
    .venv/bin/python bench/claudegate.py --port 8799 --models haiku,sonnet   # an engine from a checkout (round two)
"""
import json, math, statistics, sys, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import typescore as ts
from claudebench import saved, ct
ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "data/bench/claudegate-scores.jsonl"


PORT = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 8798
NAMES = sys.argv[sys.argv.index("--models") + 1].split(",") if "--models" in sys.argv else ["sonnet", "sonnet-long"]
if PORT != 8798: CACHE = CACHE.with_name(f"claudegate-scores-{PORT}.jsonl")   # an engine from a checkout: its own scores


def score(before, app, context, text):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/score", data=json.dumps(
        {"before": before, "app": app, "context": context, "text": text}).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=20))["words"]


def cut(words, tg, tm, cap):
    return ct.cut_words(words, tg, tm, cap).strip()


def metrics(rows):
    r = rows
    shown = [x for x in r if x["sug"]]
    right = [x for x in shown if x["words"] > 0]
    letters = sum(len(x["rest"]) for x in r) or 1
    return {"spots": len(r), "shown": len(shown) / len(r) * 100, "right": len(right) / max(1, len(shown)) * 100,
            "wrong_per_100": (len(shown) - len(right)) / len(r) * 100, "saved": sum(x["saved"] for x in r) / letters * 100}


if __name__ == "__main__":
    items, _ = ts.load(str(ROOT / "data/bench/qwen3-1.7b-lora.jsonl"))
    cache = {}
    if CACHE.exists():
        for l in CACHE.read_text().splitlines():
            d = json.loads(l); cache[(d["i"], d["pos"], d["text"])] = d["words"]
    runs = {}
    with open(CACHE, "a") as f:
        for name in NAMES:
            rows = [json.loads(l) for l in (ROOT / f"data/bench/claude-{name}.jsonl").read_text().splitlines() if l.strip()]
            for r in rows:
                it = items[r["i"]]; before = it["text"][: r["pos"]]
                k = (r["i"], r["pos"], r["sug"])
                if r["sug"] and k not in cache:
                    cache[k] = score(before, it.get("app", ""), it.get("context", ""), r["sug"])
                    f.write(json.dumps({"i": r["i"], "pos": r["pos"], "text": r["sug"], "words": cache[k]}, ensure_ascii=False) + "\n")
                r["scored"] = cache.get(k)
            runs[name] = rows

    def apply(rows, tg, tm, cap):
        out = []
        for r in rows:
            c = cut(r["scored"], tg, tm, cap) if r["sug"] else ""
            s, w = saved(r["rest"], c)
            out.append({"src": r["src"], "i": r["i"], "sug": c, "rest": r["rest"], "saved": s, "words": w})
        return out

    grid = [(tg, tm, cap) for tg in (0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.3) for tm in (0, 0.001, 0.005, 0.01, 0.03)
            for cap in (3, 9, 16)]
    def line(tag, m):
        return f"{tag:34} shown {m['shown']:3.0f}% | right {m['right']:3.0f}% of shown | wrong {m['wrong_per_100']:3.0f} per 100 | saved {m['saved']:4.1f}%"
    for name, rows in runs.items():
        print(f"\n== Claude {name}")
        for src in ("beeper", "claude"):
            r = [x for x in rows if x["src"] == src]
            print(line(f"{src} as is", metrics(apply(r, 0, 0, 99))))
        # pick on even messages, check on odd, and the other way round; the goal: letters saved minus 1% per wrong ghost
        def value(m): return m["saved"] - 0.01 * m["wrong_per_100"]
        for half in (0, 1):
            pick = [x for x in rows if x["i"] % 2 == half]; check = [x for x in rows if x["i"] % 2 != half]
            best = max(grid, key=lambda g: value(metrics(apply(pick, *g))))
            for src in ("beeper", "claude"):
                c = [x for x in check if x["src"] == src]
                print(line(f"{src} cut {best} (picked on {'even' if half == 0 else 'odd'})", metrics(apply(c, *best))))
        for g in ((0.01, 0.001, 9), (0.02, 0.005, 9), (0.05, 0.01, 9), (0.05, 0.01, 3), (0.1, 0.01, 9)):
            for src in ("beeper", "claude"):
                r = [x for x in rows if x["src"] == src]
                print(line(f"{src} cut {g}", metrics(apply(r, *g))))
