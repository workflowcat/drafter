"""Drafter engine: one warm model on localhost, used only by the Drafter menu-bar app.

    .venv/bin/python engine/server.py            # port 8797 is Aleph, so Drafter uses 8798
Env: DRAFTER_MODEL (hf repo), DRAFTER_CAP_GB (default 3.2), DRAFTER_PORT (8798).

POST /complete {before, app, title, context?, max_tokens?} -> {text, ms, more, src?, action?, ahead?} (ahead: worked out while the last one showed)
POST /accept   {text, before, app}       -> remembers what was taken (data/accepted.jsonl, local only)
POST /words    {text, lang?, kind?}       -> adds a word to data/words.json and re-warms the head
POST /outline  {text, call?}              -> {title, points, todos}: live outline of a long note or call
POST /note     {text, audio?}             -> long note: title, Aleph links, follow-ups; saved in Aleph + data/notes
POST /rewrite  {text, instruction}         -> {text}: the selection rewritten (speak over a selection)
POST /free     {from, to, minutes, title?, earliest?, latest?, count?} -> {slots: [{start, end, chip}]} from his calendars
POST /lookup   {kind,query}               -> read-only documents, links, meetings and free times
POST /command  {text}                     -> up to 3 runnable options for a typed direction (⌃⌥Space)
POST /snippet  {key, text}                -> save a snippet (data/snippets.json)
POST /ask      {text}                     -> answer from his notes, takes and Aleph (Claude Haiku), for the strip
POST /followups {items}                   -> each into Aleph as a follow-up for the next working morning (on his Tab)
POST /prep     {text}                     -> {lines, people}: call prep from Aleph for names in a call window's title
POST /reply    {app, title, context}      -> {text}: a short reply in his voice for an empty chat box
POST /chip     {before}                   -> {action?} for the line being typed (the app asks after a pause)
POST /prefill  {before, app, title, context}  -> reads it into the cache (on focus), no suggestion
POST /typed    {text, app, context?}      -> a line he sent; kept in data/typed.jsonl (with the chat above) for the phrase memory and benches; in Beeper it joins that chat's lines (people.py)
POST /act      {id, fields}               -> runs an action; app-side ones (EventKit) go to the app via /pending
GET  /settings, POST /settings {paused?, skip?, actions_off?, model?, callNotes?, ...}   -> for Aleph's controls
POST /words/remove {text}
GET  /edits, POST /edits {heard, fixed, accept}   -> words he changed after dictating; accepted ones join the dictionary
POST /sleep {secs}, POST /wake  -> text model off / on while a long call is read again (memory budget)
GET  /health
GET  /models -> {models: [catalog entry + downloaded, download {state, pct}, speed, quality], current, recommended, why,
                 machine {total_gb, free_gb, budget_gb}, switching}   (model catalog, 2026-11-15)
POST /model {id}            -> {ok, current, error?, seconds}: unload the current model, load this one (live on a failure)
POST /models/download {id}  -> {state, pct}: the weights he asked for, in their own process; /models/cancel {id} stops it

Only local programs (the app, Aleph's hub) may call it, never a web page: a request with Origin or Sec-Fetch-*
headers, a Host other than 127.0.0.1/localhost, or a POST that is not application/json gets 403.
"""
import json, math, os, queue, re, shutil, subprocess, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from collections import OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(ROOT))
import guard
CAP = float(os.environ.get("DRAFTER_CAP_GB", "3.6"))
guard.start(CAP)
from model import Model
import model as model_mod
import catalog
from prompt import Builder
import prompt as prompt_mod
import dictionary
import actions
import memory
import edits
import snippets
import notes
import claude_worker
import cloud
import prep
import router
import words as words_mod
import know as know_mod
import people
import gatecore
import fim
import claude_type
import local
import integrations
import provider

REPO = os.environ.get("DRAFTER_MODEL", "mlx-community/Qwen3-1.7B-4bit")
FMT = os.environ.get("DRAFTER_FMT", "raw")
PORT = int(os.environ.get("DRAFTER_PORT", "8798"))
MAX_TOKENS = int(os.environ.get("DRAFTER_MAX_TOKENS", "8"))
MIN_P = float(os.environ.get("DRAFTER_MIN_P", "0.6"))
MAX_WORDS = int(os.environ.get("DRAFTER_MAX_WORDS", "3"))
DATA = ROOT / "data"; DATA.mkdir(exist_ok=True)
dictionary.ensure()   # the live dictionary lives in data/ since 2026-11-14 (moved once from dictionary/)
local.seed_snippets(DATA / "snippets.json")   # a new install only: never touches an existing file
cloud.migrate(DATA / "settings.json")        # once: an existing file keeps its Claude switches before the defaults went off

phrases = memory.Memory()
knowledge = know_mod.Pack(DATA / "know.json")
_entities = []


def entity_store():
    """data/entities.json, read again only when the file changed (engine/entities.py Store)."""
    if not _entities:
        import entities
        _entities.append(entities.Store(DATA / "entities.json"))
    return _entities[0]
finisher = words_mod.Words()
print(f"drafter engine: word finisher from {finisher.load()} lines, {finisher.export(DATA / 'mywords.txt')} known words", flush=True)
GATE_LOCK = threading.Lock()
GATE = {"g": gatecore.load(), "mtime": 0}
# per-person memory (engine/people.py): his older messages in the Beeper chat on screen go above it in the prompt;
# read from the Beeper CLI in the background (off with DRAFTER_PEOPLE=0)
people_mem = people.People()
if os.environ.get("DRAFTER_PEOPLE", "1") == "1" and shutil.which("beeper") and integrations.available("beeper"): people_mem.start()


def earlier(app, context, remember=True):
    """His older messages in the Beeper chat on screen (people.People.block), or ''; every local prompt of a screen
    takes the same, so /prefill, /complete and score_words share one warm cache."""
    if not (app or "").lower().startswith("beeper") or not context: return ""
    try: return people_mem.block(context, remember=remember)
    except Exception as e: print("people:", e, flush=True); return ""


DEFAULTS = Path(__file__).resolve().parent / "defaults"


def fitted(name):
    """data/<name>, else the shipped default in engine/defaults/ (numbers only, fitted on the author's typing), so a
    new install has a gate and a selector before its own fit."""
    p = DATA / name
    return p if p.exists() or not (DEFAULTS / name).exists() else DEFAULTS / name


def gate_file():
    """The gate for the model loaded now (model catalog): live, or a model outside the catalog, uses data/gate.json;
    another catalog model its own fit (engine/defaults/gates/, bench/catalog_gates.py), else the shipped default."""
    e = globals().get("CURRENT", {}).get("entry")
    if e is None or e.get("gate", "live") == "live": return fitted("gate.json")
    p = DEFAULTS / e["gate"]
    return p if p.exists() else DEFAULTS / "gate.json"


def gate():
    """data/gate.json (bench/gate.py --save), read again when it changes; per model since the catalog (gate_file)."""
    with GATE_LOCK:
        p = gate_file()
        try: mt = p.stat().st_mtime
        except Exception: return None
        if (mt, p) != GATE["mtime"]: GATE["g"], GATE["mtime"] = gatecore.load(p), (mt, p)
        return GATE["g"]


JSONS = {}


def kept_json(name, names):
    """data/<name> read again when it changes; None when missing or made for other features."""
    with GATE_LOCK:
        p = fitted(name)
        try: mt = p.stat().st_mtime
        except Exception: return None
        old = JSONS.get(name)
        if not old or old[0] != mt or old[2] != p:
            try:
                w = json.loads(p.read_text())
                w = w if w.get("names") == names else None
            except Exception: w = None
            JSONS[name] = old = (mt, w, p)
        return old[1]


def wordgate():
    """data/wordgate.json (bench/wordgate.py --save): when his own finish of the word being typed answers first."""
    return kept_json("wordgate.json", gatecore.WORD_NAMES)


def selector():
    """data/selector.json (bench/selector.py --save): one chance per offer from memory, his word or the model."""
    s = kept_json("selector.json", gatecore.SEL_NAMES)
    return s if s and (s.get("wordgate") or {}).get("names") == gatecore.WORD_NAMES else None


def offers_now(sel, before, ai, mid):
    """The selector's instant offers (phrase memory, his word): the best (p, text, kind) that clears its bar, or None."""
    best, low = None, sel.get("min", {})
    said, hits = phrases.suggest(before)
    said = clean(before, said) if said else ""
    cands = []
    if said and gatecore.letters(said) >= int(low.get("memory", 5)):
        cands.append(("memory", said, {"mem_hits": math.log1p(hits or 1)}))
    if mid:
        c = finisher.candidate(before)
        f = gatecore.word_features(c, before, ai)
        if f and gatecore.letters(c["rest"]) >= int(low.get("words", 3)):
            cands.append(("words", c["rest"], {"word_p": gatecore.score(sel["wordgate"]["w"], f)}))
    for kind, text, f in cands:
        p = gatecore.score(sel["w"], gatecore.sel_features(kind, text, before, ai, **f))
        if p >= sel["th"] and (best is None or p > best[0]): best = (p, text, kind)
    return best


def word_first(before, ai):
    """His own word, when the word gate approves it (round four): the rest of the word, or ''."""
    wg = wordgate()
    if not wg: return ""
    c = finisher.candidate(before)
    f = gatecore.word_features(c, before, ai)
    if f is None or gatecore.score(wg["w"], f) < wg["th"] or gatecore.letters(c["rest"]) < int(wg.get("min_letters", 3)): return ""
    return c["rest"]


AI_APPS = ("claude", "chatgpt", "codex", "perplexity")
ADAPTER = os.environ.get("DRAFTER_ADAPTER") or None


def strength_setting(st=None):
    """Settings > Typing "Personal style" (parity round): 0-100 % of his layer, default 100."""
    if st is None:   # read here: settings_load() is defined further down, after the model loads
        try: st = json.loads((DATA / "settings.json").read_text())
        except Exception: st = {}
    try: return min(100, max(0, int(st.get("personalStrength", 100)))) / 100
    except (TypeError, ValueError, AttributeError): return 1.0


