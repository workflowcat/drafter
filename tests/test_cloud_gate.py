"""The engine never sends his text to a Claude worker unless the setting that owns that feature is on (Argon review
2026-11-14, findings 1 and 2). No model, no network, no `claude` process: server functions run from their source
with stand-ins.

    .venv/bin/python -B tests/test_cloud_gate.py
"""
import ast, sys, types, unittest, unittest.mock
from pathlib import Path
from unittest.mock import Mock

ENGINE = Path(__file__).resolve().parent.parent / "engine"
sys.path.insert(0, str(ENGINE))
import cloud

# Every place that starts a `claude` process or hands text to one, by (module, top-level function or class).
# A new one fails test_every_claude_call_site_is_known until it is added here with the feature that owns it.
SITES = {
    ("claude_type", "Worker"): "starts the process; reached only through the _worker functions below",
    ("claude_type", "_worker"): "server: pause / early / warm_claude",
    ("proofread", "_worker"): "server: proof",
    ("facts", "_worker"): "server: facts",
    ("translate", "_worker"): "server: translate",
    ("rework", "_worker"): "server: rework",
    ("server", "rewrite"): "rewrite",
    ("server", "outline"): "call_notes",
    ("server", "reply"): "reply",
    ("command", "plan"): "command (no owner: after he picks)",
    ("ask", "answer"): "ask (no owner: he asked)",
    ("notes", "claude_summary"): "call_notes: only when notes.make gets cloud=claude_on(\"call_notes\")",
    ("router", "text"): "no caller (test_router_text_has_no_caller)",
    ("entities", "ask_claude"): "entities: cloud.allowed(\"entities\") + router.online() in the function itself; only the name goes",
}
SINKS = {"claude_worker.ask", "ct.Worker", "Worker"}

# server.py: a call into one of these must sit in a function that asks claude_on(<one of the features>) first
ENTRIES = {
    "claude_type": ({"answer", "early", "warm", "complete"}, {"pause", "early"}),
    "proofread": ({"check", "warm"}, {"proofread"}),
    "facts_mod": ({"answer"}, {"facts"}),
    "translate_mod": ({"translate"}, {"translate"}),
    "rework_mod": ({"rework", "warm"}, {"rework"}),
    "claude_worker": ({"ask"}, {"rewrite", "reply", "call_notes"}),
    "notes": ({"make"}, {"call_notes"}),
}
# called from the handler with no owning setting (AGENTS.md "What leaves the Mac": his own action)
NO_OWNER = {("command", "plan"), ("notes_ask", "answer")}


def dotted(node):
    if isinstance(node, ast.Name): return node.id
    if isinstance(node, ast.Attribute):
        base = dotted(node.value)
        return base + "." + node.attr if base else None
    return None


def tops(tree):
    for n in tree.body:
        if isinstance(n, (ast.FunctionDef, ast.ClassDef)): yield n


