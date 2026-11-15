"""The decision gate (2026-10-31): how likely the model's next grey word is exactly what Andrii types next. A plain
logistic model over a few numbers the engine already has (token probabilities, mid-word or not, app, language, does
the instant word finisher agree), so it costs a dot product. Trained by bench/gate.py on recordings of the fresh
replay set; weights in data/gate.json. GitHub Copilot's "contextual filter" works the same way.

Shared by the engine (engine/model.py complete_gated) and the bench, so both decide the same way.
"""
import json, math, re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CYR = re.compile(r"[а-яіїєґ]", re.I)
NAMES = ["bias", "logp_first", "logp_min", "margin", "mid_word", "heal_len", "word_len", "claude", "cyrillic",
         "line_words", "heal_logp", "words_agree", "words_has", "punct_word", "after_space"]


def next_word(s):
    """app/Keys.swift nextWord: leading spaces, one word with its punctuation, the space after it."""
    out, seen = "", False
    for ch in s:
        if ch.isspace():
            if seen:
                if ch == " ": out += ch
                break
            out += ch; continue
        seen = True; out += ch
    return out


def first_word(toks):
    """toks: [[text after the half word, p, p2, ...], ...] -> (next word, its token probs, p2 of its first token, half-word probs)."""
    if not toks: return "", [], 0.0, []
    w = next_word(toks[-1][0])
    end = len(w.rstrip())
    ps, heal_ps, p2, prev = [], [], None, 0
    for t in toks:
        text, p, q = t[0], t[1], t[2]
        if not text: heal_ps.append(p); continue
        if prev >= end: break
        ps.append(p)
        if p2 is None: p2 = q
        prev = len(text)
    return w, ps, p2 or 0.0, heal_ps


def word_done(text):
    """The first word is whole once something follows it (a space after it, punctuation, a new line)."""
    s = text.lstrip(" ")
    m = re.match(r"\S+", s)
    return bool(m) and len(s) > m.end()


def features(toks, before, ai, finish=""):
    w, ps, p2, heal_ps = first_word(toks)
    if not w.strip() or not ps: return None, w
    line = before.split("\n")[-1]
    mid = bool(re.search(r"[\w'’-]$", line))
    heal = re.search(r"[\w'’-]*$", line).group(0)
    f = [1.0, math.log(max(ps[0], 1e-6)), math.log(max(min(ps), 1e-6)), ps[0] - p2, float(mid),
         math.log1p(len(heal)), math.log1p(len(w.strip())), float(ai), float(bool(CYR.search(line))),
         math.log1p(len(line.split())), sum(math.log(max(p, 1e-6)) for p in heal_ps) if heal_ps else 0.0,
         float(bool(finish) and w.strip().lower().startswith(finish.lower())), float(bool(finish)),
         float(bool(re.search(r"[.,!?:;)]$", w.strip()))), float(line[-1:].isspace())]
    return f, w


WORD_NAMES = ["bias", "level2", "level1", "log_n", "share", "second", "prefix", "rest_len", "claude", "cyrillic", "line_words"]


def word_features(cand, before, claude):
    """The word gate (round four, 2026-11-14): how likely his own finish of the word being typed (Words.candidate) is
    exactly his word, from counts alone, so it can answer before the model is asked."""
    if not cand or not cand["rest"].strip(): return None
    line = before.split("\n")[-1]
    return [1.0, float(cand["level"] == 2), float(cand["level"] == 1), math.log1p(cand["n"]), cand["share"], cand["second"],
            min(cand["prefix"], 10) / 10, min(len(cand["rest"]), 12) / 12, float(claude), float(bool(CYR.search(line))),
            min(len(line.split()), 20) / 20]


SEL_NAMES = ["bias", "words", "memory", "model_p", "model_low", "word_p", "mem_hits", "first_letters",
             "claude", "cyrillic", "mid", "line_words"]