# Model catalog (2026-11-15, engine/catalog.py): the model he picked in Settings > Typing > Model (settings
# "typingModel"), when its weights are here; DRAFTER_MODEL (benches) wins; else live. His layer only on live.
CATALOG = catalog.load()
LIVE_ENTRY = catalog.entry(CATALOG, catalog.LIVE)
try: _st0 = json.loads((DATA / "settings.json").read_text())
except Exception: _st0 = {}
_pick, _why = catalog.start_pick(CATALOG, _st0, DATA, os.environ.get("DRAFTER_MODEL"))
CURRENT = {"entry": _pick}     # None: a repo from DRAFTER_MODEL that is not in the catalog (a bench run)
if _pick is not None and _pick["id"] != catalog.LIVE:
    REPO = _pick["repo"]
    guard._cap[0] = max(CAP, _pick["cap_gb"]); model_mod.set_limit(guard._cap[0])
    catalog.marker_path(DATA).parent.mkdir(parents=True, exist_ok=True)
    catalog.marker_path(DATA).write_text(json.dumps({"id": _pick["id"]}))   # the guard may stop this load: next start is live
    try:
        model = Model(REPO, None, strength=strength_setting(), src=str(catalog.local_path(_pick)))
    except Exception as e:
        print(f"drafter engine: {_pick['id']} did not load ({type(e).__name__}), live instead", flush=True)
        REPO, CURRENT["entry"] = LIVE_ENTRY["repo"], LIVE_ENTRY
        guard._cap[0] = CAP; model_mod.set_limit(CAP)
        model = Model(REPO, ADAPTER, strength=strength_setting())
    catalog.marker_path(DATA).unlink(missing_ok=True)
else:
    model = Model(REPO, catalog.adapter_for(_pick, ADAPTER) if _pick else ADAPTER, strength=strength_setting())
builder = Builder(model, FMT)
model.warm(builder.head_ids)
model.pieces()
print(f"drafter engine: {REPO} ({(CURRENT['entry'] or {}).get('id', 'not in the catalog')}, {_why}) loaded in {model.load_s:.1f}s, head {len(builder.head_ids)} tokens, port {PORT}", flush=True)

# One worker owns the model. Only the newest request matters: older ones still waiting are answered empty,
# and a running one stops at the next token when a newer one arrives.
# one model, one worker: a typing request goes before look-ahead work already waiting (low), each kind in arrival
# order (round four cleanup, Codex review: the queue was plain FIFO)
jobs = queue.PriorityQueue()
JOB_ORDER = iter(range(1 << 62))
latest = [0]
LATEST_LOCK = threading.Lock()


def request_seq():
    with LATEST_LOCK:
        latest[0] += 1
        return latest[0]


def stale(seq):
    with LATEST_LOCK:
        return seq is not None and seq < latest[0]


def worker():
    while True:
        _, _, seq, fn, box = jobs.get()
        gone = box.get("cancel") or (lambda: stale(seq))
        if gone():
            box["out"] = {"text": "", "stale": True}; box["done"].set(); continue
        try:
            box["out"] = fn(gone)
        except Exception as e:  # never let one bad request kill the warm model
            box["out"] = {"error": str(e)}
        box["done"].set()


threading.Thread(target=worker, daemon=True).start()


def orphan_watch():
    # the app owns the engine; when the app is gone, so is the engine (and its memory)
    parent = os.getppid()
    while True:
        time.sleep(2)
        if os.getppid() != parent: os._exit(0)


if os.environ.get("DRAFTER_OWNED", "1") == "1": threading.Thread(target=orphan_watch, daemon=True).start()


def run(fn, newest=True, timeout=10, low=False, seq=None, cancel=None):
    if seq is None:
        if low:
            with LATEST_LOCK: seq = latest[0]
        elif newest:
            seq = request_seq()
    # None is uncancellable; zero is a valid startup look-ahead generation.
    box = {"done": threading.Event()}
    if cancel is not None: box["cancel"] = cancel
    jobs.put((1 if low else 0, next(JOB_ORDER), seq, fn, box))
    box["done"].wait(timeout)
    return box.get("out", {"error": "timeout"})


def ask(prompt, max_tokens=90, cancelled=lambda: False):
    """Field extraction for actions: a chat turn, greedy, stops at the closing brace."""
    msgs = [{"role": "user", "content": prompt}]
    s = model.tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
    if "<think>" in (model.tok.chat_template or "") and "Instruct-2507" not in model.repo:
        s += "<think>\n\n</think>\n\n"
    ids = model.tok.encode(s, add_special_tokens=False)
    out = model.oneshot(ids, max_tokens=max_tokens, stop=re.compile(r"\}\s*$"), cancelled=cancelled)
    if (DATA / "debug").exists(): print("ask:", repr(out[:300]), flush=True)
    return out


def settings_load():
    try: return json.loads((DATA / "settings.json").read_text())
    except Exception: return {}


def refresh_cli():
    """After "Connect a model" picks or drops the claude CLI: every place that starts it sees the new path."""
    path = (integrations.claude_bin() if integrations.available("claude") else "") or "/nonexistent/claude"
    claude_type.CLI = path; claude_worker.CMD[0] = path; notes.CLAUDE = path
    if "_claude" in sys.modules: sys.modules["_claude"].CLAUDE = path


def claude_on(feature, st=None):
    """The one check before the engine sends his text to a Claude worker: the setting that owns `feature` is on
    (engine/cloud.py) and the Mac is online. tests/test_cloud_gate.py fails on a Claude call site that skips it."""
    return cloud.allowed(feature, settings_load() if st is None else st) and router.online()


def clean(before, text):
    """Keep a suggestion only if it adds something and does not repeat the line just typed."""
    if not text.strip(): return ""
    text = re.sub(r"[ \t]{2,}", " ", text)                 # never two spaces in a row
    if before.endswith((" ", "\n")): text = text.lstrip(" ")
    text = re.split(r"###|\[", text)[0]
    text = text.rstrip("\n")
    last = before.splitlines()[-1] if before.splitlines() else ""
    m = re.search(r"\d{3,}", text)
    if m and not re.search(r"\d", last): text = text[: m.start()].rstrip()   # made-up numbers ("invoice 1234567")
    if len(text.strip()) >= 4 and text.strip() in last: return ""
    return text


def rewrite(req):
    """Speak over a selection (idea 1): the selected text rewritten as the spoken instruction says. Local model."""
    text, instr = (req.get("text") or "")[:3000], (req.get("instruction") or "")[:400]
    if not text.strip() or not instr.strip(): return {"text": ""}
    prompt = ("Перепиши текст за вказівкою. Відповідай лише новим текстом, без пояснень і без лапок. Мова та сама, що в "
              "тексті, якщо вказівка не каже інакше. Rewrite the text as the instruction says; reply with the new text only.\n"
              f"Вказівка / instruction: {instr}\n\nТекст / text:\n{text}")
    msgs = [{"role": "user", "content": prompt}]
    s = model.tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
    if "<think>" in (model.tok.chat_template or "") and "Instruct-2507" not in model.repo:
        s += "<think>\n\n</think>\n\n"
    ids = model.tok.encode(s, add_special_tokens=False)
    n = min(600, int(len(model.tok.encode(text)) * 2) + 40)

    def job(cancelled):
        t = time.perf_counter()
        out = model.oneshot(ids, max_tokens=n)
        out = out.strip().strip('"«»').strip()
        return {"text": out, "ms": round((time.perf_counter() - t) * 1000), "by": "local"}
    if claude_on("rewrite"):
        t = time.perf_counter()
        out = claude_worker.ask(prompt + "\n\nReply with the new text only, between <text> and </text>.", 25) or ""
        m = re.search(r"<text>(.*?)</text>", out, re.S)
        if m and m.group(1).strip():
            return {"text": m.group(1).strip().strip('"«»'), "ms": round((time.perf_counter() - t) * 1000), "by": "haiku"}
    return run(job, newest=False, timeout=30)


def outline(req):
    """Live outline of a long note or a call still running (Granola-style): a title, main points, to-dos with names.
    Claude Haiku when `callNotes` is on and online (engine/cloud.py), else the base model (his-writing layer off); the newest
    ~6,000 characters."""
    text = (req.get("text") or "")[-6000:]
    if len(text.split()) < 12: return {}
    kind = "розмови (дзвінка)" if req.get("call") else "нотатки"
    prompt = (f"Ось текст {kind}, який ще триває. Мовою тексту дай JSON з ключами: title (3-7 слів), points (до 5 "
              "головних пунктів, до 12 слів кожен), todos (до 4 справ: хто що робить). Лише JSON.\nТекст:\n" + text)
    msgs = [{"role": "user", "content": prompt}]
    s = model.tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
    if "<think>" in (model.tok.chat_template or "") and "Instruct-2507" not in model.repo:
        s += "<think>\n\n</think>\n\n"
    ids = model.tok.encode(s, add_special_tokens=False)

    def job(cancelled):
        t = time.perf_counter()
        out = model.oneshot(ids, max_tokens=320)
        m = re.search(r"\{.*\}", out, re.S)
        try: d = json.loads(m.group(0)) if m else {}
        except Exception: d = {}
        return {"title": str(d.get("title") or "")[:80], "points": [str(x)[:120] for x in (d.get("points") or [])][:5],
                "todos": [str(x)[:120] for x in (d.get("todos") or [])][:4], "ms": round((time.perf_counter() - t) * 1000), "by": "local"}
    if claude_on("call_notes"):
        t = time.perf_counter()
        out = claude_worker.ask(prompt, 30) or ""
        m = re.search(r"\{.*\}", out, re.S)
        try:
            d = json.loads(m.group(0)) if m else None
            if d: return {"title": str(d.get("title") or "")[:80], "points": [str(x)[:120] for x in (d.get("points") or [])][:5],
                          "todos": [str(x)[:120] for x in (d.get("todos") or [])][:4], "ms": round((time.perf_counter() - t) * 1000), "by": "haiku"}
        except Exception: pass
    return run(job, newest=False, timeout=60)


def prompt_examples(n=30):
    """His own recent messages to Claude (phrase memory, src claude): how he asks an AI for things."""
    try:
        rows = [json.loads(l) for l in (ROOT / "data/phrases.jsonl").read_text().splitlines()[-4000:]]
        out = [r["text"] for r in rows if r.get("src") == "claude" and 25 <= len(r.get("text", "")) <= 260]
        return out[-n:]
    except Exception:
        return []


REPLY_CACHE = {}
# three different directions he could take, each with a 2-4 word label (Andrii, 2026-10-20: "flip between a few
# suggestions… a short description, and a larger preview")
OPTIONS = (" Give three different options (different directions, not rewordings), the most likely first. Each as "
           '<option label="2-4 word gist in the language of the message">the message</option>, and nothing else. '
           "If there is nothing to say, answer <reply></reply>.")


def reply_notes(notes):
    """His writing instructions for the next-message prompt (parity round); "" = the prompt as before."""
    return f" His writing instructions (follow them): {notes}" if notes else ""