class Gate(unittest.TestCase):
    def test_owners(self):
        live = {"claudeTyping": True, "claudePause": False, "proofread": True, "rework": True, "nextMessage": False,
                "connect": {"provider": "cli"}}
        self.assertFalse(any(cloud.allowed(f, {**live, "connect": {}}) for f in cloud.OWNERS))   # nothing connected: all local
        self.assertFalse(cloud.allowed("pause", live))
        self.assertFalse(cloud.allowed("early", live))
        self.assertTrue(cloud.allowed("proofread", live))
        self.assertFalse(cloud.allowed("reply", live))
        self.assertFalse(cloud.allowed("proofread", {"claudeTyping": False}))
        self.assertFalse(cloud.allowed("pause", {}))           # the app's defaults (app/Main.swift Settings): off since 2026-11-14
        self.assertFalse(cloud.allowed("nothing-like-this", {}))
        self.assertFalse(cloud.allowed("pause", {"claudeTyping": True, "claudePause": "no"}))   # only a real true
        self.assertFalse(cloud.allowed("call_notes", {}))
        self.assertTrue(cloud.allowed("call_notes", {"callNotes": True, "connect": {"provider": "cli"}}))
        self.assertFalse(cloud.allowed("call_notes", {"callNotes": False}))

    def test_only_his_own_actions_have_no_owner(self):
        self.assertEqual({f for f, o in cloud.OWNERS.items() if not o}, {"command", "ask"})

    def test_defaults_match_the_app(self):
        main = (ENGINE.parent / "app/Main.swift").read_text()
        for k, v in cloud.DEFAULTS.items():
            self.assertIn(f"forKey: .{k}) ?? {'true' if v else 'false'}", main, k)

    def test_every_claude_call_site_is_known(self):
        found = set()
        for f in sorted(ENGINE.glob("*.py")):
            mod = f.stem
            if mod == "claude_worker": continue
            for top in tops(ast.parse(f.read_text())):
                for n in ast.walk(top):
                    if isinstance(n, ast.Call) and dotted(n.func) in SINKS:
                        if dotted(n.func) == "Worker" and mod != "claude_type": continue
                        if mod == "claude_type" and isinstance(top, ast.ClassDef) and top.name == "Worker" and dotted(n.func) == "Worker":
                            continue
                        found.add((mod, top.name))
        unknown = found - set(SITES)
        self.assertFalse(unknown, f"a new Claude call site: gate it (server.claude_on) and add it to SITES: {unknown}")
        self.assertIn(("server", "reply"), found)     # the walk itself still sees the known ones

    def test_server_functions_ask_first(self):
        tree = ast.parse((ENGINE / "server.py").read_text())
        funcs = [n for n in tops(tree) if isinstance(n, ast.FunctionDef)]
        funcs += [m for c in tops(tree) if isinstance(c, ast.ClassDef) for m in c.body if isinstance(m, ast.FunctionDef)]
        checked = 0
        for fn in funcs:
            gates = {n.args[0].value for n in ast.walk(fn) if isinstance(n, ast.Call) and dotted(n.func) == "claude_on"
                     and n.args and isinstance(n.args[0], ast.Constant)}
            for n in ast.walk(fn):
                if not isinstance(n, ast.Call): continue
                name = dotted(n.func) or ""
                mod, _, attr = name.rpartition(".")
                if (mod, attr) in NO_OWNER:
                    self.assertFalse(cloud.OWNERS[{"command": "command", "notes_ask": "ask"}[mod]])
                    continue
                if mod in ENTRIES and attr in ENTRIES[mod][0]:
                    checked += 1
                    self.assertTrue(gates & ENTRIES[mod][1], f"{fn.name} calls {name} without claude_on({ENTRIES[mod][1]})")
        self.assertGreaterEqual(checked, 10)

    def test_note_handler_passes_the_call_notes_gate(self):
        tree = ast.parse((ENGINE / "server.py").read_text())
        calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and dotted(n.func) == "notes.make"]
        self.assertTrue(calls)
        for n in calls:
            kw = {k.arg: k.value for k in n.keywords}
            self.assertIn("cloud", kw, "notes.make without cloud=: the call summary would ignore callNotes")
            self.assertIsInstance(kw["cloud"], ast.Name)
        src = (ENGINE / "server.py").read_text()
        self.assertIn('cloud = bool(req.get("call")) and claude_on("call_notes")', src)

    def test_call_summary_off_stays_local(self):
        import notes
        local = Mock(return_value='{"points": ["made-up point"], "todos": ["Ann: made-up task"]}')
        with unittest.mock.patch.object(notes, "claude_summary", Mock(return_value={"points": ["cloud"]})) as cs:
            self.assertEqual(notes.summary("a made-up call transcript", local, cloud=False)[0], ["made-up point"])
            cs.assert_not_called()
            self.assertEqual(notes.summary("a made-up call transcript", local)[0], ["made-up point"])   # default: local
            cs.assert_not_called()
            self.assertEqual(notes.summary("a made-up call transcript", local, cloud=True)[0], ["cloud"])
            cs.assert_called_once()

    def test_router_text_has_no_caller(self):
        for f in ENGINE.glob("*.py"):
            self.assertNotIn("router.text(", f.read_text(), f.name)


