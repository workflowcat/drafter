"""Fact chips (1 November 2026; Superhuman and Gmail answer scheduling questions from the calendar): when the screen
above the field shows a question to Andrii that his own data answers - when the call is, when he is free, the meeting
link, his email or calendar link - the answer shows as a chip while he types the reply; Tab puts it in.

Facts: his primary calendar for the next 14 days (events with people and Meet links; read through GAM, kept 10
minutes), his free half hours on the next working days (weekdays 09:00-18:00, the same rule as ;free), his snippets
(data/snippets.json, short ones), today's date. Claude (his signed-in `claude` CLI, its own kept-running worker)
reads the question and the facts and answers with the words to insert, or nothing. An answer is kept only when every
time, link, email and number in it is in the facts: nothing invented reaches the chip.

What leaves the Mac: the screen text above the field, what he typed, and the facts above, under `claudeTyping` and
its own setting `facts`.

    .venv/bin/python engine/facts.py "Сава: коли сьогодні дзвінок? скинь лінк" ["what he typed"]
"""
import hashlib, json, re, sys, threading, time
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_type as ct
import prompt as prompt_mod
import local

SYSTEM = """You help {name} answer a chat or an email. You get facts from his calendar and files, the conversation on his screen and what he has typed so far in the reply box.

If the other person's latest message asks him something the facts answer (when a call or meeting is, when he is free, the meeting link, his email, his calendar link, a date), reply with one line of JSON: {"insert": "...", "label": "..."}
- insert: the words to put at his caret, continuing what he typed (no repeat of it), in the language of the conversation, short: the time, the day, the link, or a few words around them. Only facts from the list. Days and dates written the way he would in that language (у четвер о 15:00; Thu at 3 pm is wrong, use 15:00).
- label: 2-6 words in English that start with the fact itself, e.g. "Thu 05 Nov 15:00 · call with Sava" or "calendar link".
A call "with" someone is an event where they are among the people or named in the title; if no event matches the person, do not guess one.
If the message asks several things, answer the ones the facts answer (a calendar link when no call is set yet).
If nothing on screen asks him, if the facts do not answer it, or if he already typed the answer, reply with exactly: ∅"""


def system():
    """SYSTEM with the user's name from the local config (data/drafter.local.json); "the user" without it."""
    return SYSTEM.replace("{name}", local.name())


QUESTION = re.compile(r"\?|\b(коли|о котрій|котра|скільки|де |лінк|посилання|посиланн|пошт|імейл|мейл|номер|зручно|вільн|"
                      r"when|what time|link|email|e-mail|phone|number|available|free|calendar|календар|дзвін|зустріч|call|meet)", re.I)
TOKENS = re.compile(r"https?://\S+|[\w.+-]+@[\w-]+\.[\w.]+|\b\d{1,2}[:.]\d{2}\b|\+?\d[\d ()-]{6,}\d")

_lock = threading.Lock()
_cal = {"at": 0.0, "rows": None, "zone": None, "loading": False, "error": ""}
_workers = {}
_cache = {}
_stats = {"asked": 0, "answered": 0, "dropped": 0}


def _load_calendar():
    try:
        import lookup
        account, zone = lookup.config()
        now = datetime.now(zone)
        rows = lookup.events(account, now - timedelta(hours=2), now + timedelta(days=14))
        _cal.update(rows=rows, zone=zone, at=time.time(), error="")
    except Exception as e:
        _cal.update(at=time.time(), error=str(e)[:120])
        if _cal["rows"] is None: _cal["rows"] = []
    finally:
        _cal["loading"] = False


def calendar(wait=0.0):
    """The cached events; a reload starts in the background after 10 minutes."""
    with _lock:
        stale = time.time() - _cal["at"] > 600
        if stale and not _cal["loading"]:
            _cal["loading"] = True
            threading.Thread(target=_load_calendar, daemon=True).start()
    t0 = time.time()
    while _cal["rows"] is None and time.time() - t0 < wait: time.sleep(0.05)
    return _cal["rows"] or [], _cal["zone"]


def asks(context):
    """Is there a question near the end of the screen text?"""
    tail = (context or "").strip()[-400:]
    return bool(tail) and bool(QUESTION.search(tail))


