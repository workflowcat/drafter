"""Claude finishes the sentence when Andrii pauses (2026-10-31, Andrii: "wire sonnet into it for quick typing, with
actual daily context"). The local model keeps the per-key grey words (~40 ms). When he stops typing for a moment, the
app asks `/pause` and Claude writes the rest of the sentence, knowing his day: today's calendar, his latest notes and
calls, what he typed lately, how he writes, the names he uses, and the chat on screen.

What leaves the Mac: the text before the caret, the text above the field and the day pack, to Claude through his own
signed-in `claude` CLI (setting `claudeTyping`; the app never asks in skipped apps, password fields or under secure
input). Offline, busy or on any error the local suggestion stands. No API key: the four Anthropic keys in 1Password
DevKit answered 401 on 2026-10-31.

The day pack is the worker's whole system prompt, so Claude keeps it cached; a pause pays for the few hundred tokens
of the screen and the line.

    .venv/bin/python engine/claude_type.py "Text before the caret" [app]     # a few tries, prints text and timings
"""
import json, os, re, subprocess, sys, threading, time
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
sys.path.insert(0, str(Path(__file__).resolve().parent))
import prompt as prompt_mod
import local
import provider

RUSSIAN = re.compile(r"[ыэъёЫЭЪЁ]")

_lock = threading.Lock()
_state = {"pack": None, "pack_at": 0.0, "fail_at": 0.0}


# ---------- the day pack ----------

def _calendar():
    try:
        import lookup
        account, zone = lookup.config()
        now = datetime.now(zone)
        start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        rows = lookup.events(account, start, start + timedelta(days=2))
    except Exception:
        return ""
    out = []
    for e in rows[:20]:
        if e.get("eventType") == "workingLocation": continue
        s = (e.get("start") or {}).get("dateTime") or (e.get("start") or {}).get("date") or ""
        when = s[5:16].replace("T", " ") if "T" in s else s[5:10] + " весь день"
        who = [a.get("displayName") or a.get("email", "").split("@")[0] for a in e.get("attendees", []) if not a.get("self")][:6]
        out.append(f"- {when} {e.get('summary') or '(без назви)'}" + (f" — з {', '.join(who)}" if who else ""))
    return "\n".join(out)


def _notes(days=3, n=6):
    cut = time.time() - days * 86400
    files = sorted((p for p in (DATA / "notes").glob("*.md") if p.stat().st_mtime > cut), key=lambda p: p.stat().st_mtime)[-n:]
    out = []
    for p in files:
        t = p.read_text(errors="ignore")
        t = t.split("## Розшифровка")[0].split("## Transcript")[0]
        t = re.sub(r"\n{2,}", "\n", t).strip()
        out.append(p.name[:15] + " " + t[:700])
    return "\n\n".join(out)


def _typed(n=60, exclude=()):
    rows = []
    for f in ("typed.jsonl",):
        try:
            for l in (DATA / f).read_text().splitlines()[-400:]:
                try: rows.append(json.loads(l))
                except Exception: pass
        except Exception: pass
    cut = time.time() - 2 * 86400
    keys = {x[:30] for x in exclude}
    lines = []
    for r in rows:
        t = (r.get("text") or "").strip()
        at = r.get("at") or r.get("t") or 0
        if isinstance(at, str):
            try: at = datetime.fromisoformat(at).timestamp()
            except Exception: at = 0
        if not t or (at and at < cut) or RUSSIAN.search(t) or t[:30] in keys: continue
        lines.append(f"[{r.get('app', '')}] {t[:200]}")
    return "\n".join(lines[-n:])


INSTRUCTIONS = """You finish what {name} is typing, like autocomplete in his own head. {about}

You get the app, the text on screen above the field (often the chat he answers) and the text before his caret. Reply with ONLY the characters that come right after the caret: no quotes, no explanations, never repeat what is typed. If the caret is inside a word, finish that word first, then go on. Write to the end of the current sentence or thought ({length}), then stop. Match his language (the one the line started in), his tone and spelling, including his slang and lowercase. Use the day context below when it fits (names, meetings, projects, what he said earlier); never invent facts, numbers, links or dates. If you cannot guess well, reply with exactly: ∅
Every message is a new moment and a new caret; earlier messages in this conversation are other moments, never part of this text."""
MAX_WORDS, LENGTH = 9, "usually 2-8 words"      # bench --long tries 16 and "up to about 15 words"