def sel_features(kind, ghost, before, claude, **f):
    """The selector (round four, bench/selector.py): one chance that the first word of a ghost is his, whichever
    source offers it (kind "model", "words" or "memory"); f: model_p, model_low, word_p, mem_hits."""
    line = before.split("\n")[-1]
    v = dict.fromkeys(SEL_NAMES, 0.0)
    v.update(bias=1.0, words=float(kind == "words"), memory=float(kind == "memory"), claude=float(claude),
             cyrillic=float(bool(CYR.search(line))), mid=float(bool(re.search(r"[\w'’-]$", line))),
             line_words=min(len(line.split()), 20) / 20, first_letters=min(letters(next_word(ghost)), 12) / 12, **f)
    return [float(v[k]) for k in SEL_NAMES]


def extends(text, word):
    """A later part may only extend what is shown: the model's ghost starts with the whole word."""
    return bool(word) and text.startswith(word) and (len(text) == len(word) or not re.match(r"[\w'’-]", text[len(word)]))


def score(weights, f):
    z = sum(a * b for a, b in zip(weights, f))
    return 1 / (1 + math.exp(-max(-30, min(30, z))))


def load(path=ROOT / "data/gate.json"):
    try:
        g = json.loads(Path(path).read_text())
        return g if g.get("names") == NAMES else None
    except Exception: return None


def letters(s):
    """Letters a ghost adds (what Tab puts in, spaces not counted): the measure of the minimum ghost length."""
    return sum(1 for ch in s or "" if not ch.isspace())


def grow(toks, out, more, max_words, min_letters):
    """A ghost whose sure words add fewer than `min_letters` (2026-11-13: under 5 letters he takes one 3% of the
    time): the next words follow while each of their tokens is at least `more`, up to `max_words` words in all, and
    stop as soon as it is long enough. -> the longer ghost, or `out` as it was when it never got there."""
    if letters(out) >= min_letters: return out
    raw = toks[-1][0] if toks else ""
    # `out` may have lost the leading space the model wrote (server.clean after a typed space)
    lead = len(raw) - len(raw.lstrip(" "))
    if raw.startswith(out): pos = len(out)
    elif raw[lead:].startswith(out): pos = lead + len(out)
    else: return out
    longer, n = out, len(out.split())
    for ww in re.findall(r"\s*\S+\s?", raw[pos:]):
        if n >= max_words: break
        end = pos + len(ww.rstrip())
        # the last recorded word may be cut by the token limit: only words something follows count as whole
        if end >= len(raw) and not END_RE.search(ww): break
        span = word_ps(toks, pos, end)
        if not span or min(span) < more: break
        longer += ww; pos += len(ww); n += 1
        if letters(longer) >= min_letters or END_RE.search(ww): break
    return longer if letters(longer) >= min_letters else out


END_RE = re.compile(r"[.!?…)\n]")


def more_words(toks, out, bar, max_words):
    """The lighter tail (round two, 2026-11-13): whole words after `out` while each of their tokens is >= `bar`, up to
    `max_words` words in all; a word counts only once something follows it (or it ends the sentence)."""
    raw = toks[-1][0] if toks else ""
    lead = len(raw) - len(raw.lstrip(" "))
    if raw.startswith(out): pos = len(out)
    elif raw[lead:].startswith(out): pos = lead + len(out)
    else: return out
    longer, n = out, len(out.split())
    for ww in re.findall(r"\s*\S+\s?", raw[pos:]):
        if n >= max_words: break
        end = pos + len(ww.rstrip())
        if end >= len(raw) and not END_RE.search(ww): break
        span = word_ps(toks, pos, end)
        if not span or min(span) < bar: break
        longer += ww; pos += len(ww); n += 1
        if END_RE.search(ww): break
    return longer


