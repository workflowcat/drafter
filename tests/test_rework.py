import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import rework as r


class Kept(unittest.TestCase):
    def test_kept(self):
        t = "давай завтра о 15:00 глянемо документи, лінк https://x.y/a"
        self.assertTrue(r.kept(t, "давай завтра о 15:00 подивимось документи, лінк https://x.y/a", "clearer"))
        self.assertFalse(r.kept(t, "давай завтра подивимось документи, лінк https://x.y/a", "clearer"))   # a time lost
        self.assertTrue(r.kept(t, "завтра о 15:00, https://x.y/a", "shorter"))
        self.assertTrue(r.kept(t, "завтра, https://x.y/a", "shorter"))                                   # numbers may go
        self.assertFalse(r.kept(t, "завтра о 15:00", "shorter"))                                         # a link may not
        self.assertFalse(r.kept(t, t, "fix"))                                                             # nothing changed
        self.assertFalse(r.kept(t, "давай завтра о 15:00 посмотрим документы https://x.y/a", "fix"))     # Russian
        self.assertFalse(r.kept("short one", "a much longer one that is not shorter at all", "shorter"))

    def test_target(self):
        self.assertEqual(r.target("привіт, можемо завтра поговорити?"), "en")
        self.assertEqual(r.target("hi, can we talk tomorrow about it?"), "uk")

    def test_instruction(self):
        self.assertIn("English", r.instruction("translate", "привіт, можемо завтра поговорити?"))
        self.assertEqual(r.instruction("custom", "x", "  make it a haiku "), "make it a haiku")
        self.assertEqual(r.rework("text", "nope"), {})


if __name__ == "__main__": unittest.main()