def instructions():
    """INSTRUCTIONS for this user: name and about from the local config (data/drafter.local.json), neutral without it."""
    return INSTRUCTIONS.replace("{name}", local.name()).replace("{about}", local.about()).replace("{length}", LENGTH)



def pack(exclude=(), fresh=False):
    """The system text, cached by Claude. Built at most every 30 minutes (a new pack means a new worker); lines he
    sends in between go into each message instead."""
    if not fresh and _state["pack"] and time.time() - _state["pack_at"] < 1800: return _state["pack"]
    style = prompt_mod.load_json(DATA / "style.json", {"examples": []}).get("examples", [])[:14]
    names = prompt_mod.words()[:120]
    parts = [instructions(), "How he writes:\n" + prompt_mod.rules(),
             "His names and words: " + ", ".join(names),
             "Messages he wrote:\n" + "\n###\n".join(style)]
    today = datetime.now().strftime("%A %d %B %Y")
    city = (local.user("city") or "").strip()
    parts.append(f"Today: {today}" + (f" ({city})" if city else ""))
    cal = _calendar()
    if cal: parts.append("His calendar today and tomorrow:\n" + cal)
    notes = _notes()
    if notes: parts.append("His latest notes and calls:\n" + notes)
    typed = _typed(exclude=exclude)
    if typed: parts.append("What he typed lately (newest last):\n" + typed)
    text = "\n\n".join(parts)
    if text != _state["pack"]:
        _state.update(pack=text, pack_at=time.time())
    else:
        _state["pack_at"] = time.time()
    return text


# ---------- the request ----------

BEFORE_CHARS, AFTER_CHARS, SCREEN_CHARS = 3000, 600, 2500   # Claude reads earlier sentences too (2026-10-31)

def notes_line(notes):
    """His writing instructions (Settings > Typing, global and this app's) as one line for a Claude prompt; "" = none."""
    n = " ".join((notes or "").split())[:300]
    return f"His writing instructions (follow them): {n}\n" if n else ""


def _user(before, app, title, context, since=0.0, after="", notes="", hint=""):
    """`hint`: the keyboard line and the chat's person block (engine/whom.py), as given."""
    now = datetime.now().strftime("%H:%M")
    where = " · ".join(x for x in (app, title) if x)
    t = f"App: {where or 'unknown'}\nTime: {now}\n" + notes_line(notes) + (hint if not hint or hint.endswith("\n") else hint + "\n")
    fresh = _typed_since(since) if since else ""
    if fresh: t += "He sent these in the last minutes:\n" + fresh + "\n"
    if context.strip(): t += "On screen above the field:\n" + context.strip()[-SCREEN_CHARS:] + "\n"
    t += "\nText before the caret (continue it right after the last character):\n" + before[-BEFORE_CHARS:] + "⟨caret⟩"
    if after.strip(): t += "\n\nAlready written after the caret (do not repeat it; your words go before it):\n" + after[:AFTER_CHARS]
    return t


def _typed_since(ts, n=4):
    out = []
    try:
        for l in (DATA / "typed.jsonl").read_text().splitlines()[-30:]:
            try: r = json.loads(l)
            except Exception: continue
            if (r.get("t") or 0) > ts and not RUSSIAN.search(r.get("text", "")): out.append(f"[{r.get('app', '')}] {r['text'][:200]}")
    except Exception: pass
    return "\n".join(out[-n:])


def clean(before, out, max_words=9, known=lambda w: False):
    out = out.replace("⟨caret⟩", "")
    if not out or out.strip() == "∅" or "∅" in out or RUSSIAN.search(out): return ""
    out = out.split("\n")[0]
    if out.strip().startswith(("\"", "«", "“")): out = out.strip().strip("\"«»“”")
    m = re.search(r"[\w'’-]+$", before)
    partial = m.group(0) if m else ""
    if partial and len(partial) >= 2 and out.lower().startswith(partial.lower()) and len(out) > len(partial):
        out = out[len(partial):]                     # it repeated the half word
    last = re.search(r"([\w'’-]+)\s+$", before)
    if last and re.match(re.escape(last.group(1)) + r"\s", out, re.I): out = out.lstrip()[len(last.group(1)):]   # "want to " + "to make"
    if before.endswith((" ", "\n")) or not before: out = out.lstrip()
    elif not partial and not out.startswith(" ") and out[:1].isalnum() and before[-1:] not in "([«\"'/@#": out = " " + out
    elif partial and out[:1].isalpha():
        # after a whole word Claude often leaves out the space: "so" + "the plan" is two words, "chec" + "k" is one
        first = re.match(r"[\w'’-]+", out).group(0)
        if known(partial) and known(first) and not known(partial + first): out = " " + out
    # to the end of the sentence, without his never-used final full stop
    s = re.search(r"[.!?…](\s|$)", out)
    if s: out = out[: s.start() + (0 if out[s.start()] == "." else 1)]
    words = re.findall(r"\s*\S+", out)
    return "".join(words[:max_words]).rstrip()