def whole_words(text, sure):
    """What of a ghost being written can be drawn now: up to its last whole word (a word followed by a space or
    ending in punctuation), so a word still being spelled ("the" -> "there") is never shown and then changed.
    -> (text, sure part length)"""
    if not text or text[-1].isspace() or END_RE.search(text[-1]) or text[-1] in ",;:": return text, min(sure, len(text))
    cut = max(text.rfind(" "), text.rfind("\n")) + 1
    if cut <= 0 or not text[:cut].strip(): return "", 0
    return text[:cut], min(sure, cut)


def word_ps(toks, pos, end):
    """p of each token that writes part of the word raw[pos:end] (toks hold the text so far after each token). A token
    that ends one character past the word counts only when it also holds letters of the word: a lone space or line
    break after "world," is the next word's business (Argon review 9: a weak space dropped a streamed "world,").
    A word's span starts where the word before it ended, so the space between them counts for the later word."""
    raw = next((t[0] for t in reversed(toks) if t[0]), "")
    lo = len(raw[:pos].rstrip())
    out, start = [], 0
    for t in toks:
        if not t[0]: continue
        n = len(t[0])
        if lo < n <= end or (n == end + 1 and start < end): out.append(t[1])
        start = n
    return out


def shape(toks, more, max_words, grow_bar=None, grow_words=6, min_letters=0, tail=None, tail_words=8):
    """The ghost the recorded tokens make now (model.complete_gated, bench/lengths.py policy): the first word, sure
    words while each token >= `more`, grown words when still short, the lighter tail. -> (text, sure part length)"""
    text = extend(toks, next_word(toks[-1][0]), more, max_words)
    if grow_bar is not None and min_letters: text = grow(toks, text, grow_bar, grow_words, min_letters)
    sure = len(text)
    if tail is not None: text = more_words(toks, text, tail, tail_words)
    return text, sure


def settled(raw, shown, min_letters=0):
    """Round five (2026-11-14): the ghost the tokens make (`shown`, from shape) can no longer change, so the model may
    stop. True when a whole word after it in the model's text `raw` was already turned down (a token under its bar,
    or the word limit): later tokens never change the probabilities of earlier ones. A ghost still under
    `min_letters` is never settled (grow may still reach it with the next word)."""
    if not shown or (min_letters and letters(shown) < min_letters): return False
    lead = len(raw) - len(raw.lstrip(" "))
    if raw.startswith(shown): pos = len(shown)
    elif raw[lead:].startswith(shown): pos = lead + len(shown)
    else: return False
    m = re.match(r"\s*(\S+)(\s?)", raw[pos:])
    return bool(m) and (bool(m.group(2)) or bool(END_RE.search(m.group(1))))


# Sentence-length ghosts (long round, 2026-11-14, Andrii: "it also gotta suggest more words ... full sentences i could
# finish quickly"). The show decision stays on the first word (the gate); after it the ghost runs on while the running
# chance that he gets that far (the product of each later word's probability, the first word left out: the gate
# already judged it) stays at or above a floor, to the end of the sentence or clause, a line end, or a word cap. One
# unsure function word does not cut it (a per-token bar did); a run of weak words does. bench/long_ghosts.py picked
# the numbers.
SENT_END = re.compile(r"[.!?…][\"'»”)\]]*$")
RUN_MODES = {"phrase": {"words": 6, "stops": ",;:", "comma_words": 0},
             "sentence": {"words": 24, "stops": ";", "comma_words": 8}}
RUN_FLOOR, RUN_CAP, RUN_LIKELY, RUN_GARBAGE = 0.1, 24, 0.3, 0.005


def word_p(toks, pos, end):
    """The model's probability of the whole word raw[pos:end]: the product of its token probabilities."""
    span = word_ps(toks, pos, end)
    p = 1.0
    for x in span: p *= x
    return p if span else 0.0


