import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import claude_type as ct
ct.CLI = sys.executable   # any file that exists: the tests replace the calls; the `claude` integration may be off here


class Clean(unittest.TestCase):
    def test_new_words_after_space(self):
        self.assertEqual(ct.clean("завтра в нас дзвінок з ", " Савою о третій"), "Савою о третій")

    def test_finishes_half_word(self):
        self.assertEqual(ct.clean("can you chec", "k the build"), "k the build")

    def test_repeated_half_word_is_cut(self):
        self.assertEqual(ct.clean("can you chec", "check the build"), "k the build")

    def test_space_added_after_whole_word(self):
        known = {"so", "the", "plan", "chec"}.__contains__
        self.assertEqual(ct.clean("ok so", "the plan is", known=known), " the plan is")
        self.assertEqual(ct.clean("can you chec", "k it", known=known), "k it")

    def test_stops_at_sentence_end_without_full_stop(self):
        self.assertEqual(ct.clean("ok ", "let's do it. Then we ship"), "let's do it")
        self.assertEqual(ct.clean("ok ", "are you sure? Then"), "are you sure?")

    def test_nothing(self):
        for out in ("∅", "", " ∅", "щас скажу ещё"):
            self.assertEqual(ct.clean("ну ", out), "")

    def test_one_line_and_word_cap(self):
        self.assertEqual(ct.clean("a ", "b c\nd"), "b c")
        self.assertEqual(len(ct.clean("a ", " ".join("w" * 3 for _ in range(20))).split()), 9)

    def test_repeated_last_word_is_cut(self):
        self.assertEqual(ct.clean("next I want to ", "to make it fast"), "make it fast")

    def test_enough(self):
        self.assertTrue(ct._enough("so we ship it. "))
        self.assertFalse(ct._enough("so we ship"))


class EarlyTest(unittest.TestCase):
    def setUp(self):
        self.saved = (ct._early.copy(), ct.complete)
        ct._early.update(want=None, busy=False, running=None, done=None, asked=0, used=0, times=[])

    def tearDown(self):
        ct._early.clear(); ct._early.update(self.saved[0]); ct.complete = self.saved[1]

    def done(self, before, text, app="Beeper", age=0, title="", context=""):
        ct._early["done"] = {"before": before, "text": text, "where": ct._where(app, title, context, "", "sonnet"), "at": __import__("time").time() - age,
                             "raw": text, "ms": 1400, "first_ms": 1300, "model": "sonnet", "turn": 1}

    def test_fit(self):
        self.done("so the plan is to ", "find a small shop")
        d, w = ct._early["done"], ct._where("Beeper", "", "", "", "sonnet")
        self.assertEqual(ct._fit(d, "so the plan is to ", w), "find a small shop")
        self.assertEqual(ct._fit(d, "so the plan is to fi", w), "nd a small shop")
        self.assertEqual(ct._fit(d, "so the plan is to find ", w), "a small shop")
        self.assertIsNone(ct._fit(d, "so the plan is to go", w))
        self.assertIsNone(ct._fit(d, "so the plan is to find a small shop", w))   # all typed: nothing left
        self.assertIsNone(ct._fit(d, "so the plan is to ", ct._where("Mail", "", "", "", "sonnet")))
        self.done("so the plan is to ", "find", age=120)
        self.assertIsNone(ct._fit(ct._early["done"], "so the plan is to f", w))

    def test_other_chat_never_takes_it(self):
        self.done("ok so ", "let's ship it", title="Ira", context="Ira: when do we ship?")
        ct.complete = lambda *a, **k: None
        self.assertIsNone(ct.answer("ok so ", "Beeper", "Oleh", "Oleh: are you coming?"))
        r = ct.answer("ok so ", "Beeper", "Ira", "Ira: when do we ship?")
        self.assertEqual(r["text"], "let's ship it")
        self.assertIsNone(ct._fit(ct._early["done"], "ok so ", ct._where("Beeper", "Ira", "Ira: when do we ship?", "", "sonnet", 3)))   # clicked since

    def test_pause_uses_early_answer_without_asking(self):
        ct.complete = lambda *a, **k: self.fail("asked again")
        self.done("ok so the plan is to ", "find a shop")
        r = ct.answer("ok so the plan is to fi", "Beeper")
        self.assertEqual((r["text"], r["early"]), ("nd a shop", True))
        self.assertEqual(ct._early["used"], 1)

    def test_pause_waits_for_early_at_same_caret(self):
        import threading, time
        ct.complete = lambda *a, **k: self.fail("asked again")
        ct._early["running"] = ("ok so ", ct._where("Beeper", "", "", "", "sonnet"))
        def finish():
            time.sleep(0.15); self.done("ok so ", "let's ship it"); ct._early["running"] = None
        threading.Thread(target=finish).start()
        r = ct.answer("ok so ", "Beeper")
        self.assertEqual((r["text"], r["early"]), ("let's ship it", True))

    def test_pause_asks_fresh_when_early_does_not_fit(self):
        self.done("ok so ", "let's ship it")
        ct.complete = lambda before, *a, **k: {"text": "e it", "raw": "e it", "ms": 900, "first_ms": 800, "model": "sonnet", "turn": 2}
        r = ct.answer("ok so we clos", "Beeper")
        self.assertEqual((r["text"], r["early"]), ("e it", False))

    def test_early_queue_latest_wins(self):
        import threading, time
        seen, gate = [], threading.Event()
        def fake(before, *a, **k):
            seen.append(before); gate.wait(1)
            return {"text": "x", "raw": "x", "ms": 1, "first_ms": 1, "model": "sonnet", "turn": 1}
        ct.complete = fake
        self.assertTrue(ct.early("one two ", "Beeper"))
        time.sleep(0.05)
        ct.early("one two three ", "Beeper"); ct.early("one two three four ", "Beeper")
        gate.set(); time.sleep(0.3)
        self.assertEqual(seen, ["one two ", "one two three four "])


