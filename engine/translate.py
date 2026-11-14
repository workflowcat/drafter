"""Translate as you type (1 November 2026; Gboard's translate bar; item 3 in docs/typing-models-research.md "Third
round"). When Andrii writes Ukrainian in a chat that is in English, or English in a Ukrainian one, or ends the line
with ;en or ;uk, the message goes to Claude with the conversation and comes back in the other language, in his tone.
The app shows it as a chip; Tab puts it in place of what he typed; Backspace right after brings his own text back.

A translation is kept only when it is in the target language (never Russian), its length is near the original's, and
every link, email and number of the original is in it.

What leaves the Mac: the message, the end of the conversation on screen and the app name, through his signed-in
`claude` CLI, under `claudeTyping` and its own setting `translate`.

    .venv/bin/python engine/translate.py en "привіт, можемо завтра о 15:00 подивитись https://x.y?" ["context"]
"""
import hashlib, json, re, sys, threading, time
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_type as ct
import prompt as prompt_mod
import local

SYSTEM = """You translate a message {name} is typing in a chat, so it reads as if he wrote it himself in the target language.
Keep his tone and register: casual stays casual, short stays short, a lowercase start and a missing final period stay (English "I" is still a capital). Keep names, links, emails, numbers, times (15:00 stays 15:00), emoji, code, @mentions and line breaks as they are.
Fit the conversation on screen: its terms and who is who. Add nothing he did not say: no greetings, sign-offs or notes.
Ukrainian means Ukrainian, never Russian.
Reply with the translation only."""


def system():
    """SYSTEM with the user's name from the local config (data/drafter.local.json); "the user" without it."""
    return SYSTEM.replace("{name}", local.name())


MAX_CHARS = 600
NAMES = {"en": "English", "uk": "Ukrainian"}
LAT = re.compile(r"[A-Za-z]")
CYR = re.compile(r"[А-Яа-яІіЇїЄєҐґ]")
TOKENS = re.compile(r"https?://\S+|[\w.+-]+@[\w-]+\.[\w.]+|\d+")

_lock = threading.Lock()
_workers = {}
_cache = {}
_stats = {"asked": 0, "kept": 0, "dropped": 0}


def lang(text, share=0.8):
    """"uk", "en" or None: which letters most of the text is written in (at least 12 letters)."""
    lat, cyr = len(LAT.findall(text or "")), len(CYR.findall(text or ""))
    n = lat + cyr
    if n < 12: return None
    if cyr / n >= share: return None if ct.RUSSIAN.search(text) and len(ct.RUSSIAN.findall(text)) > 2 else "uk"
    if lat / n >= share: return "en"
    return None


def _tokens(t):
    return Counter(x.rstrip(".,;:!?)") for x in TOKENS.findall(t))


def kept(text, out, target):
    """Is `out` a translation of `text` worth showing?"""
    if not out or out.strip() == "✓" or out.strip() == text.strip(): return False
    if not 0.4 <= len(out) / max(1, len(text)) <= 2.5: return False
    if lang(out, 0.6) != target and (len(LAT.findall(out)) + len(CYR.findall(out))) >= 12: return False
    if target == "uk" and ct.RUSSIAN.search(out): return False
    if target == "en" and len(CYR.findall(out)) > 2: return False
    need, have = _tokens(text), _tokens(out)
    return all(have[k] >= n for k, n in need.items())


def _worker(model):
    with _lock:
        w = _workers.get(model)
        if w is None or not w.alive() or w.turns >= ct.Worker.MAX_TURNS:
            if w: w.stop()
            names = prompt_mod.words()[:120]
            w = _workers[model] = ct.Worker(model, system() + "\n\nNames he uses: " + ", ".join(names), max_tokens=1500)
        w.used = time.time()
        return w


# idle processes are stopped by claude_type's one reaper (10 idle minutes, or at once when memory is low)


def translate(text, target, context="", app="", model="sonnet", cancelled=lambda: False):
    """-> {"text", "target", "ms"} or {} (nothing kept)."""
    text = (text or "").strip()
    if target not in NAMES or not text or len(text) > MAX_CHARS: return {}
    if not Path(ct.CLI).exists(): return {}
    key = hashlib.sha1(json.dumps([text, target, (context or "")[-800:], model]).encode()).hexdigest()
    if key in _cache: return dict(_cache[key], cached=True)
    _stats["asked"] += 1
    user = (f"App: {app}\n\n" if app else "") + f"Translate into {NAMES[target]}.\n\n" + \
           ("Conversation on screen (newest last):\n" + context.strip()[-800:] + "\n\n" if context.strip() else "") + \
           "His message:\n" + text
    r = _worker(model).ask(user, cancelled, wait=1.0, deadline=10.0, whole=True)
    if r is None: return {}
    raw, first, ms = r
    out = raw.strip()
    res = {}
    if kept(text, out, target): res = {"text": out, "target": target, "ms": ms}; _stats["kept"] += 1
    else: _stats["dropped"] += 1
    if len(_cache) > 40: _cache.pop(next(iter(_cache)))
    _cache[key] = res
    return res


def stats(): return dict(_stats)


if __name__ == "__main__":
    tgt = sys.argv[1] if len(sys.argv) > 1 else "en"
    t = sys.argv[2] if len(sys.argv) > 2 else "привіт, можемо завтра о 15:00 глянути документи? я скину лінк"
    ctx = sys.argv[3] if len(sys.argv) > 3 else "Mila: Hi Andrii, did you get a chance to look at the contract draft?"
    s = time.time()
    print(translate(t, tgt, ctx), f"{time.time() - s:.1f}s", stats())
