"""Parity round (2026-11-15): his writing instructions reach the Claude helper prompts (Claude on a pause and at word
ends, the next message, rework on Claude and on the local model), and an empty instruction leaves each prompt
byte-identical. The calls go through the existing claude_on / cloud.py checks (unchanged). Made-up text, no model.
.venv/bin/python -B tests/test_helper_notes.py"""
import ast, re, sys, time, types, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
import claude_type as ct
import rework as rw

NOTE = "zebra-tone: short, no greetings"
SERVER = (ROOT / "engine/server.py").read_text()


def server_fns(*names, **ns):
    fns = [n for n in ast.parse(SERVER).body if isinstance(n, ast.FunctionDef) and n.name in names]
    exec(compile(ast.Module(body=fns, type_ignores=[]), "server.py", "exec"), ns)
    return ns


class FakeWorker:
    def __init__(self): self.users = []; self.turns = 1
    def ask(self, user, cancelled=lambda: False, **kw): self.users.append(user); return ("rest of it", 1, 2)
    def alive(self): return True


class ClaudeType(unittest.TestCase):
    def setUp(self):
        self.w = FakeWorker()
        self.saved = ct._worker, ct.CLI
        ct._worker = lambda model, lane="pause": self.w
        ct.CLI = sys.executable
        ct._state["fail_at"] = 0

    def tearDown(self): ct._worker, ct.CLI = self.saved

    def test_pause_prompt_carries_the_note(self):
        ct.complete("we can meet ", "Mail", "Re: zebra", "", notes=NOTE)
        self.assertIn("His writing instructions (follow them): " + NOTE, self.w.users[-1])

    def test_empty_note_is_byte_identical(self):
        a = ct._user("we can meet ", "Mail", "Re: zebra", "ctx line", after="later")
        b = ct._user("we can meet ", "Mail", "Re: zebra", "ctx line", after="later", notes="  ")
        self.assertEqual(a, b)
        self.assertEqual(ct._where("Mail", "t", "c", "a", "sonnet", 1), ct._where("Mail", "t", "c", "a", "sonnet", 1, ""))
        self.assertNotEqual(ct._where("Mail", "t", "c", "a", "sonnet", 1), ct._where("Mail", "t", "c", "a", "sonnet", 1, NOTE))

    def test_early_lane_carries_the_note(self):
        ct._early.update(want=None, busy=False, running=None, done=None, times=[])
        self.assertTrue(ct.early("the plan for zebra ", "Mail", "t", "", notes=NOTE))
        for _ in range(200):
            if ct._early["done"]: break
            time.sleep(0.01)
        self.assertIn(NOTE, self.w.users[-1])


