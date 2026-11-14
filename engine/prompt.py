"""The prompt: a fixed head (how the user writes, their words, their messages) and a moving tail (where he types, what is typed)."""
import json, re, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parent.parent

import local


def rules():
    """How the user writes: `user.style_rules` in the local config (data/drafter.local.json), else a neutral line."""
    return local.style_rules()


def load_json(p, default):
    try: return json.loads(Path(p).read_text())
    except Exception: return default


def words():
    d = load_json(ROOT / "data" / "words.json", {})
    return [w["text"] if isinstance(w, dict) else w for w in d.get("words", [])]


def head(n_examples=12, n_words=40):
    style = load_json(ROOT / "data" / "style.json", {"examples": []})
    ex = style["examples"][:n_examples]
    w = words()[:n_words]
    parts = [rules()]
    if w: parts.append("Його слова й імена: " + ", ".join(w))
    parts.append("Його повідомлення:\n" + "\n###\n".join(ex))
    return "\n\n".join(parts) + "\n###\n"


# per-app voice (2026-10-20): how he writes where; the trained layer knows [Beeper] / [Claude] / [Voice Notes] already,
# this line adds the rest
STYLE = {"Beeper": "коротко, розмовно, як у чаті", "WhatsApp": "коротко, розмовно, як у чаті", "Telegram": "коротко, розмовно",
         "Slack": "коротко, по справі", "Mail": "повними реченнями, ввічливо, без води", "Outlook": "повними реченнями, ввічливо",
         "Claude": "чіткі інструкції для агента", "Notes": "нотатки для себе", "Obsidian": "нотатки для себе",
         "Google Docs": "повними реченнями", "Pages": "повними реченнями", "TextEdit": "повними реченнями"}


def tail(before, app="", title="", context="", mine=""):
    where = " · ".join(x for x in (app, title) if x)
    style = next((v for k, v in STYLE.items() if k.lower() in (app or "").lower()), "")
    t = (f"[{where}]" + (f" ({style})" if style else "") + "\n") if where else ""
    if mine:
        # his own older messages in this chat (people.People.earlier), above the screen and fixed per chat, so the cache keeps it
        t += "Мої раніші повідомлення в цьому чаті:\n" + mine.strip() + "\n"
    if context:
        # the text on screen above the field (the message he answers); it changes rarely, so it stays in the cache
        # (the engine trims it to a window whose start stays put, up to 1.5 x 1,000 characters: server.window)
        t += "На екрані перед цим:\n" + context.strip()[-1600:] + "\n---\n"
    return t + before


class Builder:
    """Same head for every request, so the prompt cache keeps it warm."""
    def __init__(self, model, fmt="raw"):
        self.m, self.fmt = model, fmt
        self.refresh()

    def refresh(self):
        self.head = head()
        self.head_ids = self.m.bos() + self.m.encode(self._wrap_head(self.head))

    def _wrap_head(self, h):
        if self.fmt == "bare": return "\n"   # one token, so the engine still warms up on its own thread
        if self.fmt == "raw": return h
        # chat: the fixed part (how he writes, his messages) opens the user turn; chat_tail adds the rest
        return "<|im_start|>user\n" + h.rstrip("#\n") + "\n\n"

    def chat_tail(self, before, app="", title="", context=""):
        """Chat shape (Qwen template): the conversation goes in the user turn, his text starts the answer."""
        where = " · ".join(x for x in (app, title) if x)
        u = (f"Де він пише: {where}\n" if where else "") + (f"На екрані перед цим:\n{context.strip()}\n" if context else "")
        u += "Продовж його текст кількома словами, тією ж мовою."
        return u + "<|im_end|>\n<|im_start|>assistant\n" + before

    def ids(self, before, app="", title="", context="", mine=""):
        """(prompt ids, heal): the half-typed word and trailing spaces are cut off and re-spelled by the model,
        so the prompt never ends on a token it would not have chosen itself."""
        t = tail(before, app, title, context, mine) if self.fmt in ("raw", "bare") else self.chat_tail(before, app, title, context)
        heal = re.search(r"[ \t]*[\w'’-]*$", t).group(0)
        if len(heal) > 24: heal = ""
        if heal == t: heal = ""            # nothing left to stand on
        # the tail is tokenised on its own so the head ids never shift
        return self.head_ids + self.m.encode(t[: len(t) - len(heal)]), heal
