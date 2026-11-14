import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import translate as t


class Lang(unittest.TestCase):
    def test_lang(self):
        self.assertEqual(t.lang("привіт, можемо завтра поговорити"), "uk")
        self.assertEqual(t.lang("hi, can we talk tomorrow about it"), "en")
        self.assertEqual(t.lang("привіт, глянь PR в repo про deploy pipeline"), None)   # mixed
        self.assertEqual(t.lang("ок"), None)                                          # too short
        self.assertEqual(t.lang("привет, это всё ещё не готово, объясни"), None)       # Russian


class Kept(unittest.TestCase):
    def test_kept(self):
        self.assertTrue(t.kept("привіт, можемо завтра о 15:00?", "hi, can we do tomorrow at 15:00?", "en"))
        self.assertTrue(t.kept("ось лінк https://x.y/a", "here's the link https://x.y/a", "en"))
        self.assertTrue(t.kept("sure, send it over", "так, скидай", "uk"))

    def test_dropped(self):
        self.assertFalse(t.kept("привіт, можемо завтра о 15:00?", "hi, can we do tomorrow at 3 pm?", "en"))        # time lost
        self.assertFalse(t.kept("ось лінк https://x.y/a", "here's the link", "en"))                              # link lost
        self.assertFalse(t.kept("sure, send it over please", "конечно, присылай пожалуйста", "uk"))               # Russian
        self.assertFalse(t.kept("привіт, як справи?", "привіт, як справи?", "en"))                               # same
        self.assertFalse(t.kept("ок", "Okay, I will send the whole document and the notes in the evening", "en"))  # too long


if __name__ == "__main__":
    unittest.main()
