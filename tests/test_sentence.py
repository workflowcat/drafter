"""The cloud whole-sentence pass (engine/sentence.py, round "earlier" step 5). Made-up lines only; no network, no
`claude` process: providers are stand-ins, the server function runs from its source.

    .venv/bin/python -B tests/test_sentence.py
"""
import ast, sys, unittest
from pathlib import Path
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
import cloud, sentence


class Last(unittest.TestCase):
    def test_full_stop_ends_a_sentence(self):
        t = "first one is here. we can meet tomorow at noon."
        self.assertEqual(sentence.last(t), (19, "we can meet tomorow at noon."))
        self.assertEqual(sentence.last(t + " "), (19, "we can meet tomorow at noon."))

    def test_no_end_no_rest_nothing(self):
        self.assertIsNone(sentence.last("we can meet tomorow at noon"))

    def test_rest_after_six_words(self):
        self.assertEqual(sentence.last("ok. we can meet tomorow at noon", rested=True), (4, "we can meet tomorow at noon"))
        self.assertIsNone(sentence.last("ok. we can meet", rested=True))

    def test_a_new_line_starts_a_sentence(self):
        self.assertEqual(sentence.last("hi all\nthe build is redy now!"), (7, "the build is redy now!"))

    def test_short_or_empty(self):
        self.assertIsNone(sentence.last("ok."))
        self.assertIsNone(sentence.last(""))


class Race(unittest.TestCase):
    def test_first_answer_wins(self):
        import time
        slow = lambda: (time.sleep(0.2), ("slow", 200, 200))[1]
        fast = lambda: ("fast", 10, 10)
        self.assertEqual(sentence.race("x", providers={"haiku": slow, "cf": fast})[:2], ("fast", "cf"))

    def test_a_failed_provider_does_not_win(self):
        self.assertEqual(sentence.race("x", providers={"haiku": lambda: ("ok", 5, 9), "cf": lambda: None})[1], "haiku")
        self.assertIsNone(sentence.race("x", providers={"haiku": lambda: None, "cf": lambda: None}))

    def test_edits_land_in_the_whole_text(self):
        text = "first one is here. we can meet tomorow at noon."
        at, s = sentence.last(text)
        r = sentence.check(text, at, providers={"haiku": lambda: ("we can meet tomorrow at noon.", 5, 9)})
        self.assertEqual([(e["old"], e["new"]) for e in r["edits"]], [("tomorow", "tomorrow")])
        e = r["edits"][0]
        self.assertEqual(text[e["at"]:e["at"] + e["len"]], "tomorow")
        self.assertEqual(r["fixed"], "first one is here. we can meet tomorrow at noon.")

    def test_his_words_stay(self):
        # his own words come from data/ live; the test brings a made-up set instead (tests never read live data)
        import proofread
        from unittest.mock import patch
        text = "шо там по договору, тіки чесно."
        with patch.object(proofread, "_keep", lambda: {"шо", "тіки"}):
            r = sentence.check(text, 0, providers={"haiku": lambda: ("що там по договору, тільки чесно.", 5, 9)})
        self.assertEqual(r["edits"], [])

    def test_his_model_first_haiku_on_failure(self):
        asked = []
        class W:
            def __init__(self, m): self.m = m
            def ask(self, *a, **k):
                asked.append(self.m); return None if self.m == "sonnet" else ("ok", 5, 9)
        with unittest.mock.patch.object(sentence, "_worker", lambda m: W(m)):
            self.assertEqual(sentence.ask_claude("we can meet tomorow at noon.", model="sonnet")[0], "ok")
        self.assertEqual(asked, ["sonnet", "haiku"])
        asked.clear()
        with unittest.mock.patch.object(sentence, "_worker", lambda m: W(m)):
            sentence.ask_claude("x y z", model="haiku")
        self.assertEqual(asked, ["haiku"])

    def test_server_passes_his_model(self):
        self.assertIn('model=req.get("model") or st.get("claudeModel", "sonnet")', server_fn("sentence_proof"))

    def test_no_cf_key_no_cf_call(self):
        with unittest.mock.patch("urllib.request.urlopen") as op:
            self.assertIsNone(sentence.ask_cf("we can meet tomorow at noon.", env={}))
            op.assert_not_called()


def server_fn(name):
    src = (ROOT / "engine/server.py").read_text()
    tree = ast.parse(src)
    node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == name)
    return ast.get_source_segment(src, node)


class Gate(unittest.TestCase):
    """Switch off or offline: no provider is asked at all."""
    def run_fn(self, settings, online):
        calls = Mock(return_value={"edits": [], "fixed": ""})
        ns = {"settings_load": lambda: settings, "KEYS": [0], "DATA": Path("/nonexistent"), "sys": sys,
              "sentence_mod": Mock(check=calls, last=sentence.last),
              "claude_on": lambda f, st=None: cloud.OWNERS.get(f) is not None and all(st.get(k) is True for k in cloud.OWNERS[f]) and online}
        exec(server_fn("sentence_proof"), ns)
        out = ns["sentence_proof"]({"text": "first. we can meet tomorow at noon.", "app": "Notes"})
        return out, calls

    def test_off_means_no_call(self):
        out, calls = self.run_fn({"claudeTyping": True, "sentenceProof": False}, True)
        self.assertEqual(out.get("src"), "off"); calls.assert_not_called()
        out, calls = self.run_fn({"claudeTyping": False, "sentenceProof": True}, True)
        calls.assert_not_called()

    def test_offline_means_no_call(self):
        out, calls = self.run_fn({"claudeTyping": True, "sentenceProof": True}, False)
        calls.assert_not_called()

    def test_on_and_online_asks(self):
        out, calls = self.run_fn({"claudeTyping": True, "sentenceProof": True}, True)
        calls.assert_called_once()

    def test_owner_and_default_off(self):
        self.assertEqual(cloud.OWNERS["sentence"], ("claudeTyping", "sentenceProof"))
        self.assertIs(cloud.DEFAULTS["sentenceProof"], False)
        self.assertIn("sentenceProof", cloud.NEVER_ON)

    def test_route_and_cloud_check(self):
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn('if self.path == "/sentence": return self.send(sentence_proof(req))', src)
        self.assertIn('claude_on("sentence", st)', server_fn("sentence_proof"))


if __name__ == "__main__":
    unittest.main()
