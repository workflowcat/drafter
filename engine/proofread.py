"""Proofread the whole message with one chip (1 November 2026; Gboard's "Fix it" and Grammarly do it, none for
Ukrainian; first on the list in docs/typing-models-research.md "Third round"). When Andrii stops typing for a moment the
app sends the message so far; Claude returns it with only clear mistakes fixed, and only small word fixes are kept:
one word for one word, a few letters apart or the same word typed in the other keyboard layout, or a word split or
joined. His slang, punctuation, case and missing full stops stay. Words he took back before (data/autocorrect-keep.txt)
are never fixed. The app shows "Fix N" as a chip; Tab puts the fixes in, each with a dotted line and a chip to undo it.

What leaves the Mac: the message text and the app name, through his signed-in `claude` CLI, under the same setting as
Claude on a pause (`claudeTyping`) and its own `proofread`.

    .venv/bin/python engine/proofread.py "Text to check" [model]
"""
import difflib, json, re, sys, threading, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_type as ct
import prompt as prompt_mod
import local

SYSTEM = """You proofread a chat message or note {name} is typing (Ukrainian and English, often mixed in one message).

Fix only clear mistakes: typos, missing, doubled or swapped letters, a wrong case ending or agreement in Ukrainian, a missing apostrophe or soft sign in Ukrainian, words typed in the wrong keyboard layout (ghbdsn = привіт), two words run together or one word split.
Keep everything else exactly as written: his words and word choice, slang and surzhyk on purpose (шо, тіки, щас, ок, норм, плз), names, links, code, emoji, numbers, lowercase starts, a missing final period, his commas and other punctuation, line breaks and spacing. Never rephrase, never add or remove words, never translate, never change Ukrainian to Russian.

Reply with the corrected text only, nothing before or after it. If nothing needs fixing, reply with exactly: ✓"""


def system():
    """SYSTEM with the user's name from the local config (data/drafter.local.json); "the user" without it."""
    return SYSTEM.replace("{name}", local.name())


MAX_CHARS = 800
RUSSIAN = re.compile(r"[ыэъёЫЭЪЁ]")
EDGE = "\"'«»“”„()[]{}<>.,:;!?…-–—*_~`"
EN = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./"
UK = "'йцукенгшщзхїфівапролджєячсмитьбю."
TO_UK = {a: b for a, b in zip(EN, UK)} | {a.upper(): b.upper() for a, b in zip(EN, UK) if a.isalpha()}
TO_EN = {b: a for a, b in TO_UK.items()}

_lock = threading.Lock()
_workers = {}
_cache = {}          # (text, model) -> result, last 40
_stats = {"asked": 0, "edits": 0, "dropped": 0, "clean": 0}


def _system():
    names = prompt_mod.words()[:150]
    return system() + "\n\nHis names and words (right as written, never fix them): " + ", ".join(names)


def _worker(model):
    """Its own kept-running `claude` process (a whole answer, a bigger output cap); stopped after 10 idle minutes."""
    with _lock:
        w = _workers.get(model)
        if w is None or not w.alive() or w.turns >= ct.Worker.MAX_TURNS:
            if w: w.stop()
            w = _workers[model] = ct.Worker(model, _system(), max_tokens=1200)
        w.used = time.time()
        return w


# idle processes are stopped by claude_type's one reaper (10 idle minutes, or at once when memory is low)


def warm(model="sonnet"):
    threading.Thread(target=lambda: _worker(model), daemon=True).start()


# ---------- which fixes stay ----------

def _keep():
    """Words never fixed: ones he took back (autocorrect-keep.txt) and his own words, used 3+ times (mywords.txt; the
    bench "fixed" тіма, his word for team)."""
    out = set()
    for f in ("mywords.txt", "known-words.txt"):
        try: out |= {l.strip().lower() for l in (ct.DATA / f).read_text().splitlines() if l.strip()}
        except Exception: pass
    try: counts = json.loads((ct.DATA / "autocorrect-keep.json").read_text())
    except (OSError, ValueError): counts = {}
    if not isinstance(counts, dict): counts = {}
    counts = {w.lower(): n for w, n in counts.items() if isinstance(n, int) and n >= 0}
    # The old list counts as one, never an unconditional keep. JSON stores total counts.
    try:
        for word in (ct.DATA / "autocorrect-keep.txt").read_text().splitlines():
            word = word.strip().lower()
            counts[word] = max(counts.get(word, 0), 1)
    except OSError: pass
    out |= {w.lower() for w, n in counts.items() if isinstance(n, int) and n >= 2}
    return out


def _core(tok):
    """A token without the punctuation around it: (lead, core, trail)."""
    i, j = 0, len(tok)
    while i < j and tok[i] in EDGE: i += 1
    while j > i and tok[j - 1] in EDGE: j -= 1
    return tok[:i], tok[i:j], tok[j:]


def _dist(a, b):
    """Edit distance with swaps (Damerau, optimal string alignment)."""
    d = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a) + 1): d[i][0] = i
    for j in range(len(b) + 1): d[0][j] = j
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            c = 0 if a[i - 1] == b[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + c)
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]: d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
    return d[-1][-1]


def _layout(old, new):
    """The same keys in the other layout?"""
    return "".join(TO_UK.get(c, c) for c in old) == new or "".join(TO_EN.get(c, c) for c in old) == new