def cut_words(words, tg, tm, cap=99):
    """The Claude gate (2026-11-01): Claude's words kept while his own model gives each one a geometric-mean token
    p >= tg and no token below tm; it stops at the first word that fails and never resumes after it.
    words: model.score() output [(word with its leading space, [token p])]."""
    import math
    out = ""
    for w, ps in (words or [])[:cap]:
        # a zero (or NaN) token is the strongest no, not a missing number (Codex review 2026-11-01)
        ps = [p if p > 0 and math.isfinite(p) else 1e-12 for p in ps] or [1e-12]
        if math.exp(sum(math.log(p) for p in ps) / len(ps)) < tg or min(ps) < tm: break
        out += w
    return out.rstrip() if out.strip() else ""


def _enough(raw):
    return "\n" in raw or bool(re.search(r"[.!?…](\s|$)", raw)) or len(raw.split()) > MAX_WORDS or "∅" in raw


class Worker:
    """One `claude` process with the day pack as its whole system prompt (no tools, no settings, no MCP), kept running:
    the pack stays in Claude's cache, so a pause costs ~0.7 s (Haiku) to ~1.3 s (Sonnet) warm (2026-10-31, CLI 2.1).
    Every message is a new caret; after 40 of them, or when the pack changes, a fresh process takes over."""
    MAX_TURNS = 40
    # every live process, for the cap and the reaper (2026-11-01: up to seven `claude` processes, ~120 MB each, ran at
    # once: pause, early, proofread, facts, translate, rework + the haiku worker)
    live, _reg = [], threading.Lock()

    def __new__(cls, model, system, max_tokens=None):
        # an API connection (engine/provider.py) gets a worker with the same face that makes HTTPS requests instead
        if provider.kind() in ("anthropic", "openai"): return provider.ApiWorker(model, system, max_tokens)
        return super().__new__(cls)

    def __init__(self, model, system, max_tokens=None):
        self.model, self.system, self.turns, self.started = model, system, 0, time.time()
        self.used, self.dead, self.generation = time.time(), False, provider.state["generation"]
        Worker.make_room()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "ANTHROPIC"))}
        env.update(PATH=f"{Path.home()}/.local/bin:/usr/bin:/bin", CLAUDE_CODE_MAX_OUTPUT_TOKENS=str(max_tokens or 32 + 6 * MAX_WORDS))
        # his text never goes on the command line (any process reads argv through `ps`; 2026-11-14): the pack goes in
        # a 0600 file the CLI reads at start, deleted once the process answers anything (it reads the file once)
        self.system_file = prompt_file(system)
        self.p = subprocess.Popen(Worker.argv(model, self.system_file), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, env=env)
        self.deltas, self.idle, self.usage = None, threading.Event(), {}
        self.idle.set()
        with Worker._reg: Worker.live.append(self)
        threading.Thread(target=self._pump, daemon=True).start()

    @staticmethod
    def argv(model, system_file):
        """The command line: flags and paths only. Never the system prompt or a message (tests/test_claude_argv.py)."""
        return [CLI, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--model", model, "--system-prompt-file", system_file, "--tools", "", "--effort", "low",
                "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--setting-sources", "",
                "--disable-slash-commands", "--no-session-persistence"]

    def alive(self): return not self.dead and self.p.poll() is None and self.generation == provider.state["generation"]

    def _drop_file(self):
        f, self.system_file = self.system_file, None
        if f:
            try: os.unlink(f)
            except OSError: pass

    def _pump(self):
        for line in self.p.stdout:
            self._drop_file()   # it answered: the system prompt has been read
            try: d = json.loads(line)
            except Exception: continue
            q = self.deltas
            if d.get("type") == "stream_event":
                ev = d.get("event") or {}
                if ev.get("type") == "content_block_delta" and (ev.get("delta") or {}).get("type") == "text_delta" and q:
                    q.put(ev["delta"]["text"])
            elif d.get("type") == "result":
                self.usage = d.get("usage") or {}
                if q: q.put(None)
                self.idle.set()
        if self.deltas: self.deltas.put(None)
        self.idle.set()
        self._drop_file()   # ended before it answered

    def ask(self, user, cancelled=lambda: False, wait=1.5, deadline=6.0, whole=False):
        """-> (raw text, first_ms, ms), or None. Returns as soon as the sentence is whole (or, with `whole`, the answer is
        over); the turn finishes on its own."""
        import queue
        self.used = time.time()
        if not self.idle.wait(wait): return None
        with Worker._reg:     # taken under the same lock eviction uses, so a worker is never stopped mid-request
            if not self.alive() or not self.idle.is_set(): return None
            self.idle.clear(); self.turns += 1
        q = self.deltas = queue.Queue()
        t0 = time.time(); first = None; out = ""
        try:
            self.p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": user}}) + "\n"); self.p.stdin.flush()
        except Exception:
            self.idle.set(); return None
        end = t0 + deadline
        while time.time() < end:
            if cancelled(): return None
            try: piece = q.get(timeout=0.05)
            except Exception: continue
            if piece is None: break
            if first is None: first = time.time()
            out += piece
            if not whole and _enough(out): break
        else:
            self.p.kill(); return None
        return out, round(((first or time.time()) - t0) * 1000), round((time.time() - t0) * 1000)

    def stop(self):
        self.dead = True
        try: self.p.kill()
        except Exception: pass
        self._drop_file()

    @classmethod
    def make_room(cls):
        """At most MAX_LIVE processes: a new one stops the idle one used longest ago (it starts again when needed)."""
        with cls._reg:
            cls.live = [w for w in cls.live if w.alive()]
            idle = sorted((w for w in cls.live if w.idle.is_set()), key=lambda w: w.used)
            while len(cls.live) >= MAX_LIVE and idle:
                w = idle.pop(0); w.stop(); cls.live.remove(w)

    @classmethod
    def reap(cls, idle_s):
        """Stop every process with no turn running and none asked for `idle_s` seconds. -> how many."""
        n = 0
        with cls._reg:
            for w in list(cls.live):
                if not w.alive(): cls.live.remove(w)
                elif w.idle.is_set() and time.time() - w.used > idle_s:
                    w.stop(); cls.live.remove(w); n += 1
        return n