def run_words(toks, mode="sentence", floor=RUN_FLOOR, words=None, closed=None, likely=RUN_LIKELY, garbage=RUN_GARBAGE,
              min_letters=0, grow=0.05, kind="prod"):
    """The ghost of a sentence-length run on the recorded tokens, once the gate said yes to the first word.
    -> (text, sure part length, why it ended, [running chance after each later word]).
    closed: None while the model is still writing; "eos" when it ended the text (the last word is whole); "cap" when
    the token cap stopped it (a last word with nothing after it may be cut, so it is left out).
    why: "open" (the next word is still being written: wait for more tokens), "sentence" (. ! ? … ended it), "clause"
    (; or, in phrase mode, , :), "comma" (a comma after `comma_words` words), "line" (a line break follows), "floor"
    (the running chance fell under `floor`, or one word under `garbage`), "words" (the word cap), "end" (the model
    ended the text), "cap" (the token cap)."""
    raw = toks[-1][0] if toks else ""
    m = RUN_MODES[mode]
    cap = words or m["words"]
    first = next_word(raw)
    w0 = first.strip()
    if not w0: return "", 0, ("open" if not closed else closed if closed == "cap" else "end"), []
    if len(first) >= len(raw) and not first.endswith(" ") and not END_RE.search(w0) and closed != "eos":
        return "", 0, ("open" if not closed else "cap"), []
    text, pos, n, cum, confs, sure = first, len(first), 1, 1.0, [], len(first)
    logs = 0.0
    if SENT_END.search(w0): return text, sure, "sentence", confs
    if w0[-1:] in m["stops"]: return text, sure, "clause", confs
    why = None
    for ww in re.findall(r"\s*\S+ ?", raw[pos:]):
        if "\n" in ww[: len(ww) - len(ww.lstrip())]: why = "line"; break
        end = pos + len(ww.rstrip())
        if end >= len(raw) and not END_RE.search(ww) and closed != "eos": why = "cap" if closed else "open"; break
        wp = word_p(toks, pos, end)
        if min_letters and letters(text) < min_letters:
            span = word_ps(toks, pos, end)
            if not span or min(span) < grow: why = "floor"; break
        elif wp < garbage or running(kind, cum * wp, logs + math.log(max(wp, 1e-9)), n) < floor: why = "floor"; break
        if n >= cap: why = "words"; break
        cum *= wp; logs += math.log(max(wp, 1e-9)); text += ww; pos += len(ww); n += 1; confs.append(round(cum, 4))
        if cum >= likely: sure = len(text)
        w = ww.strip()
        if SENT_END.search(w): why = "sentence"; break
        if w[-1:] in m["stops"]: why = "clause"; break
        if m["comma_words"] and w.endswith(",") and n >= m["comma_words"]: why = "comma"; break
    if why is None:
        if raw[pos:].startswith("\n") or raw[pos:].lstrip(" ").startswith("\n"): why = "line"
        else: why = "open" if not closed else ("end" if closed == "eos" else "cap")
    return text, min(sure, len(text)), why, confs


RUN_PRIOR, RUN_PRIOR_P = 2, 0.7


def running(kind, cum, logs, n):
    """The running confidence after n later words: the product `cum`, or the geometric mean of their probabilities
    (log sum `logs`) pulled towards RUN_PRIOR_P by RUN_PRIOR words."""
    if kind == "prod": return cum
    return math.exp((logs + RUN_PRIOR * math.log(RUN_PRIOR_P)) / (n + RUN_PRIOR))


def run_settled(why):
    """The run can no longer change: the model may stop (only "open" waits for more tokens)."""
    return why != "open"


def extend(toks, first, more, max_words):
    """Further words after the first while each of their tokens is at least `more` sure."""
    raw = toks[-1][0]
    out, pos, n = first, len(first), 1
    for ww in re.findall(r"\s*\S+\s?", raw[len(first):]):
        if n >= max_words: break
        end = pos + len(ww.rstrip())
        span = word_ps(toks, pos, end)
        if not span or min(span) < more: break
        out += ww; pos += len(ww); n += 1
    return out
