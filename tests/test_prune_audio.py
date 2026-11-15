"""scripts/prune_audio.py: only old audio with a real transcript moves; made-up folders in a temp dir.

    .venv/bin/python -B tests/test_prune_audio.py
"""
import os, sys, tempfile, time, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import prune_audio as pa

DAY = 86400


def folder(root: Path, name: str, age_days: float, transcript: int = 500, unread: bool = False) -> Path:
    d = root / "calls" / name; d.mkdir(parents=True)
    for n in ("me.wav", "them.wav"):
        (d / n).write_bytes(b"\0" * 1000)
        t = time.time() - age_days * DAY; os.utime(d / n, (t, t))
    if transcript: (d / "transcript.txt").write_text("x" * transcript)
    (d / "meta.json").write_text("{}")
    if unread: (d / ".unread").write_text("")
    return d


class Prune(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.old = folder(self.root, "old", 20)
        self.new = folder(self.root, "new", 3)
        self.bare = folder(self.root, "no-transcript", 20, transcript=0)
        self.thin = folder(self.root, "thin-transcript", 20, transcript=20)
        self.unread = folder(self.root, "unread", 20, unread=True)

    def tearDown(self): self.tmp.cleanup()

    def test_only_old_with_transcript(self):
        got = pa.due(self.root / "calls", time.time())
        self.assertEqual(sorted(p.parent.name for p in got), ["old", "old"])

    def test_move_keeps_text_and_is_a_move(self):
        trash = self.root / "trash"
        files = pa.due(self.root / "calls", time.time())
        self.assertEqual(pa.move(files, trash, dry=False), 2000)
        self.assertEqual(sorted(p.name for p in (trash / "old").iterdir()), ["me.wav", "them.wav"])
        self.assertEqual(sorted(p.name for p in self.old.iterdir()), ["meta.json", "transcript.txt"])
        for d in (self.new, self.bare, self.thin, self.unread): self.assertTrue((d / "me.wav").exists())

    def test_dry_run_moves_nothing(self):
        files = pa.due(self.root / "calls", time.time())
        pa.move(files, self.root / "trash", dry=True)
        self.assertTrue((self.old / "me.wav").exists()); self.assertFalse((self.root / "trash").exists())

    def test_missing_calls_folder(self):
        self.assertEqual(pa.due(self.root / "none", time.time()), [])


if __name__ == "__main__":
    unittest.main()