def reply(req):
    """An empty message box: his next message in his voice, by Claude Haiku (the `claude` CLI); the local 1.7B wrote poor
    replies (2026-10-20). Two kinds (2026-10-20, after ChatGPT's own suggested next prompt): in a chat, his reply to
    the last message; in an AI app (ChatGPT, Claude, Codex), the next thing he would ask the assistant to do. Nothing is
    typed: the app shows it as grey text, Tab puts it in. Same screen -> the same answer from the cache."""
    import prompt as P
    if not claude_on("reply"): return {"text": "", "src": "off"}
    ai = bool(req.get("ai"))
    ctx = (req.get("context") or "")[-(4000 if ai else 2500):]
    if len(ctx.split()) < 3: return {"text": ""}
    notes = " ".join(str(req.get("notes") or "").split())[:300]
    key = (ai, ctx[-1200:]) + ((notes,) if notes else ())
    if key in REPLY_CACHE: return {**REPLY_CACHE[key], "cached": True}
    try: voice = Path(local.setting("voice_guide", "path")).read_text()[:3500] if local.enabled("voice_guide") else P.rules()
    except Exception: voice = P.rules()
    if ai:
        examples = prompt_examples()
        prompt = (local.short_name().replace("the user", "The user") + " is working with an AI assistant in " + (req.get("app") or "an AI app") + ". Suggest the next message he "
                  "would send it. How he writes to AI assistants (his real messages):\n" + "\n".join("- " + e.replace("\n", " / ") for e in examples)
                  + "\n\nThe conversation on his screen (last part):\n" + ctx.strip()
                  + "\n\nWrite his likely next message to the assistant: the natural next step from where the conversation is now "
                  "(ask it to draft, send on, check, shorten, continue, fix what it got wrong), naming the concrete people, "
                  "numbers and things from the conversation. One or two short sentences, his words, in English (he writes to "
                  "AI assistants in English: fewer tokens; Ukrainian names and quotes stay as they are). An instruction, not a question about what to do. "
                  "Never say to send anything to other people without 'поки не відправляй' / 'don't send yet' when it is a draft "
                  "for someone." + reply_notes(notes) + OPTIONS)
    else:
        examples = P.load_json(ROOT / "data" / "style.json", {"examples": []})["examples"][:25]
        prompt = ("You write one chat reply as " + local.short_name() + ", in his voice. His voice guide:\n" + voice + "\n\nSome of his real messages:\n"
                  + "\n".join("- " + e.replace("\n", " / ") for e in examples) + "\n\nThe chat on his screen (last lines):\n" + ctx.strip()
                  + "\n\nWrite his reply to the last message in the chat: one short message (1-3 short lines), his words, in the "
                  "language of that last message, answering what it asks. Do not promise or decide anything the chat does not already "
                  "settle (then ask back or say he'll check). If the last message is his own and needs no follow-up, answer with an "
                  "empty <reply></reply>." + reply_notes(notes) + OPTIONS)
    t = time.perf_counter()
    raw = claude_worker.ask(prompt, 40) or ""
    opts = [{"label": l.strip()[:40], "text": x.strip().strip('"«»')[:400]}
            for l, x in re.findall(r'<option label="([^"]*)">(.*?)</option>', raw, re.S) if x.strip()][:3]
    if not opts:
        m = re.search(r"<reply>(.*?)</reply>", raw, re.S)
        if m and m.group(1).strip(): opts = [{"label": "", "text": m.group(1).strip().strip('"«»')[:400]}]
    out = {"text": opts[0]["text"] if opts else "", "options": opts, "ms": round((time.perf_counter() - t) * 1000)}
    if opts or "<reply></reply>" in raw:
        if len(REPLY_CACHE) > 50: REPLY_CACHE.clear()
        REPLY_CACHE[key] = out
    return out


def chip(req):
    """Only the chip for the line being typed, or nothing. Asked by the app after a pause in typing."""
    if model.asleep or model.loading: return {}
    before = (req.get("before") or "")[-800:]
    act = actions.detect(before)
    if not act: return {}

    def job(cancelled):
        if model.asleep or model.loading: return {}
        t = time.perf_counter()
        found = actions.cached(act, before, lambda p, max_tokens=90: ask(p, max_tokens, cancelled))
        return {"action": found, "ms": round((time.perf_counter() - t) * 1000)} if found else {}
    return run(job)


BEFORE_CHARS = int(os.environ.get("DRAFTER_BEFORE_CHARS", "800"))
CTX_CHARS = int(os.environ.get("DRAFTER_CTX_CHARS", "1000"))
WINDOWS_LOCK = threading.Lock()
WINDOWS = {}   # (app, title, part) -> the first characters of the window used last time


def window(key, text, size, remember=True):
    """The last `size` characters of `text`, with a start that stays put while the text only grows at the end (a new
    message came in, he typed on), so the prompt cache keeps all before it. It jumps forward when the window gets half
    again as long (2026-11-01: a shifting window made the engine read the whole chat again, 230-360 ms on one key)."""
    with WINDOWS_LOCK:
        if len(text) <= size: return text
        a = WINDOWS.get(key)
        if a:
            # the place of the anchor nearest to where the window started last time, inside the allowed 1.5 x (Codex
            # round 4: the last place of a repeated anchor cut the window to a sliver and the prompt changed every key)
            anchor, was = a
            # Speculation keeps the current anchor even beyond the jump threshold;
            # only a real key advances it, so the next unaccepted key reuses its prefix.
            lo, best, i = (max(0, len(text) - int(size * 1.5)) if remember else 0), -1, -1
            while True:
                i = text.find(anchor, i + 1 if i >= 0 else lo)
                if i < 0: break
                if best < 0 or abs(i - was) < abs(best - was): best = i
            if best >= 0:
                if remember: WINDOWS[key] = (anchor, best)
                return text[best:]
        w = text[-size:]
        nl = w.find("\n")
        if 0 <= nl < size // 4: w = w[nl + 1:]                 # start at a line, else at a word
        elif 0 <= w.find(" ") < 40: w = w[w.find(" ") + 1:]
        if remember:
            WINDOWS.pop(key, None); WINDOWS[key] = (w[:48], len(text) - len(w))
            while len(WINDOWS) > 200: WINDOWS.pop(next(iter(WINDOWS)))
        return w


def parts(req, remember=True):
    """(before, app, title, context, screen) as every local prompt reads them, so /prefill, /complete and the
    Claude gate's scoring build the same prompt and share one warm cache per screen."""
    app, title = req.get("app", ""), (req.get("title") or "")[:80]
    before = window((app, title, "before"), normal_space(req.get("before") or ""), int(req.get("before_chars") or BEFORE_CHARS), remember=remember)
    context = window((app, title, "ctx"), normal_space(req.get("context") or "").strip(), int(req.get("ctx_chars") or CTX_CHARS), remember=remember)
    return before, app, title, context, f"{app} · {title}"
def extras(req):
    """(clip, notes) a request carries for the local prompt (parity round): the fresh copy the app judged safe
    (prompt.clip_text checks again) and his writing instructions for this app. Empty = the prompt as before."""
    return str(req.get("clip") or "")[:2000], str(req.get("notes") or "")[:600]


def mid_line(req):
    """(after, after_line) for a mid-line ask (the app's setting midLine: `mid`, `after`, `after_line`), else ("", ""):
    the text after the caret goes into the prompt (prompt.MID_FORM) and the ghost must fit before `after_line`
    (engine/fim.py). A request without `mid` reads exactly as before."""
    line = str(req.get("after_line") or "")[:120] if req.get("mid") else ""
    if not line.strip(): return "", ""
    return str(req.get("after") or line)[:prompt_mod.MID_CHARS], line


def mid_result(req, res):
    """A mid-line answer from any source (memory, his word, the model): one line that fits before the rest of the
    line, never repeating it (engine/fim.py cut); no lighter tail, no "more"."""
    _, line = mid_line(req)
    if not line or not isinstance(res, dict) or not res.get("text"): return res
    text = fim.cut(res["text"], line)
    if res.get("replace"): return res     # a "→ word" fix: the app drops it mid-line
    out = dict(res, text=text, more=False)
    if not text or not text.endswith(out.get("unsure") or "\x00"): out.pop("unsure", None)
    return out


CLAUDE_CTX = 2500     # Claude reads more of the screen than the local model
BUILDERS_LOCK = threading.Lock()
builders = {FMT: builder}


def builder_for(fmt):
    """Test switch (bench/replay.py): another prompt shape on the same model, built and warmed on first use."""
    with BUILDERS_LOCK:
        if fmt not in builders:
            builders[fmt] = Builder(model, fmt)
        return builders[fmt]


AHEAD, AHEAD_LOCK, AHEAD_TTL = OrderedDict(), threading.Lock(), 30.0
AHEAD_STATS = {"made": 0, "hit": 0}
AHEAD_KIND = {}   # key -> "next" (the rest after he takes the ghost) or "branch" (a next letter), for the day counts


def ahead_stats():
    with AHEAD_LOCK: return dict(AHEAD_STATS)


# Look-ahead per day (2026-11-14, efficiency round two; accounting only): data/ahead-days.json, local day ->
# {asked, started, made, used, next_made, next_used, branch_made, branch_used}. asked = typing requests (round five). started = model runs begun for look-ahead
# (a newer key may stop one), made = answers kept, used = answers a later request took. Written at most once a
# minute; the typing track reads it to cut what rarely hits.
AHEAD_DAYS_FILE = DATA / "ahead-days.json"
_ahead_days, _ahead_saved = None, [0.0]


def ahead_count(**add):
    """Under AHEAD_LOCK: add to today's counts; save now and then."""
    global _ahead_days
    if _ahead_days is None:
        try: _ahead_days = json.loads(AHEAD_DAYS_FILE.read_text())
        except Exception: _ahead_days = {}
    day = _ahead_days.setdefault(time.strftime("%Y-%m-%d"), {})
    for k, v in add.items(): day[k] = day.get(k, 0) + v
    if time.time() - _ahead_saved[0] > 60:
        _ahead_saved[0] = time.time()
        for old in sorted(_ahead_days)[:-60]: _ahead_days.pop(old)   # two months
        try:
            tmp = AHEAD_DAYS_FILE.with_suffix(".tmp"); tmp.write_text(json.dumps(_ahead_days, indent=1, sort_keys=True)); tmp.replace(AHEAD_DAYS_FILE)
        except OSError: pass


def normal_space(text):
    """Chromium represents typed spaces as NBSP; use one form for prompts and keys."""
    return text.replace("\u00a0", " ")


