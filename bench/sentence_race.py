"""Race of the cloud whole-sentence pass (round "earlier", step 5): Claude Haiku through the warm `claude` worker
against Cloudflare Workers AI (Gemma 4), on the made-up set bench/sentence_set.json (Ukrainian, English, mixed, with
planted typos and layout slips). Both run at once per sentence, as in the engine. No local model, no data/ text.

Workers AI goes through `cf ai run` (the account's own `cf` sign-in; no token on a command line). Its CLI start is
measured with --dry-run and taken off, so its times are an estimate of the HTTP call.

    .venv/bin/python -B bench/sentence_race.py [--n 36] [--out bench/out/sentence-race.json]
"""
import argparse, json, statistics, subprocess, sys, tempfile, threading, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import claude_type as ct
import proofread
import sentence

CF_MODEL = sentence.CF_MODEL


def pct(xs, p):
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(p * len(xs)))]) if xs else None


def cf_body(text):
    return {"messages": [{"role": "system", "content": sentence.system()}, {"role": "user", "content": sentence.user(text)}],
            "chat_template_kwargs": {"enable_thinking": False}, "max_tokens": 400, "temperature": 0}


def cf_run(text, dry=False):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(cf_body(text), f, ensure_ascii=False)
    t0 = time.time()
    p = subprocess.run(["cf", "ai", "run", CF_MODEL, "--body", "@" + f.name, "-q"] + (["--dry-run"] if dry else []),
                       capture_output=True, text=True, timeout=60)
    ms = (time.time() - t0) * 1000
    Path(f.name).unlink(missing_ok=True)
    if dry: return ms
    return sentence.cf_text(p.stdout), ms


def score(text, raw, fix):
    found = proofread.edits(text, raw or "", keep=set()) if raw and not raw.startswith("✓") else []
    hit = wrong = 0
    for e in found:
        strip = lambda w: w.strip(proofread.EDGE)
        want = fix.get(strip(e["old"])) or fix.get(strip(e["old"]).lower())
        if want and want.lower() == strip(e["new"]).lower(): hit += 1
        else: wrong += 1
    return len(found), hit, wrong


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--out", default=str(ROOT / "bench/out/sentence-race.json"))
    a = ap.parse_args()
    rows = json.loads((ROOT / "bench/sentence_set.json").read_text())
    if a.n: rows = rows[:a.n]
    over = statistics.median(cf_run("ok", dry=True) for _ in range(5))
    print(f"cf CLI start (dry run, median of 5): {over:.0f} ms", flush=True)
    w = ct.Worker("haiku", sentence.system(), max_tokens=400)
    w.ask(sentence.user("ok, все добре."), lambda: False, wait=1.0, deadline=20.0, whole=True)   # warm, not counted
    out = []
    for i, r in enumerate(rows):
        res = {}
        def haiku():
            got = w.ask(sentence.user(r["text"]), lambda: False, wait=1.0, deadline=15.0, whole=True)
            res["haiku"] = (got[0], got[1], got[2]) if got else (None, None, None)
        def cf():
            try: raw, ms = cf_run(r["text"]); res["cf"] = (raw, max(1, ms - over), max(1, ms - over))
            except Exception as e: res["cf"] = (None, None, None); print("cf:", e, flush=True)
        ts = [threading.Thread(target=haiku), threading.Thread(target=cf)]
        for t in ts: t.start()
        for t in ts: t.join()
        row = {"lang": r["lang"], "planted": len(r["fix"])}
        for k, (raw, first, ms) in res.items():
            n, hit, wrong = score(r["text"], raw, r["fix"])
            row[k] = {"first_ms": first, "ms": ms, "edits": n, "hit": hit, "wrong": wrong, "ok": bool(raw), "raw": raw}
        hm = row["haiku"]["ms"] if row["haiku"]["ok"] else None
        cm = row["cf"]["ms"] if row["cf"]["ok"] else None
        row["winner"] = None if hm is None and cm is None else "haiku" if cm is None or (hm is not None and hm <= cm) else "cf"
        out.append(row)
        print(i, r["lang"], row["winner"], {k: (row[k]["ms"], row[k]["hit"], row[k]["wrong"]) for k in ("haiku", "cf")}, flush=True)
    w.stop()
    summary = {"n": len(out), "planted": sum(r["planted"] for r in out), "cf_cli_ms": round(over)}
    for k in ("haiku", "cf"):
        ok = [r[k] for r in out if r[k]["ok"]]
        summary[k] = {"answered": len(ok), "first_p50": pct([x["first_ms"] for x in ok], .5), "first_p95": pct([x["first_ms"] for x in ok], .95),
                      "full_p50": pct([x["ms"] for x in ok], .5), "full_p95": pct([x["ms"] for x in ok], .95),
                      "edits_per_sentence": round(sum(x["edits"] for x in ok) / max(1, len(ok)), 2),
                      "planted_fixed": sum(x["hit"] for x in ok), "own_words_changed": sum(x["wrong"] for x in ok),
                      "wins": sum(r["winner"] == k for r in out)}
    summary["win_share_haiku"] = round(summary["haiku"]["wins"] / max(1, len(out)), 2)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps({"summary": summary, "rows": out}, indent=1))
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
