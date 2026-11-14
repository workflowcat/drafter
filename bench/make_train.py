"""Training set for a LoRA on Andrii's own writing (local only, data/train/): every line from the phrase memory
(Beeper messages he sent, Voice Notes takes, his prompts to Claude) and what he sent while Drafter was on, in the same
shape the engine prompts with ("[App]\\n" + text). Left out, so the tests stay fair: the 30 replay items and the fresh
set (data/replay-fresh.json, drawn again by every retrain from the lines since the last one: the rolling test set)."""
import argparse, json, random, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))
from held import Held, norm


APP_TAG = {"cc": "Claude", "codex": "Codex", "beeper": "Beeper"}


def weighted(rows, weights, seed=3):
    """Each corpus row kept round-down(weight) times, plus once more with the leftover share: weights per source."""
    rnd, out = random.Random(seed), []
    for r in rows:
        w = float(weights.get(r["src"], 0))
        out += [r] * (int(w) + (rnd.random() < w - int(w)))
    return out


def from_corpus(corpus, weights, before=None, out=None, seed=3):
    """Training lines from data/corpus.jsonl (bench/corpus.py), per-source weights, nothing dated at or after `before`
    (the held-out cut: the same prompt can sit in typed.jsonl, a take and a session file) and no held line or near-copy.
    -> counts per source of distinct lines used."""
    import corpus as C
    is_held = Held()
    rows, n = [], {}
    for r in C.load(corpus, before=before):
        t = norm(r["text"])
        if is_held(t) or len(t) < 8 or not weights.get(r["src"]): continue
        app = APP_TAG.get(r["src"]) or r.get("app") or "Claude"
        rows.append({"src": r["src"], "text": f"[{app}]\n{t}"})
        n[r["src"]] = n.get(r["src"], 0) + 1
    random.Random(seed).shuffle(rows)
    k = max(60, len(rows) // 20)
    valid, train = rows[:k], weighted(rows[k:], weights, seed)
    random.Random(seed + 1).shuffle(train)
    out = Path(out or ROOT / "data/train"); out.mkdir(parents=True, exist_ok=True)
    (out / "valid.jsonl").write_text("".join(json.dumps({"text": r["text"]}, ensure_ascii=False) + "\n" for r in valid))
    (out / "train.jsonl").write_text("".join(json.dumps({"text": r["text"]}, ensure_ascii=False) + "\n" for r in train))
    print(f"train {len(train)} (weighted), valid {k}, lines per source {n}, held out {len(is_held.texts)}")
    return n


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build the held-out training set")
    parser.add_argument("--phrases", type=Path, default=ROOT / "data/phrases.jsonl")
    parser.add_argument("--corpus", type=Path, default=None, help="data/corpus.jsonl: weighted sources instead of --phrases")
    parser.add_argument("--weights", default=None, help='JSON per source, e.g. {"typed": 2, "cc": 1}; default corpus.WEIGHTS')
    parser.add_argument("--before", type=float, default=None, help="leave out every line dated at or after (unix seconds)")
    parser.add_argument("--out", type=Path, default=None)
    a = parser.parse_args(argv)
    if a.corpus:
        import corpus as C
        from_corpus(a.corpus, json.loads(a.weights) if a.weights else C.weights(), a.before, a.out)
        return
    phrases = a.phrases
    # a held line, or the same line in another take (the fresh set keeps the first 240 letters of a long line, and
    # typed.jsonl can hold a sentence twice, one a few letters longer), or a longer text holding one
    is_held = Held()
    held = is_held.texts
    APP = {"beeper": "Beeper", "voice": "Voice Notes", "claude": "Claude", "typed": "Claude"}
    rows = []
    for l in phrases.read_text().splitlines():
        if not l.strip(): continue
        r = json.loads(l); t = norm(r["text"])
        if is_held(t) or len(t) < 8: continue
        rows.append({"text": f"[{APP.get(r['src'], 'Claude')}]\n{t}"})
    try:
        for l in (ROOT / "data/typed.jsonl").read_text().splitlines():
            t = norm(json.loads(l)["text"])
            if not is_held(t): rows.append({"text": f"[{json.loads(l).get('app') or 'Claude'}]\n{t}"})
    except FileNotFoundError:
        pass
    rows = list({r["text"]: r for r in rows}.values())
    random.Random(3).shuffle(rows)
    n = max(60, len(rows) // 20)
    out = ROOT / "data/train"; out.mkdir(exist_ok=True)
    (out / "valid.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows[:n]) + "\n")
    (out / "train.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows[n:]) + "\n")
    print(f"train {len(rows) - n}, valid {n}, held out {len(held)}")


if __name__ == "__main__":
    main()