def ahead_key(req, pack=None):
    """What makes two suggestion requests the same one (the text before the caret, the screen and the settings; not
    the text after the caret, context provenance or the Claude flags, which the local suggestion does not read)."""
    if pack is None: pack = knowledge.snapshot()
    rest = {k: v for k, v in req.items() if k not in ("before", "early", "after", "field", "ahead", "context_fresh")}
    rest["_know_stamp"] = pack.stamp
    if "context" in rest: rest["context"] = normal_space(rest["context"] or "")
    return normal_space(req.get("before") or "")[-4000:] + "\x00" + json.dumps(rest, sort_keys=True, ensure_ascii=False)


BRANCHES = int(os.environ.get("DRAFTER_BRANCHES", "2"))
# Futures (long round, 2026-11-14, Andrii: "run like parallel realities ... so that the model watches a few ideas about
# what might be coming"): after the shown ghost, the gap before his next key prepares the answers for up to FUTURES
# other next letters, the likeliest first (the model's own next word, the other likely starts in its first-step
# distribution, his own next words), each run to the same sentence length. How many fit is read from his own key
# gaps and the engine's own answer time (futures_k); none on a low battery or near the memory cap.
# Cap 2: replay of the held set with his 1,443 key gaps (bench/long_ghosts.py futures): answered at 0 ms or joined
# K 0 3% · K 1 31% · K 2 38% · K 3 39% · K 4 39%; K 3-4 cost 0.6 more prepared tokens per ask for about one point.
FUTURES = int(os.environ.get("DRAFTER_FUTURES", "2"))
GAPS, COSTS = [], []          # ms between his typing requests (under 1.5 s), ms per prepared answer: the last 200 of each
FUT_INDEX = OrderedDict()     # ahead_key of a shown request -> [(letter, ahead_key of its future)], for /futures
WANT = [""]                   # ahead_key of the newest typing request: a look-ahead for exactly it is not cancelled
INFLIGHT = {}                 # ahead_key -> Event while a look-ahead for it runs (the request for it waits instead)
LAST_ASK = [0.0]
POWER = {"low": False, "at": 0.0}


def note_gap():
    now = time.time()
    if LAST_ASK[0] and now - LAST_ASK[0] < 1.5: GAPS.append((now - LAST_ASK[0]) * 1000); del GAPS[:-200]
    LAST_ASK[0] = now


def power_low():
    """On battery under 30 %: no futures (checked once a minute; `pmset` is cheap but not free)."""
    if time.time() - POWER["at"] > 60:
        POWER["at"] = time.time()
        try:
            out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=2).stdout
            m = re.search(r"(\d+)%", out)
            POWER["low"] = "discharging" in out and bool(m) and int(m.group(1)) < 30
        except Exception: POWER["low"] = False
    return POWER["low"]


