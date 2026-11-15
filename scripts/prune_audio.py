"""Old call audio goes to the Trash once its transcript exists. Run by bench/nightly.sh (2026-11-14).

A recording folder under data/calls/ keeps its audio (*.wav) for KEEP_DAYS (14) days. After that, when the folder
holds a transcript.txt of at least MIN_TRANSCRIPT bytes and no `.unread` mark, the audio moves to
~/.Trash/drafter-audio-<day>/<folder>/. The transcript, notes, screenshots and meta stay. Nothing is deleted:
the Trash is the way back for a transcript that turns out bad. A folder without a transcript keeps its audio.

    python3 scripts/prune_audio.py [--data DIR] [--trash DIR] [--days N] [--dry-run]
"""
import argparse, shutil, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KEEP_DAYS = 14
MIN_TRANSCRIPT = 200


def due(calls: Path, now: float, days: int = KEEP_DAYS) -> list:
    """Audio files that may go: old enough, in a folder with a real transcript and no unread mark."""
    out = []
    if not calls.is_dir(): return out
    for folder in sorted(p for p in calls.iterdir() if p.is_dir()):
        t = folder / "transcript.txt"
        if not t.is_file() or t.stat().st_size < MIN_TRANSCRIPT or (folder / ".unread").exists(): continue
        for wav in sorted(folder.glob("*.wav")):
            if now - wav.stat().st_mtime > days * 86400: out.append(wav)
    return out


def move(files: list, trash: Path, dry: bool) -> int:
    size = 0
    for f in files:
        size += f.stat().st_size
        if dry: continue
        dest = trash / f.parent.name
        dest.mkdir(parents=True, exist_ok=True)
        shutil.move(str(f), str(dest / f.name))
    return size


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, default=ROOT / "data")
    ap.add_argument("--trash", type=Path, default=Path.home() / ".Trash" / f"drafter-audio-{time.strftime('%Y-%m-%d')}")
    ap.add_argument("--days", type=int, default=KEEP_DAYS)
    ap.add_argument("--dry-run", action="store_true")
    o = ap.parse_args()
    files = due(o.data / "calls", time.time(), o.days)
    size = move(files, o.trash, o.dry_run)
    print(f"prune_audio: {len(files)} audio files, {size / 1e6:.0f} MB {'would go' if o.dry_run else 'moved'} to the Trash")
    return 0


if __name__ == "__main__":
    sys.exit(main())