class HintTest(unittest.TestCase):
    def test_hint_goes_after_notes_before_screen(self):
        hint = "Keyboard now: Ukrainian. A hint.\nChat with: Вигадана Особа\n"
        u = ct._user("привіт, як ", "Beeper", "", "рядок чату вище", notes="коротко", hint=hint)
        self.assertLess(u.index("His writing instructions"), u.index("Keyboard now"))
        self.assertLess(u.index("Chat with: Вигадана Особа"), u.index("On screen above the field"))
        self.assertNotIn("Keyboard", ct._user("привіт, як ", "Beeper", "", ""))
        self.assertIn("Chat with: X\nOn screen", ct._user("a", "B", "", "ctx", hint="Chat with: X"))   # a line end is added

    def test_other_hint_is_another_place(self):
        self.assertNotEqual(ct._where("Beeper", "", "c", "", "sonnet"), ct._where("Beeper", "", "c", "", "sonnet", hint="Keyboard now: English.\n"))
        self.assertEqual(ct._where("Beeper", "", "c", "", "sonnet"), ct._where("Beeper", "", "c", "", "sonnet", hint=""))


class GateTest(unittest.TestCase):
    W = [("let's", [0.4]), (" ship", [0.2, 0.3]), (" it", [0.002]), (" today", [0.6])]

    def test_keeps_words_until_the_first_unlikely_one(self):
        self.assertEqual(ct.cut_words(self.W, 0.05, 0.01), "let's ship")

    def test_never_resumes_after_a_failed_word(self):
        self.assertNotIn("today", ct.cut_words(self.W, 0.05, 0.01))

    def test_nothing_left(self):
        self.assertEqual(ct.cut_words([("ok", [0.001])], 0.05, 0.01), "")
        self.assertEqual(ct.cut_words(None, 0.05, 0.01), "")

    def test_leading_space_kept(self):
        self.assertEqual(ct.cut_words([(" the", [0.5]), (" plan", [0.5])], 0.05, 0.01), " the plan")

    def test_weakest_token_counts(self):
        self.assertEqual(ct.cut_words([("обговорити", [0.9, 0.9, 0.005])], 0.05, 0.01), "")


if __name__ == "__main__":
    unittest.main()