def futures_k(cap=None):
    """How many futures fit in his usual gap: the median gap less the look-ahead for the shown ghost, over the median
    answer time; between 1 and FUTURES (2 before any numbers), 0 on a low battery or near the memory cap."""
    cap = FUTURES if cap is None else cap
    if cap <= 0 or power_low(): return 0
    try:
        cap_now = getattr(globals().get("guard"), "_cap", [float(os.environ.get("DRAFTER_CAP_GB", "3.6"))])[0]   # the loaded model's cap
        if model.memory_gb()[0] > cap_now * 0.85: return 0
    except Exception: pass
    if len(GAPS) < 20 or len(COSTS) < 10: return min(cap, BRANCHES)
    gap, cost = sorted(GAPS)[len(GAPS) // 2], max(5.0, sorted(COSTS)[len(COSTS) // 2])
    return max(1, min(cap, int((gap - cost) // cost)))


def branch_letters(before, raw, ghost, n=BRANCHES, alts=()):
    """The next letter of the word branches (round four, bench/branches.py; long round: more of them): the model's own
    next word (what it wrote, shown or not), the other likely starts of the model's first step (`alts`), his own
    likely next words (Words.dist); none that the shown ghost already starts with (typing it keeps the ghost)."""
    out = []
    t = raw.lstrip(" ") if before.endswith((" ", "\n")) else (raw or "")
    if t[:1].strip(): out.append(t[0])
    mine = []
    try: mine = [rest[0] for rest, _ in finisher.dist(before, 3) if rest[:1]]
    except Exception: pass
    for ch in [x for pair in zip(list(alts) + [""] * len(mine), mine + [""] * len(alts)) for x in pair]:
        if ch and ch not in out: out.append(ch)
    return [c for c in out if not (ghost and ghost.startswith(c))][:n]


def look_ahead(req, text, seq=None, raw="", alts=()):
    """A suggestion went out: the one for when he takes it (Tab, or types it through) is worked out now, behind any
    newer key (which stops it), so Tab, Tab, Tab never waits for the model (2026-11-01). Then, in the same gap, the
    answers for the next letter of two word branches (round four): when his key is one of them, the answer is ready
    (bench/branches.py: in chats 75% of new ghosts ready, in AI apps 43-48%, against 1-2% before)."""
    before = req.get("before") or ""
    todo = ([dict(req, before=(before + text)[-4000:], ahead=False, early=False)] if text else [])
    k = futures_k(int(req["futures"]) if req.get("futures") is not None else None)
    letters = branch_letters(before, raw, text, k, alts) if req.get("branches", True) and k and not re.search(r"[\n]$", before) else []
    todo += [dict(req, before=(before + ch)[-4000:], ahead=False, early=False) for ch in letters]
    if not todo: return
    base = ahead_key(req)
    with AHEAD_LOCK:
        FUT_INDEX[base] = [(ch, ahead_key(t)) for ch, t in zip(letters, todo[1 if text else 0:])]
        while len(FUT_INDEX) > 16: FUT_INDEX.popitem(last=False)

    if seq is None:
        with LATEST_LOCK: seq = latest[0]

    def go():
        for k, nxt in enumerate(todo):
            if stale(seq): return
            key = ahead_key(nxt)
            kind = "branch" if k or not text else "next"
            with AHEAD_LOCK: ahead_count(started=1)
            ev = INFLIGHT[key] = threading.Event()
            t0 = time.perf_counter()
            try:
                # long round: a newer key for exactly this text does not stop it (the request waits for it instead);
                # before, the very answer he was about to need was cancelled at his key and worked out again
                res = complete(nxt, low=True, seq=seq, keep=key)
            finally:
                INFLIGHT.pop(key, None)
            res.pop("next", None); res.pop("alts", None)
            if not res.get("stale"): COSTS.append((time.perf_counter() - t0) * 1000); del COSTS[:-200]
            if key != ahead_key(nxt): ev.set(); return  # pack changed while the model was working
            with LATEST_LOCK:
                # kept even when a newer key came meanwhile (it is the exact answer for its text; before, a branch that
                # ended a moment after his key was thrown away)
                if res.get("stale") or res.get("error"): ev.set(); return
                with AHEAD_LOCK:
                    AHEAD[key] = (time.time(), res); AHEAD_STATS["made"] += 1
                    if k or not text: AHEAD_STATS["branch"] = AHEAD_STATS.get("branch", 0) + 1
                    AHEAD_KIND[key] = kind; ahead_count(made=1, **{kind + "_made": 1})
                    while len(AHEAD) > 12: AHEAD_KIND.pop(AHEAD.popitem(last=False)[0], None)
            ev.set()
    threading.Thread(target=go, daemon=True, name="ahead").start()


def complete(req, low=False, seq=None, on_part=None, keep=None):
    """/complete: a suggestion worked out ahead (look_ahead) when he took the last one, else _complete; every
    suggestion with text then starts the next one ahead."""
    # mid-line (engine/fim.py): every answer, the ones worked out ahead too, is cut to fit before the rest of the line
    if low and req.get("mid"): return mid_result(req, _complete(req, low=True, seq=seq, **({"keep": keep} if keep else {})))
    if low: return _complete(req, low=True, seq=seq, **({"keep": keep} if keep else {}))
    if seq is None: seq = request_seq()  # before any cache, snippet or word-only return
    earlier(req.get("app", ""), req.get("context") or "", remember=req.get("context_fresh", True))
    pack = knowledge.snapshot()
    if req.get("ahead", True):
        note_gap()
        hk = ahead_key(req, pack)
        ev = INFLIGHT.get(hk)
        if ev is not None and ev.wait(0.6):
            with AHEAD_LOCK: ahead_count(joined=1)   # long round: answered by the look-ahead already running for it
        with AHEAD_LOCK:
            ahead_count(asked=1)   # round five: typing requests, so used/asked is the share of keys answered at once
            hit = AHEAD.pop(hk, None); kind = AHEAD_KIND.pop(hk, "next")
            if hit and time.time() - hit[0] < AHEAD_TTL: AHEAD_STATS["hit"] += 1; ahead_count(used=1, **{kind + "_used": 1})
        if hit and time.time() - hit[0] < AHEAD_TTL:
            res = dict(hit[1], ahead=True, ms=0)
            raw = res.pop("next", ""); alts = res.pop("alts", ())
            if not res.get("action") and not res.get("replace"): look_ahead(req, res.get("text", ""), seq, raw, alts)
            return res
    res = _complete(req, seq=seq, pack=pack, **({"on_part": on_part} if on_part and not req.get("mid") else {}))
    if req.get("mid"): res = mid_result(req, res)
    raw = res.pop("next", ""); alts = res.pop("alts", ())
    if (req.get("ahead", True) and not res.get("action") and not res.get("replace") and not res.get("src") == "snippet"
            and not res.get("stale") and not res.get("error") and not model.asleep and not model.loading):
        look_ahead(req, res.get("text", ""), seq, raw, alts)
    return res


def futures(req):
    """/futures (long round): the answers prepared for the other next letters after the ghost asked with this very
    request, as other ideas for the same spot: [{"letter", "text", "unsure"}], nothing computed here."""
    with AHEAD_LOCK:
        out = []
        for ch, key in FUT_INDEX.get(ahead_key(req), []):
            hit = AHEAD.get(key)
            if hit and time.time() - hit[0] < AHEAD_TTL and hit[1].get("text") and not hit[1].get("action") and not hit[1].get("replace"):
                out.append({"letter": ch, "text": hit[1]["text"], "unsure": hit[1].get("unsure", "")})
        return {"futures": out, "k": futures_k()}


# Short ghosts (2026-11-13, app.log 6-13 November: under 5 letters he took 3%, 5-9 letters 30%; bench/lengths.py):
# the app sends min_letters (setting minGhost); a gated suggestion that adds fewer letters goes on past its sure words
# while each token stays >= GROW, up to GROW_WORDS words, and what is still short is not offered.
# Held set (137 lines after the 8 November cutoff), letters saved by ghosts of 5+ letters, AI apps / chats:
# hide only 16.3% / 8.1%, grow 0.2 23.4% / 9.4%, grow 0.05 30.9% / 16.6%, grow 0 31.8% / 16.6% (live today 16.2% / 8.1%).
GROW = float(os.environ.get("DRAFTER_GROW", "0.05"))
GROW_WORDS = int(os.environ.get("DRAFTER_GROW_WORDS", "6"))


def short(req, text):
    n = int(req.get("min_letters") or 0)
    return bool(n) and bool(text) and gatecore.letters(text) < n


def _complete(req, low=False, seq=None, pack=None, on_part=None, keep=None):
    before, app, title, context, screen = parts(req, remember=not low)
    after, after_line = mid_line(req) if req.get("mid") else ("", "")
    b = builder_for(req.get("fmt") or FMT)
    bars = tuple(req["bars"]) if req.get("bars") else None
    # chips: the Drafter app asks for them separately (/chip, after a pause) so typing never waits for a chip read;
    # other callers (Aleph's panel) still get them here
    chips = req.get("chips", True)
    # a quick insert: ";m" -> his email, "my email is" -> the same (engine/snippets.py), before anything else
    snip = snippets.offer(before)
    if snip:
        return {"text": "", "action": snip, "src": "snippet", "ms": 0}
    sel = selector() if req.get("selector", True) and req.get("gate", True) else None
    if req.get("memory", True) and not sel:
        # his own phrase, said before: answer at once, the model is not asked (bench/memory_eval.py)
        t = time.perf_counter()
        said, hits = phrases.suggest(before)
        if said and not short(req, clean(before, said)) and not (chips and actions.detect(before)):
            return {"text": clean(before, said), "more": False, "src": "memory", "hits": hits,
                    "ms": round((time.perf_counter() - t) * 1000, 1)}

    line = before.split("\n")[-1]
    mid = bool(re.search(r"[\w'’-]$", line))
    g = gate() if req.get("gate", True) else None
    ai = any(k in (app or "").lower() for k in AI_APPS)
    if mid and req.get("fix"):
        # the word being typed is no word he writes, but one he writes often is a letter (or a layout) away: a ghost
        # that replaces (engine/words.py Words.fix; the app shows "→ word" and Tab swaps it)
        t = time.perf_counter()
        fx = finisher.fix(before)
        if fx:
            return {"text": fx["new"], "replace": fx["old"], "kind": fx["kind"], "src": "fix", "ms": round((time.perf_counter() - t) * 1000, 1)}
    if pack is None: pack = knowledge.snapshot()  # one check for this request's finisher and booster
    if mid and req.get("words", True) and (g or {}).get("words_first", req.get("words_first", False)):
        # the instant word finisher: his own words, no model (engine/words.py)
        t = time.perf_counter()
        f, source = words_mod.finish_with_source(finisher, before, (g or {}).get("words", (2, 0.6, 1)), pack)
        if f and not short(req, f):
            if source == "know": knowledge.offered += 1
            return {"text": f, "src": source, "ms": round((time.perf_counter() - t) * 1000, 1)}
    # his own word first (round four, Codex review "personal word path first"): when the word gate approves, the word
    # shows at once; the model runs only to extend it (bench/wordgate.py, before/after on held-out lines)
    if sel and g:
        # one calibrated selector (round four, bench/selector.py): memory and his word answer at once when their chance
        # clears the bar; else the model, whose first word must clear the same bar
        t = time.perf_counter()
        best = offers_now(sel, before, ai, mid) if req.get("words", True) and req.get("memory", True) else None
        if best:          # each source's own minimum length is in offers_now (memory 5 letters, his word 3)
            return {"text": best[1], "src": best[2], "sel": round(best[0], 3), "ms": round((time.perf_counter() - t) * 1000, 1)}
    first_word = word_first(before, ai) if mid and req.get("words", True) and req.get("word_first", True) and g and not sel else ""
    if first_word and (on_part is None or model.asleep or model.loading):
        return {"text": first_word, "src": "words", "first": True, "ms": 0}
    if first_word: on_part({"part": first_word, "src": "words", "ms": 0})
    if model.asleep or model.loading:
        # the text model steps aside while a call is read (or is loading back): his own words only, at once, never
        # queued behind the reload
        f, source = words_mod.finish_with_source(finisher, before, (g or {}).get("words", (2, 0.6, 1)), pack) if mid and req.get("words", True) else ("", "")
        if short(req, f): f = ""
        if f and source == "know": knowledge.offered += 1
        return {"text": f, "src": source if f else "asleep", "ms": 0}

    t_in = time.perf_counter()

    def job(cancelled):
        t = time.perf_counter()
        act = actions.detect(before) if chips else None
        if act:
            found = actions.cached(act, before, lambda p, max_tokens=90: ask(p, max_tokens, cancelled))
            if found:
                return {"text": "", "action": found, "ms": round((time.perf_counter() - t) * 1000)}
        # /complete may carry Keys.contextFor's previous screen while a fresh read runs.
        # complete() tracks fresh context before any fast return; this job never moves it.
        ids, heal, stable = b.ids_stable(before, app, title, context, earlier(app, context, remember=False), *extras(req), after)
        prep = round((time.perf_counter() - t) * 1000, 1)
        n = max(1, min(int(req.get("max_tokens") or MAX_TOKENS), 16))
        if g:
            # the decision gate decides on the first word, then sure words follow (engine/gatecore.py)
            th = g["th"]["ai" if ai else "chat"]
            finish = finisher.finish(before, 2, 0.5, 1) if mid else ""   # a gate feature, as bench/gate.py reads it
            seen = {}

            def decide(toks):
                f, _ = gatecore.features(toks, before, ai, finish)
                p = gatecore.score(g["w"], f) if f else 0.0
                seen["p"] = p
                if sel and f:
                    ps = gatecore.score(sel["w"], gatecore.sel_features("model", toks[-1][0], before, ai, model_p=p, model_low=float(p < th)))
                    seen["sel"] = ps
                    return ps if ps >= sel["th"] else None
                return p if p >= th else None
            # the word booster (2026-11-01): his own next words mixed into the model's guess, at the share the gate was
            # fit with (data/gate.json "boost"; 0 = off). His words update with every line he sends (/typed).
            lam = float(g.get("boost", 0) or 0) if req.get("boost", True) else 0.0
            boost = words_mod.boost_targets(finisher, before, heal, knowledge=pack, context=context, title=title) if lam else None
            min_letters = int(req.get("min_letters") or 0)
            # the lighter tail (round two): the app's per-app length (Keys.length: "tail" bar and "tail_words")
            tail = float(req["tail"]) if req.get("tail") is not None else None
            tail_words = int(req.get("tail_words") or 8)
            # sentence-length ghosts (long round): the app's ghostLength "phrase" / "sentence" (Keys.length)
            length = req.get("length") or "word"
            run_mode = None
            if length in gatecore.RUN_MODES:
                run_mode = {"mode": length, "floor": float(req.get("floor", gatecore.RUN_FLOOR)), "kind": req.get("floor_kind", "prod"),
                            "likely": float(req.get("likely", gatecore.RUN_LIKELY))}
                tail = None
            part_fn = None
            if on_part is not None:
                def part_fn(raw, sure):
                    o = clean(before, raw.replace("\ufffd", ""))
                    if not o or short(req, o) or cancelled(): return
                    if first_word and not gatecore.extends(o, first_word): return
                    msg = {"part": o, "src": "gate", "ms": round((time.perf_counter() - t) * 1000, 1)}
                    rest = raw[sure:]
                    if rest.strip() and o.endswith(rest): msg["unsure"] = rest
                    on_part(msg)
            seen["raw"] = ""
            cap = max(4, min(32, int(req.get("cap") or gatecore.RUN_CAP))) if run_mode else None
            fill = None
            if after_line:
                # mid-line (engine/fim.py): word mode, the ghost ends where the gap is filled
                rest = model.encode(after_line)
                fill = {"rest": rest[0] if rest else None, "text": after_line}
                run_mode, tail, cap, min_letters, n = None, None, None, 0, fim.TOKENS
            text, gp, first, total = model.complete_gated(ids, heal, decide, more=g.get("more", 0.5), max_words=int(g.get("max_words", 3)),
                                                          max_tokens=cap if run_mode else (max(n, min(24, 2 * tail_words + 2)) if tail is not None else n), cancelled=cancelled,
                                                          screen=screen, boost=boost, lam=lam, min_letters=min_letters,
                                                          grow=GROW if min_letters and not run_mode else None, grow_words=GROW_WORDS,
                                                          tail=tail, tail_words=tail_words, on_part=part_fn, run=run_mode, alts=FUTURES if req.get("ahead", True) else 0,
                                                          stable=stable, **({"mid": fill} if fill else {}))
            sure = getattr(model, "last_sure", None)
            if run_mode: tail = -1.0     # the sure part / lighter split below applies to the run too
            seen["alts"] = list(getattr(model, "last_alts", []) or [])
            seen["conf"] = list(getattr(model, "last_conf", []) or [])
            seen["raw"] = getattr(model, "last_raw", "") or ""
            out = clean(before, text.replace("\ufffd", ""))
            if short(req, out): out = ""
            if first_word:
                if not gatecore.extends(out, first_word):
                    return {"text": first_word, "src": "words", "first": True, "gate": round(seen.get("p", 0), 3), "next": seen["raw"], "ms": round(total)}
                res = {"text": out, "src": "gate", "first": True, "gate": round(seen.get("p", 0), 3), "next": seen["raw"], "alts": seen["alts"], "first_ms": 0, "ms": round(total)}
                rest = text[getattr(model, "last_sure", 0) or 0:] if tail is not None else ""
                if rest.strip() and out.endswith(rest) and len(out) - len(rest) >= len(first_word): res["unsure"] = rest
                return res
            fall, source = words_mod.finish_with_source(finisher, before, g.get("words", (2, 0.6, 1)), pack) if mid and not out and req.get("words", True) and not sel else ("", "")
            if short(req, fall): fall = ""
            if fall:
                # the gate said no: the word being typed, from his own words, when that is clear (bench/gate.py
                # policy_from, as measured: first three words of a line saved 4.5% -> 8.6% in Beeper, 16.5 -> 21% in Claude)
                if source == "know": knowledge.offered += 1
                return {"text": fall, "src": source, "gate": round(seen.get("p", 0), 3), "next": seen["raw"], "ms": round(total)}
            res = {"text": out, "src": "gate", "gate": round(seen.get("p", 0), 3), "next": seen["raw"], "alts": seen["alts"], "first_ms": round(first), "ms": round(total),
                   "t": dict(getattr(model, "timing", {}) or {}, prep=prep, queue=round((t - t_in) * 1000, 1))}
            if run_mode and out:
                res["conf"] = seen["conf"]; res["why"] = getattr(model, "last_why", None)
            rest = text[sure:] if sure is not None and tail is not None else ""
            if out and rest.strip() and out.endswith(rest): res["unsure"] = rest
            return res
        # short and sure (Andrii, 2026-10-19): at most 3 words, and only the words the model gives >= 50% to
        # (bench: shown on 9/30 cut messages instead of 29, wrong on 3 instead of 19)
        soft = float(req.get("soft", 0) or 0)
        text, first, total = model.complete(None, raw_ids=ids, max_tokens=n, cancelled=cancelled, heal=heal,
                                            min_p=MIN_P, max_words=int(req.get("max_words") or MAX_WORDS), bars=bars, soft=soft, soft_from=int(req.get("soft_from", 2)), screen=screen,
                                            stable=stable)
        text = text.replace("\ufffd", "")
        out = clean(before, text)
        if short(req, out): out = ""
        res = {"text": out, "more": bool(model.hit_limit and out and "\n" not in text), "first_ms": round(first), "ms": round(total)}
        # the lighter tail: the words after the sure part (the app draws them lighter; Tab still takes one word)
        if soft and model.sure_len is not None:
            tail = text[model.sure_len:].strip()
            if tail and out.rstrip().endswith(tail): res["unsure"] = tail
        return res
    cancel = (lambda: stale(seq) and WANT[0] != keep) if keep else None
    return run(job, low=low, seq=seq, cancel=cancel)


# ---- model catalog (2026-11-15, engine/catalog.py) ----
DOWNLOADS = catalog.Downloads()
SWITCH = {"busy": False}


def set_cap(gb):
    """The guard and MLX's limit for the model about to load (never under the engine's own DRAFTER_CAP_GB)."""
    guard._cap[0] = max(CAP, float(gb))
    model_mod.set_limit(guard._cap[0])


def rebuild_head():
    """After a switch: the head in the new tokenizer, read in (from its file when there), token pieces again."""
    with BUILDERS_LOCK:
        for b in builders.values(): b.refresh()
    model.warm(builder.head_ids)
    model.pieces()
    with AHEAD_LOCK: AHEAD.clear(); AHEAD_KIND.clear(); FUT_INDEX.clear()


def models_view():
    """GET /models: the catalog, what is here, what downloads, which is loaded and which suits this Mac."""
    mac = catalog.machine()
    cur = CURRENT["entry"]
    cur_gb = model.loaded_gb() if cur else 0.0
    rec, why = catalog.recommend(CATALOG, mac["total_gb"], mac["free_gb"], cur_gb)
    rows = []
    for m in CATALOG:
        d = DOWNLOADS.state(m)
        rows.append({**m, "downloaded": d["state"] == "done", "download": d, "speed": catalog.speed_mark(m),
                     "quality": catalog.quality_mark(CATALOG, m)})
    return {"models": rows, "current": cur["id"] if cur else None, "recommended": rec, "why": why,
            "machine": {**mac, "budget_gb": catalog.budget_gb(mac["total_gb"], mac["free_gb"], cur_gb)},
            "switching": SWITCH["busy"] or model.loading}


def switch_to(target):
    """On the worker thread: unload, load `target` (live when it fails), head again. Numbers only in the log."""
    try:
        got, err, secs = catalog.switch(model, target, LIVE_ENTRY, ADAPTER, rebuild=rebuild_head, set_cap=set_cap,
                                        data=DATA, free_gb=catalog.machine()["free_gb"])
        if got is not None: CURRENT["entry"] = got
        cur = (CURRENT["entry"] or {}).get("id")
        print(f"model switch: {target['id']} -> {cur} in {secs:.1f} s, mlx {model.memory_gb()[0]:.2f} GB, cap {guard._cap[0]} GB"
              + (f", {err}" if err else ""), flush=True)
        return {"ok": err is None, "current": cur, "error": err, "seconds": round(secs, 1)}
    finally:
        SWITCH["busy"] = False


def warm_claude():
    """On focus: the Claude worker starts before he types, so the first pause does not wait for it."""
    st = settings_load()
    if claude_on("pause", st):      # the pause and early workers start with the day pack: only when that lane is on
        claude_type.warm(st.get("claudeModel", "sonnet"))
    if claude_on("facts", st):
        import facts as facts_mod
        facts_mod.calendar()     # the calendar read starts now (GAM, 1-3 s), kept 10 minutes


KEYS = [0]     # /complete calls, one per key: a newer key stops a Claude pause request still on its way


def pause(req):
    """Claude writes the rest of the sentence after a pause (engine/claude_type.py). Off with `claudeTyping` false,
    offline, or without the claude CLI; any newer key cancels it."""
    st = settings_load()
    if not claude_on("pause", st): return {"text": "", "src": "off"}
    k0 = KEYS[0]
    r = claude_type.answer((req.get("before") or "")[-4000:], req.get("app", ""), (req.get("title") or "")[:80],
                           (req.get("context") or "")[-CLAUDE_CTX:], model=req.get("model") or st.get("claudeModel", "sonnet"),
                           cancelled=lambda: KEYS[0] != k0, known=_known, after=(req.get("after") or "")[:1000],
                           field=int(req.get("field") or 0), notes=str(req.get("notes") or "")[:600])
    if not r: return {"text": "", "src": "claude", "skipped": True}
    text, said = r["text"], r["text"]
    if text and st.get("claudeGate", True):
        text = gate_claude(req, text, cancelled=lambda: KEYS[0] != k0)
    if (DATA / "debug").exists():
        print("pause:", r["model"], r["ms"], "early" if r.get("early") else "", repr(r["raw"][:120]), "->", repr(text), flush=True)
    return {"text": text, "src": "claude", "ms": r["ms"], "first_ms": r["first_ms"], "model": r["model"], "early": bool(r.get("early")),
            "cut": len(said) - len(text)}


def proof(req):
    """The whole message so far, proofread by Claude (engine/proofread.py). Off with `claudeTyping` or `proofread`
    false, or offline; a newer key cancels it."""
    st = settings_load()
    if not claude_on("proofread", st): return {"edits": [], "src": "off"}
    import proofread
    k0 = KEYS[0]
    r = proofread.check(str(req.get("text") or ""), str(req.get("app") or "")[:40], model=req.get("model") or st.get("claudeModel", "sonnet"),
                        cancelled=lambda: KEYS[0] != k0)
    if not r: return {"edits": [], "skipped": True}
    if (DATA / "debug").exists(): print("proofread:", r["ms"], [(e["old"], e["new"]) for e in r["edits"]], flush=True)
    return r


def facts(req):
    """A question on screen that his calendar or saved texts answer (engine/facts.py). Off with `claudeTyping` or
    `facts` false, or offline; a newer key cancels it."""
    st = settings_load()
    if not claude_on("facts", st): return {}
    import facts as facts_mod
    k0 = KEYS[0]
    r = facts_mod.answer(str(req.get("context") or "")[-3000:], str(req.get("before") or "")[-1000:], str(req.get("app") or "")[:40],
                         model=req.get("model") or st.get("claudeModel", "sonnet"), cancelled=lambda: KEYS[0] != k0)
    if (DATA / "debug").exists(): print("facts:", r, flush=True)
    return r


def translate(req):
    """His message in the other language (engine/translate.py). Off with `claudeTyping` or `translate` false, or
    offline; a newer key cancels it."""
    st = settings_load()
    if not claude_on("translate", st): return {}
    import translate as translate_mod
    k0 = KEYS[0]
    r = translate_mod.translate(str(req.get("text") or ""), str(req.get("target") or ""), str(req.get("context") or "")[-1500:],
                                str(req.get("app") or "")[:40], model=req.get("model") or st.get("claudeModel", "sonnet"),
                                cancelled=lambda: KEYS[0] != k0)
    if (DATA / "debug").exists(): print("translate:", r, flush=True)
    return r


def local_rewrite(text, instr, notes=""):
    """The selection rewritten by the local model (base, his-writing layer off): the offline way for /rework. `notes`:
    his writing instructions, one line when there are some."""
    prompt = ("Перепиши текст за вказівкою. Відповідай лише новим текстом, без пояснень і без лапок. Мова та сама, що в "
              "тексті, якщо вказівка не каже інакше. Rewrite the text as the instruction says; reply with the new text only.\n"
              + (f"Як він пише / his writing instructions: {notes}\n" if notes else "")
              + f"Вказівка / instruction: {instr}\n\nТекст / text:\n{text}")
    s = model.tok.apply_chat_template([{"role": "user", "content": prompt}], tokenize=False, add_generation_prompt=True)
    if "<think>" in (model.tok.chat_template or "") and "Instruct-2507" not in model.repo:
        s += "<think>\n\n</think>\n\n"
    ids = model.tok.encode(s, add_special_tokens=False)
    n = min(900, int(len(model.tok.encode(text)) * 2) + 40)
    # stops when he types again (a newer suggestion) or the request gave up, so the one model is free for typing
    # (Codex review 2026-11-01: a dismissed rework held it for up to 900 tokens)
    start, gone = latest[0], threading.Event()
    stop = lambda: gone.is_set() or latest[0] != start
    r = run(lambda cancelled: {"text": model.oneshot(ids, max_tokens=n, cancelled=stop).strip().strip('"«»').strip()}, newest=False, timeout=40)
    gone.set()
    return (r or {}).get("text", "")


def rework(req):
    """⌥Tab on a selection (engine/rework.py): shorter, fix, clearer, warmer, formal, list, the other language, or his
    own words. Claude when online, else the local model. Only when he picks a command; setting `rework`.
    From the Quick panel (`from: quick`, app/Quick.swift) with `rework` off: the local model only, nothing sent."""
    st = settings_load()
    if not cloud.allowed("rework", st) and (req.get("from") != "quick" or req.get("warm")): return {}
    import rework as rework_mod
    m = req.get("model") or st.get("claudeModel", "sonnet")
    if req.get("warm"):
        if claude_on("rework", st): rework_mod.warm(m)
        return {"ok": True}
    r = rework_mod.rework(str(req.get("text") or ""), str(req.get("cmd") or ""), str(req.get("custom") or ""),
                          str(req.get("app") or "")[:40], model=m, online=claude_on("rework", st), local=local_rewrite,
                          **({"notes": str(req["notes"])} if (req.get("notes") or "").strip() else {}))
    if (DATA / "debug").exists(): print("rework:", r, flush=True)
    return r


# The Claude gate (2026-11-01, Codex review: local silence is doubt, not room for Claude): his own model reads
# Claude's words and the guess stops before the first one it finds unlikely. bench/claudegate.py on the 184 pause
# spots: chats (0.05, 0.01) took wrong Claude ghosts from 65 to 28 per 100 pauses at the same letters saved; in AI
# apps the milder (0.01, 0.001) from 79 to 54 for 3.0 -> 2.8% saved.
CLAUDE_CUT = {"chat": (0.05, 0.01), "ai": (0.01, 0.001)}
CLAUDE_GATE = {"scored": 0, "cut": 0, "dropped": 0}


def gate_claude(req, text, cancelled=lambda: False):
    before = (req.get("before") or "")[-4000:]
    app = req.get("app", "")
    words = score_words(before, app, req.get("title", ""), req.get("context") or "", text, cancelled=cancelled, extra=extras(req))
    if not words: return text          # no score (busy, timeout): his model has no say this time
    tg, tm = CLAUDE_CUT["ai" if any(k in (app or "").lower() for k in AI_APPS) else "chat"]
    out = claude_type.cut_words(words, tg, tm)
    CLAUDE_GATE["scored"] += 1
    if out != text: CLAUDE_GATE["cut" if out else "dropped"] += 1
    return out


def _known(w): return finisher.uni.get(w.lower(), 0) >= 2


def score_words(before, app, title, context, text, cancelled=lambda: False, extra=("", "")):
    """His own model reads `text` after the caret (model.score) -> [(word, [token p])] or None; the local prompt is
    built exactly as for a suggestion, so the cache it already holds is reused."""
    before, app, title, context, screen = parts({"before": before, "app": app, "title": title, "context": context})
    ids, heal, stable = builder_for(FMT).ids_stable(before, app, title, context, earlier(app, context, remember=False), *extra)
    return run(lambda c: {"words": model.score(ids, heal, text, cancelled=lambda: c() or cancelled(), screen=screen, stable=stable)}, newest=False, timeout=3).get("words")


def ask_early(req):
    """Every main /complete: when a word just ended, Claude starts on the rest of the sentence on its second worker,
    so a pause finds the answer ready (claude_type.early). Same settings and limits as the pause."""
    before = (req.get("before") or "")[-4000:]
    line = before.split("\n")[-1].strip()
    if not req.get("early") or not before.endswith((" ", "\n")) or len(line) < 6: return
    if not claude_on("early"): return
    st = settings_load()
    claude_type.early(before, req.get("app", ""), (req.get("title") or "")[:80], (req.get("context") or "")[-CLAUDE_CTX:],
                      model=st.get("claudeModel", "sonnet"), known=_known, after=(req.get("after") or "")[:1000],
                      field=int(req.get("field") or 0), notes=str(req.get("notes") or "")[:600])


LOCAL_HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}", f"[::1]:{PORT}"}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, obj, code=200):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)

    def stream(self, work):
        """Two-step ghost (round two, 2026-11-13): one JSON object per line, the first words as soon as they exist
        ({"part": ...}), then the whole answer as usual with "final": true. The model writes the parts from its worker
        thread while this one waits; a gone reader only stops the parts."""
        self.send_response(200); self.send_header("Content-Type", "application/x-ndjson"); self.send_header("Connection", "close")
        self.end_headers()
        lock, alive = threading.Lock(), [True]

        def line(obj):
            with lock:
                if not alive[0]: return
                try: self.wfile.write(json.dumps(obj, ensure_ascii=False).encode() + b"\n"); self.wfile.flush()
                except OSError: alive[0] = False
        line(dict(work(line), final=True))
        self.close_connection = True

    def foreign(self, post=False):
        """A web page open in any browser reaches 127.0.0.1 too, so the address alone proves nothing. Browsers mark
        their requests (Origin, Sec-Fetch-*), a page under another name that points here (DNS rebinding) shows its own
        Host, and a page can only POST application/json after a preflight this server never answers. The app
        (URLSession) and Aleph's hub (urllib) send none of those marks and always send application/json."""
        h = self.headers
        if self.client_address[0] not in ("127.0.0.1", "::1"): return True
        if h.get("Origin") or h.get("Sec-Fetch-Site") or h.get("Sec-Fetch-Mode"): return True
        if (h.get("Host") or "").lower() not in LOCAL_HOSTS: return True
        return post and (h.get("Content-Type") or "").split(";")[0].strip().lower() != "application/json"

    def do_GET(self):
        if self.foreign(): return self.send({"error": "forbidden"}, 403)
        if self.path.split("?", 1)[0] == "/people":
            from urllib.parse import urlsplit, parse_qs
            q = parse_qs(urlsplit(self.path).query).get("q", [""])[0]
            return self.send({"people": knowledge.people(q)})
        if self.path.split("?", 1)[0] in ("/context", "/entity", "/context/brief"):
            # a thing's context from data/entities.json (engine/entities.py): /context?q=&level=1..3, /context/brief?q=,
            # /entity?q=. Local only (the check above), built from stored records, nothing leaves the Mac
            from urllib.parse import urlsplit, parse_qs
            qs = parse_qs(urlsplit(self.path).query)
            q = qs.get("q", [""])[0]
            if not settings_load().get("contextPacks", True): return self.send({"error": "context packs are off"}, 403)
            route = self.path.split("?", 1)[0]
            if route == "/entity": return self.send(entity_store().entity(q))
            if route == "/context/brief": return self.send(entity_store().brief(q))
            try: level = int(qs.get("level", ["2"])[0])
            except ValueError: level = 2
            return self.send(entity_store().context(q, level))
        if self.path == "/settings":
            st = settings_load()
            return self.send({"paused": st.get("paused", False), "voice": st.get("voice", False), "skip": st.get("skip", []), "model": st.get("model") or model.repo,
                              "voiceFast": st.get("voiceFast"), "voiceCareful": st.get("voiceCareful"),
                              "actions": [{"id": a.ID, "on": a.ID not in set(st.get("actions_off", [])),
                                           "about": (a.__doc__ or "").strip().splitlines()[0]} for a in actions.ALL],
                              "words": len(dictionary.load()["words"])})
        if self.path == "/edits":
            return self.send({"edits": edits.waiting()})
        if self.path.split("?", 1)[0] == "/pending":
            # ?wait=N (the app, 2026-11-14): held up to N s (max 30) until a job comes, in place of a request every second
            from urllib.parse import urlsplit, parse_qs
            try: wait = min(max(float(parse_qs(urlsplit(self.path).query).get("wait", ["0"])[0]), 0.0), 30.0)
            except ValueError: wait = 0.0
            return self.send({"jobs": actions.take_pending(wait)})
        if self.path == "/models": return self.send(models_view())
        if self.path == "/health":
            act, peak = model.memory_gb()
            return self.send({"ok": True, "model": model.repo, "catalog": (CURRENT["entry"] or {}).get("id"), "adapter": model.adapter, "lora_merged": len(getattr(model, "fused", []) or []), "strength": round(getattr(model, "strength", 1.0) * 100), "fmt": FMT, "pid": os.getpid(), "head_tokens": len(builder.head_ids), "head_file": getattr(model, "head_file", None), "mark_hits": getattr(model, "mark_hits", 0), "rss_gb": round(guard.rss_gb(), 2),
                              "mlx_active_gb": round(act, 2), "mlx_peak_gb": round(peak, 2), "cap_gb": guard._cap[0],
                              "asleep": model.asleep, "sleeps": model.sleeps, "dist_used": getattr(model, "dist_used", 0), "word_gate": bool(wordgate()), "boost": (gate() or {}).get("boost", 0), "people": len(people_mem.chats), "ahead": ahead_stats(), "know": knowledge.stats(),
                              "words": len(dictionary.load()["words"]), "actions": [a.ID for a in actions.ALL],
                              "model_link": {"provider": provider.kind(), "connected": provider.connected(), "error": provider.state["last_error"]},
                              "claude_early": claude_type.early_stats(), "claude_gate": CLAUDE_GATE,
                              "proofread": sys.modules["proofread"].stats() if "proofread" in sys.modules else {},
                              "facts": sys.modules["facts"].stats() if "facts" in sys.modules else {},
                              "translate": sys.modules["translate"].stats() if "translate" in sys.modules else {},
                              "rework": sys.modules["rework"].stats() if "rework" in sys.modules else {}})
        self.send({"error": "not found"}, 404)

    def do_POST(self):
        if self.foreign(post=True): return self.send({"error": "forbidden"}, 403)
        n = int(self.headers.get("Content-Length") or 0)
        try: req = json.loads(self.rfile.read(n) or b"{}")
        except Exception: return self.send({"error": "bad json"}, 400)
        if self.path == "/futures": return self.send(futures(req))
        if self.path == "/complete":
            try: WANT[0] = ahead_key(req)   # long round: a look-ahead for exactly this text keeps running
            except Exception: WANT[0] = ""
            seq = request_seq()  # cancel before even the optional Claude helper can wait
            KEYS[0] += 1
            t_recv = time.perf_counter()
            try: ask_early(req)
            except Exception as e: print("early:", e, flush=True)
            early_ms = round((time.perf_counter() - t_recv) * 1000, 1)

            def timed(res):
                # round three: the whole stay in the engine, and the Claude early lane's share of it
                if isinstance(res.get("t"), dict): res["t"].update(early=early_ms, all=round((time.perf_counter() - t_recv) * 1000, 1))
                return res
            if req.get("stream"): return self.stream(lambda part: timed(complete(req, seq=seq, on_part=part)))
            return self.send(timed(complete(req, seq=seq)))
        if self.path == "/pause": return self.send(pause(req))
        if self.path == "/proofread": return self.send(proof(req))
        if self.path == "/facts": return self.send(facts(req))
        if self.path == "/translate": return self.send(translate(req))
        if self.path == "/rework": return self.send(rework(req))
        if self.path == "/synonyms":
            import synonyms
            return self.send(synonyms.handle(req))
        if self.path == "/score":     # bench/claudegate.py: how his model reads a given continuation
            t = time.perf_counter()
            w = score_words(req.get("before") or "", req.get("app", ""), req.get("title", ""), req.get("context") or "", req.get("text") or "", extra=extras(req))
            return self.send({"words": w, "ms": round((time.perf_counter() - t) * 1000, 1)})
        if self.path == "/chip": return self.send(chip(req))
        if self.path == "/reply": return self.send(reply(req))
        if self.path == "/command":
            import command
            return self.send(command.plan(str(req.get("text") or ""), lambda p, max_tokens=90: ask(p, max_tokens)))
        if self.path == "/lookup":
            import lookup
            return self.send(lookup.search(req))
        if self.path == "/snippet":
            import command
            return self.send({"done": command.save_snippet(str(req.get("key") or ""), str(req.get("text") or ""))})
        if self.path == "/ask":
            import ask as notes_ask
            return self.send(notes_ask.answer(str(req.get("text") or "")))
        if self.path == "/followups":
            # on his Tab: each follow-up into Aleph as a reminder for the next working morning at 10:00
            import datetime as dt
            d = dt.datetime.now() + dt.timedelta(days=1)
            while d.weekday() >= 5: d += dt.timedelta(days=1)
            due = d.replace(hour=10, minute=0).strftime("%Y-%m-%dT%H:%M")
            added = 0
            for what in (req.get("items") or [])[:8]:
                try:
                    if not integrations.available("aleph"): raise OSError("Aleph is off on this Mac")
                    r = json.loads(urllib.request.urlopen(urllib.request.Request(local.setting("aleph", "url") + "/api/do",
                        data=json.dumps({"moves": [{"type": "remind", "what": str(what)[:200], "due": due}]}).encode(),
                        headers={"Content-Type": "application/json"}), timeout=10).read())
                    added += 1 if r["results"][0].get("ok") else 0
                except Exception as e:
                    print("followups:", e, flush=True)
            return self.send({"added": added, "due": due})
        if self.path == "/prep":
            try: return self.send(prep.about(req.get("text") or ""))
            except Exception as e: return self.send({"lines": [], "error": str(e)[:200]})
        if self.path == "/rewrite": return self.send(rewrite(req))
        if self.path == "/outline": return self.send(outline(req))
        if self.path == "/note":
            text = (req.get("text") or "").strip()
            if not text: return self.send({"error": "empty"})
            event = req.get("event") if isinstance(req.get("event"), dict) else None
            cloud = bool(req.get("call")) and claude_on("call_notes")   # the call summary: `callNotes` and online
            return self.send(run(lambda c: notes.make(text, lambda p, n=60: ask(p, n), req.get("audio", ""), bool(req.get("call")), bool(req.get("dry")), event,
                                                      cloud=cloud), newest=False, timeout=110))
        if self.path == "/sleep":
            # a long call is read again (Voice.transcribe): the text model gives its memory back and idle `claude`
            # helpers stop; it loads back on /wake, or by itself after `secs` (a reading that never ends)
            # idle (the app, 2026-11-14): no typing for `textIdleMin` minutes; no timer, the app's /wake (focus in a
            # field or a typing request) brings it back; one-off prompts (oneshot) still load it on demand
            idle = bool(req.get("idle"))
            secs = 86400.0 if idle else max(10.0, min(float(req.get("secs", 600) or 600), 3600.0))
            r = run(lambda c: {"slept": model.sleep(secs, retrain=bool(req.get("retrain")))}, newest=False, timeout=15)
            r["claude_stopped"] = claude_type.reap(0)
            if not idle:
                threading.Timer(secs + 1, lambda: run(lambda c: {"woke": model.wake(force=False)}, newest=False, timeout=30)).start()
            gb = model.memory_gb()[0]
            print(f"sleep {'idle' if idle else f'{secs:.0f}s'}: mlx {gb:.2f} GB, claude stopped {r['claude_stopped']}", flush=True)
            return self.send({**r, "mlx_active_gb": round(gb, 2)})
        if self.path == "/wake":
            was, t = model.asleep, time.time()
            r = run(lambda c: {"woke": model.wake()}, newest=False, timeout=30)
            if was: r["load_s"] = round(time.time() - t, 2); print(f"wake: loaded in {r['load_s']}s (head included)", flush=True)
            return self.send({**r, "mlx_active_gb": round(model.memory_gb()[0], 2)})
        if self.path == "/strength":
            # the app saved a new "Personal style" (0-100): his layer is merged again at that scale, in the one model
            # (a few seconds, typing answers from his words meanwhile); answers prepared at the old strength go
            want = strength_setting({"personalStrength": req.get("value", 100)})
            r = run(lambda c: {"seconds": round(model.set_strength(want), 2)}, newest=False, timeout=60)
            with AHEAD_LOCK: AHEAD.clear(); AHEAD_KIND.clear(); FUT_INDEX.clear()
            print(f"strength {round(want * 100)}%: {r.get('seconds')} s", flush=True)
            return self.send({**r, "strength": round(model.strength * 100)})
        if self.path == "/model":
            # Settings > Typing > Model: the app saves "typingModel" only after this answers ok
            target = catalog.entry(CATALOG, req.get("id"))
            if target is None: return self.send({"ok": False, "error": "unknown model"}, 404)
            if (CURRENT["entry"] or {}).get("id") == target["id"] and not model.asleep:
                return self.send({"ok": True, "current": target["id"], "seconds": 0})
            if SWITCH["busy"]: return self.send({"ok": False, "error": "busy", "current": (CURRENT["entry"] or {}).get("id")})
            SWITCH["busy"] = True
            return self.send(run(lambda c: switch_to(target), newest=False, timeout=300))
        if self.path in ("/models/download", "/models/cancel"):
            # only on his press in Settings: the one network use besides what AGENTS.md lists
            target = catalog.entry(CATALOG, req.get("id"))
            if target is None: return self.send({"ok": False, "error": "unknown model"}, 404)
            if self.path == "/models/cancel": return self.send({"ok": DOWNLOADS.cancel(target["id"]), **DOWNLOADS.state(target)})
            return self.send({"ok": True, **DOWNLOADS.start(target)})
        if self.path == "/prefill":
            warm_claude()
            before, app, title, context, screen = parts(req)
            ids, _, stable = builder.ids_stable(before, app, title, context, earlier(app, context, remember=False), *extras(req))   # builder_for(FMT) is this one
            r = run(lambda c: {"fed": model.prefill(ids, screen=screen, stable=stable)}, newest=False, timeout=5)
            return self.send(r)
        if self.path == "/typed":
            # a line he sent or finished (Return), from a field Drafter may read: kept locally for the phrase memory
            text = (req.get("text") or "").strip()
            if len(text.split()) >= 3 and len(text) <= 600:
                with open(DATA / "typed.jsonl", "a") as f:
                    row = {"t": time.time(), "app": req.get("app", ""), "text": text}
                    if (req.get("context") or "").strip(): row["context"] = req["context"][-1500:]   # the chat above, for benches
                    f.write(json.dumps(row, ensure_ascii=False) + "\n")
                phrases.add(text)
                finisher.add(text)
                if (req.get("app") or "").lower().startswith("beeper"): people_mem.add(req.get("context") or "", text)
                with GATE_LOCK:
                    export_words = time.time() - GATE.get("exported", 0) > 600
                    if export_words: GATE["exported"] = time.time()
                if export_words: finisher.export(DATA / "mywords.txt")
                try: edits.sent(text)          # words he changed in a voice take become "heard -> fixed" candidates
                except Exception as e: print("edits:", e, flush=True)
            return self.send({"ok": True})
        if self.path == "/accept":
            with open(DATA / "accepted.jsonl", "a") as f:
                row = {"t": time.time(), "app": req.get("app", ""), "text": req.get("text", ""), "before": (req.get("before") or "")[-120:]}
                for k in ("ghost_len", "src"):     # bench/kept.py: kept letters per ghost length and source (2026-11-13)
                    if req.get(k) not in (None, ""): row[k] = req[k]
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
            return self.send({"ok": True})
        if self.path == "/words":
            w = dictionary.add(req.get("text", ""), lang=req.get("lang"), kind=req.get("kind", "term"), source="menu")
            run(lambda c: (builder.refresh(), model.warm(builder.head_ids)) and {}, newest=False, timeout=30)
            return self.send({"ok": bool(w), "word": w})
        if self.path == "/model-key":
            # "Connect a model" (app/Connect.swift): the app hands over the key from the Keychain after each engine start
            # and on connect; empty forgets it. Kept in memory only; never logged, never written.
            way = str(req.get("provider") or "")
            if way == "": provider.forget_all(); ok = True                      # Disconnect
            elif way == "cli": provider.forget_all(); ok = True                 # the CLI needs no key; fresh workers
            else: ok = provider.set_key(way, str(req.get("key") or ""))
            integrations._seen.pop("claude", None); router._state["at"] = 0
            refresh_cli()
            return self.send({"ok": bool(ok), "connected": provider.connected()})
        if self.path == "/settings":
            # Aleph (or anything local) changes Drafter here; the app picks the file up within a second
            st = settings_load() or {cloud.MARK: "off"}   # a file made here is a new install's: never migrated
            for k in ("paused", "skip", "actions_off", "model", "voice", "voiceFast", "voiceCareful", "learn", "screen", "adapter", "fmt", "voiceLive", "minGhost", "predictKeys",
                      "claudeTyping", "claudePause", "nextMessage", "proofread", "facts", "translate", "rework", "proofreadOff", "callNotes",
                      "streamGhost", "longGhostsAI", "longGhostsChats", "autocorrectMode"):
                if k in req: st[k] = req[k]
            tmp = DATA / "settings.tmp"; tmp.write_text(json.dumps(st, ensure_ascii=False, indent=2)); tmp.replace(DATA / "settings.json")
            return self.send({"ok": True})
        if self.path == "/edits":
            edits.decide(req.get("heard", ""), req.get("fixed", ""), bool(req.get("accept")))
            return self.send({"ok": True})
        if self.path == "/words/remove":
            d = dictionary.load(); n = len(d["words"])
            d["words"] = [w for w in d["words"] if w["text"].lower() != (req.get("text") or "").lower()]
            dictionary.save(d)
            return self.send({"ok": len(d["words"]) < n})
        if self.path == "/done":
            actions.finish(req.get("job", ""), req.get("result") or {})
            return self.send({"ok": True})
        if self.path == "/free":
            # free slots from his own calendars, read by the Drafter app (EventKit); Aleph's bar uses it (2026-10-21)
            job = {"kind": "eventkit.free", **{k: req[k] for k in ("from", "to", "minutes", "title", "earliest", "latest", "count") if k in req}}
            return self.send(actions.queue_app(job))
        if self.path == "/act":
            return self.send(actions.run_python(req.get("id"), req.get("fields") or {}))
        self.send({"error": "not found"}, 404)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
