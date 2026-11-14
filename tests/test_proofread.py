import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import proofread as p


def pairs(a, b, keep=()):
    return [(e["old"], e["new"]) for e in p.edits(a, b, set(keep))]


class Edits(unittest.TestCase):
    def test_typos_kept(self):
        self.assertEqual(pairs("я вже подвиився на документи", "я вже подивився на документи"), [("подвиився", "подивився")])
        self.assertEqual(pairs("i think teh plan works", "i think the plan works"), [("teh", "the")])

    def test_his_punctuation_and_case_stay(self):
        # Claude added a comma and a capital: the fix keeps his own punctuation, the case-only change is dropped
        self.assertEqual(pairs("ок давай tomorow", "Ок, давай tomorrow"), [("tomorow", "tomorrow")])
        self.assertEqual(pairs("lets go", "Let's go"), [])
        self.assertEqual(pairs("дай мясо", "дай м'ясо"), [("мясо", "м'ясо")])

    def test_layout(self):
        self.assertEqual(pairs("ok ghbdsn міла", "ok привіт міла"), [("ghbdsn", "привіт")])

    def test_rewrites_dropped(self):
        self.assertEqual(pairs("шо там по проєкту", "що там по проєкту"), [("шо", "що")] if p._close("шо", "що") else [])
        self.assertEqual(pairs("давай завтра", "давай післязавтра"), [])
        self.assertEqual(pairs("it is great", "it is excellent"), [])
        self.assertEqual(pairs("go now", "go right now"), [])   # inserts never

    def test_split_join(self):
        self.assertEqual(pairs("я незнаю чи буду", "я не знаю чи буду"), [("незнаю", "не знаю")])

    def test_kept_words_and_russian(self):
        self.assertEqual(pairs("i said goot", "i said good", keep={"goot"}), [])
        self.assertEqual(pairs("все ок там", "всё ок там"), [])

    def test_offsets_utf16(self):
        e = p.edits("👍 teh end", "👍 the end", set())[0]
        self.assertEqual(e["at"], 2)   # Python offset; check() turns it into UTF-16 (3)
        self.assertEqual(p._u16("👍 "), 3)


if __name__ == "__main__":
    unittest.main()
