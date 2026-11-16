"""Which cloud model answers his typing helpers fastest (round "earlier", step 5 follow-up): Claude Haiku, Claude Sonnet
(the claudeModel setting) and Workers AI (Gemma 4) on the sentence pass, the proofread and the pause, each on 12 of the
made-up sentences in bench/sentence_set.json (4 Ukrainian, 4 English, 4 mixed; 12 x 3 tasks x 3 providers = 108
calls, the cost cap). Haiku and Sonnet through warm `claude` workers as the engine runs them; Workers AI through
`cf ai run` (the account's own sign-in), its CLI start taken off. No data/ text: generic prompts without his words.

    .venv/bin/python -B bench/cloud_models.py [--n 12] [--tasks sentence,proofread,pause] [--out bench/out/cloud-models.json]
"""
import argparse, json, re, statistics, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine")); sys.path.insert(0, str(ROOT / "bench"))
import claude_type as ct
import proofread
import sentence
import sentence_race as R

PAUSE = """You continue the chat message or note the user is typing (Ukrainian and English, often mixed). Reply with the rest of the current sentence only, in the user's language and words, nothing before it. At most 12 words."""


def prompts(task, text):
    """-> (system, user, the text the edits are scored on, the rest a pause should write)"""
    if task == "sentence": return sentence.system(), sentence.user(text), text, ""
    if task == "proofread": return proofread.system(), "Text:\n" + text, text, ""
    words = text.split()
    cut = max(2, len(words) // 2)
    return PAUSE, "Typed so far:\n" + " ".join(words[:cut]) + " ", "", " ".join(words[cut:])


def pick(rows, n):
    out = []
    for lang in ("uk", "en", "mix"):
        sub = [r for r in rows if r["lang"] == lang]
        sub = sorted(sub, key=lambda r: -len(r["fix"]))[: n // 3]
        out += sub
    return out


def pct(xs, p):
    xs = sorted(x for x in xs if x is not None)
    return round(xs[min(len(xs) - 1, int(p * len(xs)))]) if xs else None


def first_word(s): m = re.search(r"[\w'’ʼ-]+", s or ""); return m.group(0).casefold() if m else ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=12)
    ap.add_argument("--tasks", default="sentence,proofread,pause")
    ap.add_argument("--providers", default="haiku,sonnet,cf")
    ap.add_argument("--out", default=str(ROOT / "bench/out/cloud-models.json"))
    a = ap.parse_args()
    rows = pick(json.loads((ROOT / "bench/sentence_set.json").read_text()), a.n)
    over = statistics.median(R.cf_run("ok", dry=True) for _ in range(3)) if "cf" in a.providers else 0
    print(f"{len(rows)} sentences; cf CLI start {over:.0f} ms", flush=True)
    res = {}
    for task in a.tasks.split(","):
        for prov in a.providers.split(","):
            got = []
            w = None
            if prov != "cf":
                sys0 = prompts(task, "x")[0]
                w = ct.Worker(prov, sys0, max_tokens=400)
                w.ask("Reply with: ok", lambda: False, wait=1.0, deadline=30.0, whole=True)   # warm, not counted
            for r in rows:
                system, user, scored, rest = prompts(task, r["text"])
                if prov == "cf":
                    body = {"messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                            "chat_template_kwargs": {"enable_thinking": False}, "max_tokens": 400, "temperature": 0}
                    import subprocess, tempfile
                    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f: json.dump(body, f, ensure_ascii=False)
                    t0 = time.time()
                    try:
                        p = subprocess.run(["cf", "ai", "run", sentence.CF_MODEL, "--body", "@" + f.name, "-q"], capture_output=True, text=True, timeout=30)
                        out = p.stdout
                    except subprocess.TimeoutExpired: out = ""           # counted as not answered
                    ms = max(1, (time.time() - t0) * 1000 - over); Path(f.name).unlink(missing_ok=True)
                    raw, first = sentence.cf_text(out) if out else None, ms
                else:
                    g = w.ask(user, lambda: False, wait=2.0, deadline=20.0, whole=True)
                    raw, first, ms = (g[0], g[1], g[2]) if g else (None, None, None)
                row = {"lang": r["lang"], "ok": bool(raw), "first_ms": first if raw else None, "ms": ms if raw else None}
                if task == "pause": row["first_right"] = bool(raw) and first_word(raw) == first_word(rest)
                else: row["edits"], row["hit"], row["wrong"] = R.score(scored, raw, r["fix"]); row["planted"] = len(r["fix"])
                got.append(row)
            if w: w.stop()
            ok = [x for x in got if x["ok"]]
            s = {"answered": f"{len(ok)}/{len(got)}", "first_p50": pct([x["first_ms"] for x in ok], .5), "first_p95": pct([x["first_ms"] for x in ok], .95),
                 "full_p50": pct([x["ms"] for x in ok], .5), "full_p95": pct([x["ms"] for x in ok], .95)}
            if task == "pause": s["first_word_right"] = sum(x["first_right"] for x in ok)
            else: s.update(fixed=f"{sum(x['hit'] for x in ok)}/{sum(x['planted'] for x in got)}", own_words_changed=sum(x["wrong"] for x in ok))
            res[f"{task}/{prov}"] = {"summary": s, "rows": got}
            print(task, prov, json.dumps(s, ensure_ascii=False), flush=True)
            Path(a.out).parent.mkdir(parents=True, exist_ok=True)
            Path(a.out).write_text(json.dumps(res, indent=1, ensure_ascii=False))      # after each pair: a crash keeps the rest
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(res, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