MAX_LIVE = int(os.environ.get("DRAFTER_CLAUDE_MAX", "4"))


def mem_free():
    """macOS memory level in % (kern.memorystatus_level, what the system counts as free); -1 when unknown."""
    try:
        import ctypes
        libc = ctypes.CDLL("libc.dylib")
        v, n = ctypes.c_int(0), ctypes.c_size_t(4)
        if libc.sysctlbyname(b"kern.memorystatus_level", ctypes.byref(v), ctypes.byref(n), None, ctypes.c_size_t(0)) == 0:
            return v.value
    except Exception:
        pass
    return -1


def reap(idle_s=600):
    """Kept processes idle for idle_s go; the haiku worker (claude_worker) too, when it was loaded."""
    n = Worker.reap(idle_s)
    cw = sys.modules.get("claude_worker")
    if cw and hasattr(cw, "reap"): n += cw.reap(idle_s)
    return n


def _reaper():
    """Every minute: processes idle 10 minutes go, and all idle ones while the Mac is short of memory (< 20% free)."""
    while True:
        time.sleep(60)
        try:
            low = 0 <= mem_free() < 20
            n = reap(0 if low else 600)
            if n and low: print(f"claude: memory low, stopped {n} idle", flush=True)
        except Exception as e:
            print("claude reaper:", e, flush=True)


threading.Thread(target=_reaper, daemon=True).start()


import integrations
CLI = (integrations.claude_bin() if integrations.available("claude") else "") or "/nonexistent/claude"   # the `claude` CLI only when the local config turns it on and it is there (engine/integrations.py); else a path that never exists

# Prompt files for `claude` processes (system prompts): a folder only this user can open; each file 0600 and gone as
# soon as its process has read it (Worker._drop_file); leftovers of a crash go at the next engine start.
PROMPT_DIR = Path(os.environ.get("TMPDIR", "/tmp")) / "drafter-prompts"


