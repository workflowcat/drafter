"""Cloud whole-sentence pass (round "earlier", step 5, an experiment; 16 November 2026). When he ends a sentence (a full
stop, ! ? or …), or rests after 6+ words, the app sends the message so far and where the last sentence starts; only that
sentence goes out, for minimal edits: typos, layout slips, spacing, typography. His slang, his mix of languages and his
case stay. Two providers race and the first good answer wins: Claude in his `claudeModel` (Sonnet by default; Haiku
when it fails) through a warm `claude` worker (engine/claude_type.py) and, when a Workers AI key is set, Gemma 4 on Cloudflare Workers AI. The edits go through the
same filter as the proofread (engine/proofread.py `edits`: one word for one word, a few letters apart, the other
layout, a split or joined word), and the app shows the same "Fix N" chip; Tab applies it.

What leaves the Mac: that one sentence and the app name, only with `claudeTyping` and `sentenceProof` on and online
(engine/cloud.py owner "sentence", server.claude_on). Workers AI also needs DRAFTER_CF_AI_TOKEN and
DRAFTER_CF_ACCOUNT in the engine's environment (from 1Password, never in a file in git); without them only Haiku runs.
"""
import json, os, re, sys, threading, time, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import local

CF_MODEL = "@cf/google/gemma-4-26b-a4b-it"
MIN_WORDS = 6            # a rest counts as a sentence end after this many words
MAX_CHARS = 400

SYSTEM = """You correct one sentence {name} just typed in a chat or note (Ukrainian and English, often mixed).

Make minimal edits only: typos (missing, doubled, swapped letters), a word typed in the wrong keyboard layout (ghbdsn = привіт), a missing apostrophe in Ukrainian, two words run together or one word split, a space before a comma or a missing space after it.
Keep everything else exactly: his words, slang and surzhyk (шо, тіки, щас, ок, норм, плз), his mix of languages, lowercase starts, names, links, code, emoji, numbers, his punctuation. Never rephrase, never add or remove words, never translate, never change Ukrainian to Russian.

Reply with the corrected sentence only. If nothing needs fixing, reply with exactly: ✓"""


def system(): return SYSTEM.replace("{name}", local.name())


def user(text, app=""): return (f"App: {app}\n" if app else "") + "Sentence:\n" + text


END = re.compile(r"[.!?…]+[\"'»”)]*\s*$")
SPLIT = re.compile(r"(?<=[.!?…])[\"'»”)]*\s+")


def last(text, rested=False):
    """-> (start, sentence) of the sentence that just ended, or None. A sentence ends at . ! ? … (spaces after it may
    follow), or, when he `rested`, after MIN_WORDS words without one."""
    t = text.rstrip()
    if not t: return None
    ended = bool(END.search(t))
    if not ended and not rested: return None
    body = t[:END.search(t).start()] if ended else t
    cuts = [m.end() for m in SPLIT.finditer(body)]
    start = max([0] + [c for c in cuts if c <= len(body)])
    start = max(start, t.rfind("\n") + 1)
    s = t[start:]
    if not ended and len(s.split()) < MIN_WORDS: return None
    if len(s.split()) < 3 or len(s) > MAX_CHARS: return None
    return start, s


def cf_text(out):
    """The answer text from a Workers AI reply (chat form or the older `response` form)."""
    try: d = json.loads(out) if isinstance(out, str) else out
    except ValueError: return None
    if isinstance(d, dict) and "result" in d and isinstance(d["result"], dict): d = d["result"]
    if not isinstance(d, dict): return None
    if d.get("choices"):
        m = d["choices"][0].get("message") or {}
        return (m.get("content") or "").strip() or None
    r = d.get("response")
    return r.strip() if isinstance(r, str) and r.strip() else None


_said = {"no_cf": False}


def cf_ready(env=None):
    env = os.environ if env is None else env
    return bool(env.get("DRAFTER_CF_AI_TOKEN") and env.get("DRAFTER_CF_ACCOUNT"))