class Rework(unittest.TestCase):
    def setUp(self):
        self.w = FakeWorker(); self.local = []
        self.saved = rw._worker, rw.ct.CLI
        rw._worker = lambda model: self.w
        rw.ct.CLI = sys.executable
        rw._cache.clear()

    def tearDown(self): rw._worker, rw.ct.CLI = self.saved

    def test_claude_path(self):
        rw.rework("the zebra plan is late again", "clearer", app="Mail", notes=NOTE)
        self.assertIn("His writing instructions (follow them unless the task says otherwise): " + NOTE, self.w.users[-1])
        rw._cache.clear()
        rw.rework("the zebra plan is late again", "clearer", app="Mail")
        plain = self.w.users[-1]
        rw._cache.clear()
        rw.rework("the zebra plan is late again", "clearer", app="Mail", notes="")
        self.assertEqual(plain, self.w.users[-1])
        self.assertNotIn("instructions", plain)

    def test_local_path(self):
        calls = []
        local = lambda *a: calls.append(a) or ""
        rw.rework("the zebra plan is late again", "clearer", online=False, local=local, notes=NOTE)
        rw.rework("the zebra plan is late again", "clearer", online=False, local=local)
        self.assertEqual(calls[0][2], NOTE)
        self.assertEqual(len(calls[1]), 2)          # no note: the old two-argument call

    def test_local_prompt(self):
        seen = []
        tok = types.SimpleNamespace(apply_chat_template=lambda m, **kw: seen.append(m[0]["content"]) or "S", chat_template="",
                                    encode=lambda s, **kw: [1, 2])
        ns = server_fns("local_rewrite", model=types.SimpleNamespace(tok=tok, oneshot=lambda *a, **kw: ""), REPO="x", latest=[0],
                        threading=__import__("threading"), run=lambda fn, **kw: fn(lambda: False))
        ns["local_rewrite"]("zebra text", "clearer", NOTE)
        ns["local_rewrite"]("zebra text", "clearer")
        ns["local_rewrite"]("zebra text", "clearer", "")
        self.assertIn(NOTE, seen[0])
        self.assertEqual(seen[1], seen[2]); self.assertNotIn("his writing instructions", seen[1])

    def test_server_passes_notes_only_when_set(self):
        got = []
        fake = types.SimpleNamespace(rework=lambda *a, **kw: got.append(kw) or {}, warm=lambda m: None)
        sys.modules["rework"] = fake
        try:
            ns = server_fns("rework", settings_load=lambda: {"rework": True}, cloud=types.SimpleNamespace(allowed=lambda f, st: True),
                            claude_on=lambda f, st=None: True, local_rewrite=None, DATA=Path("/nonexistent"))
            ns["rework"]({"text": "t", "cmd": "fix", "notes": NOTE}); ns["rework"]({"text": "t", "cmd": "fix"})
        finally:
            sys.modules["rework"] = rw
        self.assertEqual(got[0]["notes"], NOTE); self.assertNotIn("notes", got[1])


class NextMessage(unittest.TestCase):
    def run_reply(self, req):
        prompts = []
        ns = server_fns("reply", "reply_notes", claude_on=lambda f, st=None: True, REPLY_CACHE={}, OPTIONS=" OPTIONS",
                        prompt_examples=lambda n=30: ["made-up ask one", "made-up ask two"], ROOT=Path("/nonexistent"), re=re,
                        Path=Path, time=time, claude_worker=types.SimpleNamespace(ask=lambda p, t: prompts.append(p) or ""),
                        local=types.SimpleNamespace(enabled=lambda k: False, short_name=lambda: "the user", setting=lambda *a: ""))
        sys.modules.setdefault("prompt", __import__("prompt"))
        sys.modules["prompt"].load_json = lambda p, d: {"examples": ["made-up hi"]}
        ns["reply"](req)
        return prompts[-1]

    def test_both_kinds(self):
        for ai in (True, False):
            base = {"context": "Them: can you send the zebra file today please", "app": "Zebra", "ai": ai}
            plain, empty = self.run_reply(base), self.run_reply({**base, "notes": "  "})
            self.assertEqual(plain, empty)
            self.assertIn("His writing instructions (follow them): " + NOTE, self.run_reply({**base, "notes": NOTE}))


class Pause(unittest.TestCase):
    def test_pause_and_early_routes_pass_notes(self):
        got = []
        fake = types.SimpleNamespace(answer=lambda *a, **kw: got.append(("answer", kw)) or None,
                                     early=lambda *a, **kw: got.append(("early", kw)) or True)
        ns = server_fns("pause", "ask_early", settings_load=lambda: {}, claude_on=lambda f, st=None: True, KEYS=[0],
                        claude_type=fake, CLAUDE_CTX=2500, _known=lambda w: False)
        ns["pause"]({"before": "the zebra plan ", "notes": NOTE})
        ns["ask_early"]({"before": "the zebra plan ", "early": True, "notes": NOTE})
        ns["pause"]({"before": "the zebra plan "})
        self.assertEqual([k["notes"] for _, k in got], [NOTE, NOTE, ""])


if __name__ == "__main__":
    unittest.main()