def prompt_file(text):
    """-> path of a new 0600 file holding `text`, for --system-prompt-file."""
    import tempfile
    PROMPT_DIR.mkdir(mode=0o700, exist_ok=True)
    os.chmod(PROMPT_DIR, 0o700)
    fd, path = tempfile.mkstemp(prefix="sp-", suffix=".txt", dir=PROMPT_DIR)   # mkstemp: 0600, O_EXCL
    with os.fdopen(fd, "w", encoding="utf-8") as f: f.write(text)
    return path


def _clear_prompt_files(older_s=3600):
    """Files a crashed engine left (an hour old: a bench importing this must not take a live worker's file)."""
    try:
        for f in PROMPT_DIR.glob("sp-*.txt"):
            if time.time() - f.stat().st_mtime > older_s: f.unlink()
    except OSError: pass


_clear_prompt_files()
_workers = {}


def _worker(model, lane="pause"):
    """The running worker for this model and lane ("pause" answers a pause, "early" runs ahead at word ends); a fresh
    one is started in the background when the pack changed or it is used up, and takes over once it answered its first
    (warming) message."""
    key = (model, lane)
    with _lock:
        w = _workers.get(key)
        system = pack()
        starting = _state.setdefault("starting", set())
        if w is None or not w.alive():
            w = _workers[key] = Worker(model, system)
            _state["pack_used"] = _state["pack_at"]
        elif (w.system != system or w.turns >= Worker.MAX_TURNS) and key not in starting:
            starting.add(key)
            def swap(old=w):
                try:
                    nw = Worker(model, system)
                    if nw.ask(_user("ok", "", "", "")) is not None and nw.idle.wait(10):
                        with _lock: _workers[key] = nw
                        _state["pack_used"] = time.time()
                        old.idle.wait(5); old.stop()
                    else: nw.stop()
                finally:
                    starting.discard(key)
            threading.Thread(target=swap, daemon=True).start()
        w.used = time.time()
        return w


def complete(before, app="", title="", context="", model="sonnet", cancelled=lambda: False, known=lambda w: False,
             lane="pause", after="", notes="", hint=""):
    """-> {"text", "raw", "first_ms", "ms", "model"} or None (no Claude, busy, error)."""
    if not Path(CLI).exists() or time.time() - _state["fail_at"] < 20: return None
    w = _worker(model, lane)
    r = w.ask(_user(before, app, title, context, since=_state.get("pack_used", 0), after=after, notes=notes, hint=hint), cancelled)
    if r is None:
        if not w.alive(): _state["fail_at"] = time.time()
        return None
    raw, first, ms = r
    return {"text": clean(before, raw, max_words=MAX_WORDS, known=known), "raw": raw, "first_ms": first, "ms": ms, "model": model, "turn": w.turns}


# ---------- early start ----------
# (2026-10-31, Andrii: "start Claude early") At each word end the engine asks Claude on a second worker, so the answer
# is usually there when he pauses. Latest wins: one request runs, a newer word end replaces the one waiting. At the
# pause the early answer is used when he typed exactly its first letters since; else a fresh one is asked on the
# pause worker, while the early one still running may win. At most EARLY_PER_MIN early asks a minute.
EARLY_PER_MIN = 20
_early = {"want": None, "busy": False, "running": None, "done": None, "asked": 0, "used": 0, "times": []}
_early_lock = threading.Lock()


def _where(app, title, context, after, model, field=0, notes="", hint=""):
    """Which field and chat an answer belongs to (Codex review, 2026-10-31): the same words typed in another chat,
    or with a new message on screen, never take an answer asked for somewhere else (nor one asked with other
    writing instructions)."""
    import hashlib
    h = lambda t: hashlib.sha1(t.encode()).hexdigest()[:12]
    return (app, title, h(context[-800:]), h(after[:300]), model, field) + ((h(notes),) if notes else ()) + ((h(hint),) if hint else ())


def early(before, app="", title="", context="", model="sonnet", known=lambda w: False, after="", field=0, notes="", hint=""):
    """Ask ahead for this caret (a word just ended). -> True when queued."""
    if not Path(CLI).exists() or time.time() - _state["fail_at"] < 20: return False
    where = _where(app, title, context, after, model, field, notes, hint)
    with _early_lock:
        d = _early["done"]
        if _early["running"] == (before, where) or (d and (d["before"], d["where"]) == (before, where)): return False
        _early["want"] = (before, app, title, context, model, known, after, where, notes, hint)
        if _early["busy"]: return True
        _early["busy"] = True
    threading.Thread(target=_early_loop, daemon=True).start()
    return True