def facts_text(now=None):
    import lookup
    rows, zone = calendar()
    if zone is None:
        try: zone = lookup.config()[1]
        except Exception:
            from zoneinfo import ZoneInfo
            zone = ZoneInfo(local.timezone())
    now = now or datetime.now(zone)
    out = [f"Now: {now:%a %d %b %Y %H:%M} ({zone.key})"]
    ev = []
    for e in rows:
        if e.get("eventType") == "workingLocation": continue
        try:
            a = lookup.event_time(e["start"], zone); b = lookup.event_time(e["end"], zone)
        except Exception: continue
        if b < now: continue
        allday = "date" in (e.get("start") or {}) and "dateTime" not in (e.get("start") or {})
        who = [a_.get("displayName") or a_.get("email", "") for a_ in e.get("attendees", []) if not a_.get("self")][:8]
        line = f"- {a:%a %d %b}" + (" all day" if allday else f" {a:%H:%M}-{b:%H:%M}") + f" · {e.get('summary') or '(no title)'}"
        if who: line += " · with " + ", ".join(who)
        link = lookup.public_url(e.get("hangoutLink", ""))
        if link: line += " · meet " + link
        ev.append(line)
        if len(ev) >= 30: break
    out.append("His calendar, next 14 days:\n" + ("\n".join(ev) if ev else "(nothing, or the calendar could not be read)"))
    try:
        free = lookup.free_times(rows, now, now + timedelta(days=7), 30, now) if rows else []
        if free: out.append("He is free for 30 minutes at (weekdays 09:00-18:00):\n" + "\n".join(f"- {a:%a %d %b %H:%M}" for a, _ in free))
    except Exception:
        pass
    snips = {k: v for k, v in prompt_mod.load_json(ct.DATA / "snippets.json", {}).items() if isinstance(v, str) and len(v) <= 200}
    if snips: out.append("His saved texts:\n" + "\n".join(f"- {k}: {v}" for k, v in list(snips.items())[:15]))
    return "\n\n".join(out)


def _worker(model):
    with _lock:
        w = _workers.get(model)
        if w is None or not w.alive() or w.turns >= ct.Worker.MAX_TURNS:
            if w: w.stop()
            names = prompt_mod.words()[:120]
            w = _workers[model] = ct.Worker(model, system() + "\n\nNames he uses: " + ", ".join(names), max_tokens=300)
        w.used = time.time()
        return w


# idle processes are stopped by claude_type's one reaper (10 idle minutes, or at once when memory is low)


# a day named in the answer, and words that say he is free (Codex review 2026-11-01: "Friday at 11:30" and "I'm free at
# 11:30" passed when 11:30 was a Monday meeting, because the time alone was looked up)
WEEKDAY = re.compile(r"(?i)\b(?:(mon(?:day)?)|(tue(?:s(?:day)?)?)|(wed(?:nesday)?)|(thu(?:rs(?:day)?)?)|(fri(?:day)?)|(sat(?:urday)?)|(sun(?:day)?))\b"
                     r"|(понеділ\w*)|(вівтор\w*)|(серед[аиу]\b)|(четвер(?:г[аиу]?)?\b)|(п['’ʼ]?ятниц\w*)|(субот\w*)|(неділ\w*)")
RELATIVE = re.compile(r"(?i)(day after tomorrow|післязавтра)|(tomorrow|завтра)|(today|tonight|сьогодні)")
MONTHS = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
          "січ": 1, "лют": 2, "берез": 3, "квіт": 4, "трав": 5, "черв": 6, "лип": 7, "серп": 8, "верес": 9, "жовт": 10, "листопад": 11, "груд": 12}
_MON = "|".join(sorted(MONTHS, key=len, reverse=True))
DATE = re.compile(rf"(?i)\b(\d{{1,2}})\s+({_MON})\w*\.?|\b({_MON})\w*\.?\s+(\d{{1,2}})\b")
FREE = re.compile(r"(?i)\b(free|available|availability|slot|вільн\w*|можу|зможу|підійде|підходить|слот\w*)")


def _slots(facts):
    """-> (today, [(date, "HH:MM", "event" | "free")]) from facts_text(); today None when the facts have no Now line."""
    now = re.search(r"Now: \w{3} (\d{2}) (\w{3}) (\d{4})", facts)
    if not now: return None, []
    today = datetime.strptime(f"{now[1]} {now[2]} {now[3]}", "%d %b %Y").date()
    out, kind = [], ""
    for line in facts.splitlines():
        if line.startswith("His calendar"): kind = "event"
        elif line.startswith("He is free"): kind = "free"
        elif not line.startswith("- "): kind = ""
        if not kind: continue
        m = re.match(r"- \w{3} (\d{2}) (\w{3})(?: (\d{2}:\d{2})(?:-(\d{2}:\d{2}))?)?", line)
        if not m or not m[3]: continue
        d = datetime.strptime(f"{m[1]} {m[2]} {today.year}", "%d %b %Y").date()
        if d < today - timedelta(days=180): d = d.replace(year=today.year + 1)
        out += [(d, t, kind) for t in (m[3], m[4]) if t]
    return today, out