def ask_cf(text, app="", timeout=6.0, env=None):
    """-> (raw, first_ms, ms) from Workers AI, or None. The key is read from the environment, never logged."""
    env = os.environ if env is None else env
    if not cf_ready(env):
        if not _said["no_cf"]:           # logged once: Haiku alone runs
            _said["no_cf"] = True; print("sentence: no Workers AI key (DRAFTER_CF_AI_TOKEN, DRAFTER_CF_ACCOUNT): Haiku only", flush=True)
        return None
    body = {"messages": [{"role": "system", "content": system()}, {"role": "user", "content": user(text, app)}],
            "chat_template_kwargs": {"enable_thinking": False}, "max_tokens": 400, "temperature": 0}
    url = f"https://api.cloudflare.com/client/v4/accounts/{env['DRAFTER_CF_ACCOUNT']}/ai/run/{CF_MODEL}"
    rq = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                headers={"Authorization": "Bearer " + env["DRAFTER_CF_AI_TOKEN"], "Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(rq, timeout=timeout) as r: raw = cf_text(r.read().decode())
    except Exception as e:
        print("sentence cf:", type(e).__name__, flush=True)
        return None
    ms = int((time.time() - t0) * 1000)
    return (raw, ms, ms) if raw else None


_lock = threading.Lock()
_workers = {}
_stats = {"asked": 0, "claude": 0, "cf": 0, "edits": 0, "none": 0, "fallback": 0}


def _worker(model):
    import claude_type as ct
    with _lock:
        w = _workers.get(model)
        if w is None or not w.alive() or w.turns >= ct.Worker.MAX_TURNS:
            if w: w.stop()
            w = _workers[model] = ct.Worker(model, system(), max_tokens=400)
        w.used = time.time()
        return w


def ask_claude(text, app="", cancelled=lambda: False, model="sonnet"):
    """His claudeModel (Sonnet: fastest and most exact here, bench/cloud_models.py 2026-11-16); Haiku when it fails."""
    r = _worker(model).ask(user(text, app), cancelled, wait=1.0, deadline=6.0, whole=True)
    if (not r or not r[0]) and model != "haiku" and not cancelled():
        _stats["fallback"] += 1
        r = _worker("haiku").ask(user(text, app), cancelled, wait=1.0, deadline=6.0, whole=True)
    return r


def race(text, app="", cancelled=lambda: False, providers=None, model="sonnet"):
    """-> (raw, winner, first_ms, ms) from the first provider that answers, or None."""
    providers = providers if providers is not None else {"claude": lambda: ask_claude(text, app, cancelled, model),
                                                          "cf": lambda: ask_cf(text, app)}
    done, box = threading.Event(), {}
    left = [len(providers)]
    def go(name, f):
        try: r = f()
        except Exception: r = None
        with _lock:
            left[0] -= 1
            if r and r[0] and "win" not in box: box["win"] = (r[0], name, r[1], r[2])
            if "win" in box or left[0] == 0: done.set()
    for name, f in providers.items(): threading.Thread(target=go, args=(name, f), daemon=True).start()
    done.wait(8.0)
    return box.get("win")


def check(text, at, app="", cancelled=lambda: False, providers=None, model="sonnet"):
    """`text` is the message so far, `at` where its last sentence starts. -> {"edits": [{at, len (UTF-16), old, new}]
    in `text`, "fixed", "ms", "first_ms", "model"} or None."""
    import proofread
    at = max(0, min(int(at), len(text)))
    s = text[at:]
    if len(s.split()) < 3: return {"edits": [], "fixed": text, "ms": 0, "model": ""}
    _stats["asked"] += 1
    r = race(s, app, cancelled, providers, model)
    if not r: _stats["none"] += 1; return None
    raw, winner, first, ms = r
    _stats[winner] = _stats.get(winner, 0) + 1
    out = raw.strip()
    found = [] if out.startswith("✓") or not out else proofread.edits(s, out)
    if found and (len(found) > max(3, len(s.split()) * 0.4) or not 0.75 <= len(out) / max(1, len(s)) <= 1.33): found = []
    _stats["edits"] += len(found)
    u16 = lambda x: len(x.encode("utf-16-le")) // 2
    fixed = text
    for e in sorted(found, key=lambda e: -e["at"]): fixed = fixed[:at + e["at"]] + e["new"] + fixed[at + e["at"] + e["len"]:]
    return {"edits": [{"at": u16(text[:at + e["at"]]), "len": u16(e["old"]), "old": e["old"], "new": e["new"]} for e in found],
            "fixed": fixed, "ms": ms, "first_ms": first, "model": winner}


def stats(): return dict(_stats)