def _early_loop():
    while True:
        with _early_lock:
            job, _early["want"] = _early["want"], None
            now = time.time()
            _early["times"] = [t for t in _early["times"] if now - t < 60]
            if job is None or len(_early["times"]) >= EARLY_PER_MIN:
                _early["busy"] = False; _early["running"] = None
                return
        before, app, title, context, model, known, after, where, notes, hint = job
        with _early_lock:
            _early["times"].append(now); _early["asked"] += 1; _early["running"] = (before, where)
        r = None
        try: r = complete(before, app, title, context, model=model, known=known, lane="early", after=after, notes=notes, hint=hint)
        except Exception as e: print("early:", e, flush=True)
        with _early_lock:
            _early["running"] = None
            _early["done"] = dict(r, before=before, where=where, at=time.time()) if r else None


def _fit(d, before, where):
    """The early answer's rest for this caret, "" when it said nothing for exactly this caret, None when it does not fit."""
    if not d or d["where"] != where or time.time() - d["at"] > 60 or not before.startswith(d["before"]): return None
    typed, text = before[len(d["before"]):], d["text"]
    if not typed: return text
    if text.startswith(typed) and len(text) > len(typed): return text[len(typed):].lstrip(" ") if typed.endswith(" ") else text[len(typed):]
    return None


def answer(before, app="", title="", context="", model="sonnet", cancelled=lambda: False, known=lambda w: False,
           after="", deadline=6.0, field=0, notes="", hint=""):
    """At a pause: the early answer when it fits, else a fresh one. -> complete()'s dict plus "early", or None."""
    t0 = time.time()
    where = _where(app, title, context, after, model, field, notes, hint)
    with _early_lock: d, running = _early["done"], _early["running"]
    hit = _fit(d, before, where)
    if hit is not None:
        with _early_lock: _early["used"] += 1 if hit else 0
        return dict(d, text=hit, early=True, ms=0, first_ms=0)
    if running == (before, where):
        # asked at this very caret: wait for it rather than asking twice
        while time.time() - t0 < deadline and not cancelled():
            with _early_lock: d, running = _early["done"], _early["running"]
            if running != (before, where): break
            time.sleep(0.02)
        hit = _fit(d, before, where)
        if hit is not None:
            with _early_lock: _early["used"] += 1 if hit else 0
            return dict(d, text=hit, early=True, ms=round((time.time() - t0) * 1000), first_ms=0)
        if cancelled(): return None
    # fresh, while an early one for an earlier caret may still come back first and fit
    box = {}
    th = threading.Thread(target=lambda: box.update(r=complete(before, app, title, context, model=model, cancelled=cancelled,
                                                                  known=known, after=after, notes=notes, hint=hint)), daemon=True)
    th.start()
    while th.is_alive() and time.time() - t0 < deadline + 1:
        if cancelled(): return None
        with _early_lock: d = _early["done"]
        hit = _fit(d, before, where)
        if hit:
            with _early_lock: _early["used"] += 1
            return dict(d, text=hit, early=True, ms=round((time.time() - t0) * 1000), first_ms=0)
        th.join(0.02)
    r = box.get("r")
    return dict(r, early=False) if r else None


def early_stats():
    with _early_lock: return {"asked": _early["asked"], "used": _early["used"], "per_min_cap": EARLY_PER_MIN}


def warm(model="sonnet", lanes=("pause", "early")):
    """Start the workers before he types (on focus), so the first pause does not pay for the process start."""
    for lane in lanes:
        w = _workers.get((model, lane))
        if w is None or not w.alive():
            threading.Thread(target=lambda lane=lane: _worker(model, lane).ask(_user("ok", "", "", "")), daemon=True).start()


if __name__ == "__main__":
    before = sys.argv[1] if len(sys.argv) > 1 else "завтра в нас дзвінок з "
    app = sys.argv[2] if len(sys.argv) > 2 else "Beeper"
    t = time.time(); pk = pack(); print(f"pack {len(pk)} chars in {time.time() - t:.1f}s")
    for model in ("haiku", "sonnet"):
        for k in range(3):
            print(model, complete(before, app, model=model))
            time.sleep(1.5)