def _days(text, today):
    """Every day the answer names: [(position, {dates})]."""
    out = []
    for m in WEEKDAY.finditer(text):
        wd = next(i for i, g in enumerate(m.groups()) if g) % 7
        out.append((m.start(), {today + timedelta(days=k) for k in range(15) if (today + timedelta(days=k)).weekday() == wd}))
    for m in RELATIVE.finditer(text):
        out.append((m.start(), {today + timedelta(days=2 if m[1] else 1 if m[2] else 0)}))
    for m in DATE.finditer(text):
        day, mon = (m[1], m[2]) if m[1] else (m[4], m[3])
        mon = next(v for k, v in MONTHS.items() if mon.lower().startswith(k))
        try: d = today.replace(month=mon, day=int(day))
        except ValueError: continue
        if d < today - timedelta(days=180): d = d.replace(year=today.year + 1)
        out.append((m.start(), {d}))
    return sorted(out, key=lambda x: x[0])


def grounded(insert, facts):
    """Every time, link, email and number in the answer is in the facts; at least one is there. A time must be one of
    his events or free half hours on the day the answer names next to it (no day named: today, or the only day with
    that time), and a free one when the answer says he is free."""
    found = list(TOKENS.finditer(insert))
    if not found: return False
    flat = facts.replace(".", ":")
    today, slots = _slots(facts)
    days = _days(insert, today) if today else []
    free = bool(FREE.search(insert))
    for f in found:
        t = f.group(0).rstrip(".,;)")
        if t.startswith("http") or "@" in t:
            if t not in facts: return False
        elif re.fullmatch(r"\d{1,2}[:.]\d{2}", t):
            h, m = re.split(r"[:.]", t)
            hm = f"{int(h):02d}:{m}"
            if hm not in flat: return False
            if today is None: continue
            dates = {d for d, tt, k in slots if tt == hm and (k == "free" or not free)}
            if not dates: return False
            before = [s for p, s in days if p <= f.start()]
            after = [s for p, s in days if p > f.start()]
            said = before[-1] if before else after[0] if after else None
            if said is not None:
                if not said & dates: return False
            elif today not in dates and len(dates) != 1: return False
        elif re.sub(r"\D", "", t) not in re.sub(r"[^\d\n]", "", facts): return False
    return True


def answer(context, before="", app="", model="sonnet", cancelled=lambda: False):
    """-> {"insert", "label", "ms"} or {} (no question, no answer)."""
    if not asks(context): return {}
    if not Path(ct.CLI).exists(): return {}
    calendar(wait=3.0)
    facts = facts_text()
    line = (before or "").split("\n")[-1][-300:]
    key = hashlib.sha1(json.dumps([context[-1500:], line, facts, model]).encode()).hexdigest()
    if key in _cache: return dict(_cache[key], cached=True)
    _stats["asked"] += 1
    user = (f"App: {app}\n\n" if app else "") + "Facts:\n" + facts + "\n\nOn screen (the conversation, newest last):\n" + \
           context.strip()[-1500:] + "\n\nWhat he typed in the reply box so far:\n" + (line or "(nothing)") + "⟨caret⟩"
    r = _worker(model).ask(user, cancelled, wait=1.0, deadline=9.0, whole=True)
    if r is None: return {}
    raw, first, ms = r
    res = {}
    m = re.search(r"\{.*\}", raw, re.S)
    if m:
        try:
            j = json.loads(m.group())
            ins, label = str(j.get("insert") or "").strip(), str(j.get("label") or "").strip()
            if ins and label and len(ins) <= 300 and not ct.RUSSIAN.search(ins):
                if grounded(ins, facts): res = {"insert": ins, "label": label[:60], "ms": ms}; _stats["answered"] += 1
                else: _stats["dropped"] += 1
        except Exception:
            pass
    if len(_cache) > 40: _cache.pop(next(iter(_cache)))
    _cache[key] = res
    return res


def stats(): return dict(_stats, calendar_error=_cal["error"], events=len(_cal["rows"] or []))


if __name__ == "__main__":
    ctx = sys.argv[1] if len(sys.argv) > 1 else "Сава: привіт! коли в нас наступний дзвінок? і скинь лінк на свій календар"
    before = sys.argv[2] if len(sys.argv) > 2 else ""
    t = time.time()
    print(answer(ctx, before), f"{time.time() - t:.1f}s", stats())