def _close(old, new):
    a, b = old.lower(), new.lower()
    if a == b: return False                       # case only: his lowercase stays
    # English without the apostrophe (lets, dont, im) is how he writes; a Ukrainian one missing is a mistake (мясо)
    if a.isascii() and a.replace("'", "").replace("’", "") == b.replace("'", "").replace("’", ""): return False
    if _layout(old, new): return True
    if len(a) < 3 or not b: return False          # "it" -> "I" in the bench: too short to tell a typo
    if any(c.isdigit() for c in a + b) or "/" in a or "@" in a: return False
    n = max(len(a), len(b))
    allowed = 1 if n <= 5 else 2 if n <= 9 else 3
    if a[0] != b[0] and _dist(a[1:], b[1:]) > 0 and n <= 5: return False
    return _dist(a, b) <= allowed


_SYSTEM_WORDS = None

def joined_word(word, keep):
    global _SYSTEM_WORDS
    if word.lower() in keep: return True
    if _SYSTEM_WORDS is None:
        try: _SYSTEM_WORDS = set(Path('/usr/share/dict/words').read_text().lower().splitlines())
        except OSError: _SYSTEM_WORDS = set()
    return word.lower() in _SYSTEM_WORDS


def edits(text, fixed, keep=None):
    """-> list of {at, len, old, new} (Python str offsets) for the small word fixes between text and fixed."""
    keep = _keep() if keep is None else keep
    ta = [(m.start(), m.group()) for m in re.finditer(r"\S+", text)]
    tb = [m.group() for m in re.finditer(r"\S+", fixed)]
    out = []
    sm = difflib.SequenceMatcher(a=[t for _, t in ta], b=tb, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op != "replace": continue
        if i2 - i1 == j2 - j1:
            for (at, old), new in zip(ta[i1:i2], tb[j1:j2]):
                lo, oc, tr = _core(old)
                _, nc, _ = _core(new)
                if not oc or not nc or oc.lower() in keep or RUSSIAN.search(nc) or not _close(oc, nc): continue
                out.append({"at": at + len(lo), "len": len(oc), "old": oc, "new": nc})
        elif "".join(t for _, t in ta[i1:i2]) == "".join(tb[j1:j2]) and (i2 - i1) + (j2 - j1) <= 4:
            # split or joined words ("незнаю" -> "не знаю"): same letters, other spaces
            at, end = ta[i1][0], ta[i2 - 1][0] + len(ta[i2 - 1][1])
            old, new = text[at:end], " ".join(tb[j1:j2])
            protected = any(_core(t)[1].lower() in keep for t in old.split())
            joined = ''.join(_core(t)[1] for t in old.split())
            # Existing unprotected split repairs stay; protected pieces may join/split
            # only if the combined spelling is independently known as a word.
            valid = joined_word(joined, keep)
            if not RUSSIAN.search(new) and (valid or (not protected and i2 - i1 == 1)):
                out.append({"at": at, "len": end - at, "old": old, "new": new})
    return out


def _u16(s): return len(s.encode("utf-16-le")) // 2


def check(text, app="", model="sonnet", cancelled=lambda: False, hint=""):
    """-> {"edits": [{at, len (UTF-16), old, new}], "fixed", "ms", "model"} or None (no Claude, busy, error)."""
    text = text[-MAX_CHARS:]
    if len(text.split()) < 4: return {"edits": [], "fixed": text, "ms": 0, "model": model}
    key = (text, model, hint)
    # the cache keeps Claude's answer, not the edits: a word he took back since is filtered out again (Codex review
    # 2026-11-01: an undone fix came back for the same text)
    cached = key in _cache
    if cached: out, first, ms = _cache[key]
    else:
        if not Path(ct.CLI).exists(): return None
        w = _worker(model)
        _stats["asked"] += 1
        user = (f"App: {app}\n" if app else "") + hint + "Text:\n" + text
        r = w.ask(user, cancelled, wait=1.0, deadline=9.0, whole=True)
        if r is None: return None
        raw, first, ms = r
        out = raw.strip()
        if len(_cache) > 40: _cache.pop(next(iter(_cache)))
        _cache[key] = (out, first, ms)
    found = [] if out.startswith("✓") or not out else edits(text, out)
    words = len(text.split())
    # a rewrite, not a proofread: too many changes, or a very different length
    if found and (len(found) > max(6, words * 0.4) or not 0.75 <= len(out) / max(1, len(text)) <= 1.33):
        _stats["dropped"] += not cached; found = []
    if not cached: _stats["clean"] += not found; _stats["edits"] += len(found)
    fixed = text
    for e in sorted(found, key=lambda e: -e["at"]): fixed = fixed[:e["at"]] + e["new"] + fixed[e["at"] + e["len"]:]
    res = {"edits": [{"at": _u16(text[:e["at"]]), "len": _u16(e["old"]), "old": e["old"], "new": e["new"]} for e in found],
           "fixed": fixed, "ms": ms, "first_ms": first, "model": model}
    if cached: res["cached"] = True
    return res


def stats(): return dict(_stats)


if __name__ == "__main__":
    t = sys.argv[1] if len(sys.argv) > 1 else "привіт, можемо поговорити завтра про проєкт? я вже подвиився на документи і там є кілька питаннь"
    m = sys.argv[2] if len(sys.argv) > 2 else "sonnet"
    for i in range(2):
        _cache.clear()
        r = check(t, model=m)
        print(r)