class Server(unittest.TestCase):
    """The gated server functions, run from source with stand-ins and his live-like settings."""
    NAMES = ("claude_on", "warm_claude", "pause", "ask_early", "reply", "rewrite", "outline", "rework", "proof", "facts", "translate")

    def setUp(self):
        src = (ENGINE / "server.py").read_text()
        tree = ast.parse(src)
        body = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in self.NAMES]
        self.assertEqual(len(body), len(self.NAMES))
        self.settings = {}
        self.ct = types.SimpleNamespace(warm=Mock(), answer=Mock(return_value=None), early=Mock())
        self.cw = types.SimpleNamespace(ask=Mock(return_value=""))
        self.local = Mock(return_value={"text": "local", "by": "local"})
        tok = types.SimpleNamespace(apply_chat_template=lambda *a, **k: "", encode=lambda *a, **k: [1], chat_template="")
        self.rework_mod = types.SimpleNamespace(warm=Mock(), rework=Mock(return_value={}))
        sys.modules["rework"] = self.rework_mod
        for m in ("proofread", "facts", "translate"):
            sys.modules[m] = types.SimpleNamespace(check=Mock(), answer=Mock(return_value={}), translate=Mock(return_value={}), calendar=Mock())
        self.ns = dict(cloud=cloud, router=types.SimpleNamespace(online=lambda: True), settings_load=lambda: {"connect": {"provider": "cli"}, **self.settings},
                       claude_type=self.ct, claude_worker=self.cw, run=lambda *a, **k: self.local(), model=types.SimpleNamespace(tok=tok),
                       REPO="x", KEYS=[0], CLAUDE_CTX=2500, DATA=Path("/nonexistent"), REPLY_CACHE={}, OPTIONS="", re=__import__("re"),
                       time=__import__("time"), json=__import__("json"), Path=Path, _known=lambda w: False, local_rewrite=Mock(),
                       prompt_examples=lambda: [])
        exec(compile(ast.Module(body=body, type_ignores=[]), "server.py", "exec"), self.ns)

    def tearDown(self):
        for m in ("rework", "proofread", "facts", "translate"): sys.modules.pop(m, None)

    def test_pause_off_sends_nothing(self):
        self.settings = {"claudeTyping": True, "claudePause": False}
        self.ns["warm_claude"]()
        self.assertEqual(self.ns["pause"]({"before": "made-up line here "})["src"], "off")
        self.ns["ask_early"]({"before": "a made-up line ", "early": True})
        self.ct.warm.assert_not_called(); self.ct.answer.assert_not_called(); self.ct.early.assert_not_called()

    def test_pause_on_still_works(self):
        self.settings = {"claudeTyping": True, "claudePause": True}
        self.ns["warm_claude"]()
        self.ns["pause"]({"before": "made-up line here "})
        self.ns["ask_early"]({"before": "a made-up line ", "early": True})
        self.ct.warm.assert_called_once(); self.ct.answer.assert_called_once(); self.ct.early.assert_called_once()

    def test_reply_off(self):
        self.settings = {"nextMessage": False}
        self.assertEqual(self.ns["reply"]({"context": "three made up words and more"})["text"], "")
        self.cw.ask.assert_not_called()

    def test_rewrite_and_rework_off(self):
        self.settings = {"rework": False}
        self.assertEqual(self.ns["rewrite"]({"text": "made-up text", "instruction": "shorter"})["by"], "local")
        self.assertEqual(self.ns["rework"]({"text": "made-up text", "cmd": "shorter", "warm": True}), {})
        self.cw.ask.assert_not_called(); self.rework_mod.warm.assert_not_called()

    def test_quick_panel_with_rework_off_stays_local(self):
        # the Quick panel (app/Quick.swift) may still rewrite with rework off, on the local model only
        self.settings = {"rework": False}
        self.ns["rework"]({"text": "made-up text", "cmd": "shorter", "from": "quick"})
        self.rework_mod.rework.assert_called_once()
        self.assertIs(self.rework_mod.rework.call_args.kwargs["online"], False)
        self.assertEqual(self.ns["rework"]({"text": "made-up text", "cmd": "shorter", "from": "quick", "warm": True}), {})
        self.rework_mod.warm.assert_not_called(); self.cw.ask.assert_not_called()

    def test_rewrite_on_asks_claude(self):
        self.settings = {"rework": True}
        self.ns["rewrite"]({"text": "made-up text", "instruction": "shorter"})
        self.cw.ask.assert_called_once()

    def test_outline_off_stays_local(self):
        self.settings = {"callNotes": False}
        text = "a made-up call with enough words to ask for an outline of it right now please"
        self.assertEqual(self.ns["outline"]({"text": text, "call": True})["by"], "local")
        self.cw.ask.assert_not_called()

    def test_outline_on_asks_claude(self):
        self.settings = {"callNotes": True}
        self.cw.ask.return_value = '{"title": "Made-up title", "points": ["one"], "todos": []}'
        text = "a made-up call with enough words to ask for an outline of it right now please"
        self.assertEqual(self.ns["outline"]({"text": text, "call": True})["by"], "haiku")
        self.cw.ask.assert_called_once()

    def test_chips_off_with_claude_typing(self):
        self.settings = {"claudeTyping": False}
        self.assertEqual(self.ns["proof"]({"text": "x"})["src"], "off")
        self.assertEqual(self.ns["facts"]({}), {})
        self.assertEqual(self.ns["translate"]({}), {})
        sys.modules["proofread"].check.assert_not_called()


if __name__ == "__main__":
    unittest.main()
