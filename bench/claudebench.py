"""Claude on a pause against the local suggestion, on the fresh replay set (data/replay-fresh.json: his lines written
after the last retrain). Two pause spots per line (word starts at ~35% and ~70% of it); the day pack leaves those lines
out. Scored like Tab word by word: a word counts only when the next characters are exactly it.

    .venv/bin/python bench/claudebench.py [haiku sonnet] [--n 100]       # writes data/bench/claude-<model>.jsonl
"""
import json, re, statistics, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import typescore as ts, ngram, gate
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import claude_type as ct


def saved(rest, sug):
    """letters a word-by-word Tab saves, and how many words were right in a row"""
    acc, n = "", 0
    for chunk in re.findall(r"\s*\S+", sug):
        if rest.startswith(acc + chunk): acc += chunk; n += 1
        else: break
    return len(acc.strip()) and len(acc), n


def spots(items, rows):
    out = []
    for i, it in enumerate(items):
        t = it["text"]
        cand = [pos for (j, pos) in rows if j == i and pos > 0 and t[pos - 1] == " " and len(t[pos:].split()) >= 2]
        for frac in (0.35, 0.7):
            if cand:
                pos = min(cand, key=lambda p: abs(p - frac * len(t)))
                if (i, pos) not in out: out.append((i, pos))
    return out


def summary(name, res):
    for src in ("beeper", "claude"):
        r = [x for x in res if x["src"] == src]
        if not r: continue
        shown = [x for x in r if x["sug"]]
        right = [x for x in shown if x["words"] > 0]
        letters = sum(len(x["rest"]) for x in r)
        ms = [x["ms"] for x in shown] or [0]
        print(f"{name:14} {src:7} spots {len(r):3} | shown {len(shown) / len(r) * 100:3.0f}% | first word right {len(right) / max(1, len(shown)) * 100:3.0f}% of shown"
              f" | words right when right {statistics.mean([x['words'] for x in right]) if right else 0:.1f}"
              f" | letters saved {sum(x['saved'] for x in r) / letters * 100:4.1f}% of the rest | ms p50 {statistics.median(ms):.0f}")


if __name__ == "__main__":
    models = [a for a in sys.argv[1:] if not a.startswith("--") and not a.isdigit()] or ["haiku", "sonnet"]
    n = int(sys.argv[sys.argv.index("--n") + 1]) if "--n" in sys.argv else 100
    items, rows = ts.load(str(ROOT / "data/bench/qwen3-1.7b-lora.jsonl"))
    for k, r in rows.items(): r["_key"] = k
    items = items[:n]
    tag = ""
    if "--long" in sys.argv:          # longer guesses: to the end of the sentence, up to 16 words
        ct.MAX_WORDS, ct.LENGTH, tag = 16, "to the end of the sentence, up to about 15 words", "-long"
    W = ngram.Words(ngram.corpus(float((ROOT / "data/review/last-retrain").read_text())))
    X, y, keys = gate.dataset(items, {k: v for k, v in rows.items() if k[0] < n}, W)
    P = gate.held_out(items, X, y, keys)
    local = gate.policy_from(P, items, rows, W, 0.4)
    sp = spots(items, rows)
    print(f"{len(sp)} pause spots in {len(items)} lines")
    res = []
    for i, pos in sp:
        t = items[i]["text"]; before = t[:pos]
        sug, ms = local(rows[(i, pos)], before, items[i]["src"])
        s, w = saved(t[pos:], ts.clean(before, sug))
        res.append({"i": i, "pos": pos, "src": items[i]["src"], "rest": t[pos:], "sug": sug, "saved": s, "words": w, "ms": ms})
    summary("local (gate)", res)
    ct.pack(exclude=[it["text"] for it in items], fresh=True)
    for model in models:
        out = ROOT / f"data/bench/claude-{model}{tag}.jsonl"
        res = []
        with open(out, "w") as f:
            for i, pos in sp:
                it = items[i]; t = it["text"]; before = t[:pos]
                r = None
                for _ in range(2):
                    r = ct.complete(before, it.get("app", ""), "", it.get("context", ""), model=model)
                    if r: break
                    time.sleep(2)
                sug = (r or {}).get("text", "")
                s, w = saved(t[pos:], sug)
                row = {"i": i, "pos": pos, "src": it["src"], "rest": t[pos:], "sug": sug, "raw": (r or {}).get("raw"),
                       "saved": s, "words": w, "ms": (r or {}).get("ms", 0), "first_ms": (r or {}).get("first_ms", 0)}
                res.append(row); f.write(json.dumps(row, ensure_ascii=False) + "\n"); f.flush()
        summary(f"claude {model}{tag}", res)
        ct._workers.pop((model, "pause")).stop()
