import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import facts as f

FACTS = """Now: Sun 01 Nov 2026 01:40 (Europe/Kyiv)
His calendar, next 14 days:
- Mon 02 Nov 11:30-12:00 · Sync · with Ira · meet https://meet.google.com/abc-defg-hij
He is free for 30 minutes at (weekdays 09:00-18:00):
- Tue 03 Nov 09:00
His saved texts:
- ;mail: au@example.com
- ;cal: https://cal.example.com/au"""


class Grounded(unittest.TestCase):
    def test_kept(self):
        for t in ["в понеділок о 11:30", "Tue at 9:00", "https://meet.google.com/abc-defg-hij", "au@example.com", "ось: https://cal.example.com/au."]:
            self.assertTrue(f.grounded(t, FACTS), t)

    def test_dropped(self):
        for t in ["о 14:00", "https://meet.google.com/xyz", "me@example.com", "у понеділок", "+380 67 123 4567"]:
            self.assertFalse(f.grounded(t, FACTS), t)

    def test_day_and_free(self):
        # the time alone is not enough: the day next to it and "free" must fit too (Codex review 2026-11-01)
        for t in ["Friday at 11:30", "I'm free at 11:30", "вільний у понеділок о 11:30", "у вівторок о 11:30", "завтра о 09:00",
                  "Wed 11 Nov at 09:00", "3 листопада о 11:30"]:
            self.assertFalse(f.grounded(t, FACTS), t)
        for t in ["free on Tue at 9:00", "можу у вівторок о 09:00", "о 11:30", "завтра о 11:30", "Mon 02 Nov 11:30",
                  "2 листопада о 11:30", "Nov 3 at 09:00", "the sync ends at 12:00"]:
            self.assertTrue(f.grounded(t, FACTS), t)

    def test_question_gate(self):
        self.assertTrue(f.asks("Сава: коли дзвінок"))
        self.assertTrue(f.asks("ok. what's your email?"))
        self.assertFalse(f.asks("thanks, see you"))
        self.assertFalse(f.asks(""))


if __name__ == "__main__":
    unittest.main()
