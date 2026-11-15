"""Drafter's voice engine: Voice Notes' engine.py readers (2026-10-18), served as one process.

Same frames on stdin as Voice Notes (1 byte kind, 4 bytes little-endian count; kind 0 = float32 16 kHz samples):
  250 warm   - load Parakeet now (sent on the key press, while the microphone starts).
  255 end    - the take is over: {"text", "loud", "took"}.   254 drop.   252 long take (drafts every 2 s).
  249 careful - the part that ended last (since the end before it) is read with Whisper turbo: {"careful": text}.
  248 hint   - UTF-8 text (count = bytes): names seen on screen, first in Whisper's prompt for this take.
  247 file   - UTF-8 JSON {path, names, lang?}: a whole recording read by Whisper -> {"file", "segments": [{start, end, text}]}.
While a take runs it emits {"draft": text so far}.

Memory (Drafter rule): one voice model at a time. Parakeet (~1.3-1.6 GB once it has read a take) loads on the first
press and is dropped after DRAFTER_VOICE_IDLE seconds without a take (default 1800; the app sets it from the setting
voiceIdleMin). For a careful pass Parakeet is dropped first, Whisper
(~1.7 GB) reads, is dropped again, and Parakeet is loaded back at once for the next take. guard.py stops the process above
DRAFTER_VOICE_CAP_GB (default 2.8). With the text engine (<= 3.0) the two stay under ~5 GB at the very worst.
"""
import json
import os
import queue
import re
import struct
import sys
import threading
import time

# Models load from the local copy without asking Hugging Face first: that check cost 1-2 s on every load (Parakeet
# 0.38 s offline vs 1.3-2.4 s, 2026-10-21). If a model is not on disk yet, the load goes online once (online()).
os.environ.setdefault("HF_HUB_OFFLINE", "1")

import mlx.core as mx
import numpy as np
from stand_ins import install as install_stand_ins
install_stand_ins()  # before either voice reader; real packages always win
from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel

from voice_settings import load_models
from voice_language import fast_language, letter_scripts, russian_letters, prompt_echo, retain_fast, piece_text, text_words

MODEL, CAREFUL = load_models()
RATE = 16000
END, DROP, AGAIN, LONG = 255, 254, 253, 252
# A loud room: the quiet moments of the take are not quiet (above FLOOR dB) and the loud ones
# stand less than SPREAD dB over them. Measured on saved takes: a quiet room sits near -63 dB.
FLOOR, SPREAD = -50.0, 22.0
PIECE = 28 * RATE      # past this much open audio, close a piece at a pause
KEEP = 12 * RATE       # a piece is at least this long

# mlx_whisper 0.4.3 transcribe.py: these three scores are returned on every segment
# (shared by segments from a decoding window). Match its silence rule, including
# the confident-text override. Compression is also a final rejection here, not
# just a temperature retry. Consecutive words (5), phrases (3) / text tokens (6) catch loops;
# do not count repetitions across segments or reject by text length/duration.
WHISPER_NO_SPEECH = 0.6
WHISPER_LOGPROB = -1.0
WHISPER_COMPRESSION = 2.4
WHISPER_WORD_RUN = 5
WHISPER_TOKEN_RUN = 6
WHISPER_SPECIAL_TOKEN = 50256  # first special ID in English; multilingual starts at 50257


def repeated_run(items, limit):
    previous, count = None, 0
    for item in items:
        count = count + 1 if item == previous else 1
        if count >= limit:
            return True
        previous = item
    return False


def whisper_rejection(segment, language=None, prompt=None, fast_text=None, *, standalone=False):
    """Pure segment check; missing scores are unknown, never evidence of silence."""
    text = segment.get("text", "")
    no_speech, logprob = segment.get("no_speech_prob"), segment.get("avg_logprob")
    if (no_speech is not None and logprob is not None
            and no_speech > WHISPER_NO_SPEECH and logprob <= WHISPER_LOGPROB):
        return "no_speech"
    if 'OTHER' in letter_scripts(text):
        return "script"
    if (standalone or language == "uk" or "CYRILLIC" in letter_scripts(fast_text or "")) and russian_letters(text):
        return "russian"
    if not standalone and language == "uk" and "CYRILLIC" not in letter_scripts(text) and sum(
            "LATIN" in letter_scripts(w) for w in text_words(text)) >= 4:
        return "script"
    if prompt_echo(text, prompt, by_terms=not standalone):
        return "prompt_echo"
    ratio = segment.get("compression_ratio")
    if ratio is not None and ratio > WHISPER_COMPRESSION:
        return "compression"
    words = re.findall(r"[^\W_]+(?:['’ʼ][^\W_]+)*", segment.get("text", "").casefold())
    if repeated_run(words, WHISPER_WORD_RUN) or any(
            words[i:i + n] == words[i + n:i + 2*n] == words[i + 2*n:i + 3*n]
            for n in range(2, 5) for i in range(len(words) - 3*n + 1)):
        return "word_loop"
    # Timestamp/control tokens are not speech and must not create a loop.
    tokens = [t for t in segment.get("tokens", []) if 0 <= t < WHISPER_SPECIAL_TOKEN]
    if repeated_run(tokens, WHISPER_TOKEN_RUN):
        return "token_loop"
    return None


def whisper_segments(segments, language=None, prompt=None, fast_text=None, *, standalone=False):
    """Keep original times and metadata; callers build text only from kept segments."""
    return [s for s in segments if s.get("text", "").strip()
            and not whisper_rejection(s, language, prompt, fast_text, standalone=standalone)]


def rejected_words(segments, language=None, prompt=None, fast_text=None):
    """Only a rejected spoken segment invalidates a same-audio careful pass."""
    return any(letter_scripts(s.get("text", "")) and
               whisper_rejection(s, language, prompt, fast_text) not in (None, "no_speech")
               for s in segments)


def careful_allowed(audio, fast_text=None):
    # None means no fast result exists (e.g. file fallback after a reader error).
    # An actual empty fast result is authoritative; do not ask Whisper to fill it.
    return (fast_text is None or bool(fast_text.strip())) and has_speech(audio)

# MLX keeps freed buffers with no limit by default; that grew the old engine past 13 GB.
mx.set_cache_limit(512 * 1024 * 1024)
mx.set_cache_limit(256 * 1024 * 1024)   # Drafter: smaller free-buffer pool than Voice Notes
WARM, CAREFUL_END, HINT_KIND, FILE_KIND = 250, 249, 248, 247


def online(load):
    """Run a model load; when the local copy is missing, once more with Hugging Face reachable."""
    try:
        return load()
    except Exception as ex:
        import huggingface_hub.constants as hc
        missing = type(ex).__name__ in ("LocalEntryNotFoundError", "OfflineModeIsEnabled", "FileNotFoundError")
        if not hc.HF_HUB_OFFLINE or not missing:
            raise
        hc.HF_HUB_OFFLINE = False
        try:
            return load()
        finally:
            hc.HF_HUB_OFFLINE = True


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def has_speech(audio):
    """At least 5 frames of 30 ms above -40 dB (rms 0.010). Parakeet turns silence into "Yeah." / "Okay." / "Thank
    you."; on his saved takes (2026-10-22) every clip below this was one of those (57 of them, rms ~-60 dB), and no
    real dictation was."""
    F = 480
    n = audio.size // F
    if n < 5: return False
    fr = audio[: n * F].reshape(n, F)
    return int((np.sqrt((fr * fr).mean(axis=1)) > 0.010).sum()) >= 5


FILE_PIECE = 240 * RATE   # a recording is read 4 minutes at a time


def load_pcm16(path):
    """Drafter's own recordings are 16 kHz mono 16-bit: read as they are (half the memory of float); else ffmpeg."""
    import wave
    try:
        with wave.open(path) as w:
            if w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2:
                return np.frombuffer(w.readframes(w.getnframes()), np.int16)
    except (wave.Error, EOFError):
        pass
    from mlx_whisper.audio import load_audio
    return (np.clip(np.asarray(load_audio(path), np.float32), -1, 1) * 32767).astype(np.int16)


def pieces(a, size=FILE_PIECE):
    """(start, end) sample ranges of at most `size`, each cut at the quietest 0.4 s of its last 20 s."""
    out, start, w, step = [], 0, int(0.4 * RATE), RATE // 10
    while a.size - start > size:
        lo = start + size - 20 * RATE
        seg = a[lo:start + size]
        e = [float(np.mean(seg[i:i + w] ** 2)) for i in range(0, seg.size - w, step)]
        cut = lo + int(np.argmin(e)) * step + w // 2
        out.append((start, cut)); start = cut
    out.append((start, a.size))
    return out


def read(model, audio, gate=True):
    if audio.size < RATE // 4 or (gate and not has_speech(audio)):
        return ""
    try:
        mel = get_logmel(mx.array(audio, dtype=mx.float32), model.preprocessor_config)
        return model.generate(mel)[0].text.strip()
    finally:
        mx.clear_cache()


def glossary():
    """Andrii's own words, handed to Whisper as a hint so it spells them right: the 60 names he uses most from the
    names reference (data/names.json `voice`, engine/names.py, 2026-11-15), else the dictionary's first 60 terms."""
    data = os.path.join(os.path.dirname(__file__), "..", "data")
    if not os.environ.get("DRAFTER_WORDS") and os.environ.get("DRAFTER_NAMES") != "0":
        try:
            with open(os.path.join(data, "names.json")) as source:
                terms = json.load(source)["voice"]
            if terms: return "Glossary: " + ", ".join(terms[:60]) + "."
        except Exception:
            pass
    try:
        with open(os.environ.get("DRAFTER_WORDS") or os.path.join(data, "words.json")) as source:
            terms = json.load(source)["terms"]
        return "Glossary: " + ", ".join(terms[:60]) + "."
    except Exception:
        return None


HINT = glossary()


def careful(audio, names="", fast_text=None):
    """Whisper turbo: slower, holds up in a loud room. Loaded for one pass and dropped after it (Drafter keeps one
    voice model at a time)."""
    if not careful_allowed(audio, fast_text):
        return retain_fast("", fast_text)
    import mlx_whisper
    try:
        # names on screen for this take go first, then his dictionary (Whisper reads ~224 tokens of prompt)
        hint = (("Names: " + names + ". " if names else "") + (HINT or ""))[:900]
        language = fast_language(fast_text)
        r = online(lambda: mlx_whisper.transcribe(
            audio, path_or_hf_repo=CAREFUL, condition_on_previous_text=False, word_timestamps=False,
            verbose=None, initial_prompt=hint or None, language=language,
            no_speech_threshold=WHISPER_NO_SPEECH, logprob_threshold=WHISPER_LOGPROB,
            compression_ratio_threshold=WHISPER_COMPRESSION))
        segments = r.get("segments", [])
        kept = whisper_segments(segments, language, hint, fast_text)
        text = " ".join(x["text"].strip() for x in kept)
        return retain_fast(text, fast_text, rejected=rejected_words(segments, language, hint, fast_text))
    finally:
        mx.clear_cache()


def loud(audio):
    """Speech in a quiet room has deep gaps between words; in a loud room the gaps are full of
    other people."""
    win = RATE // 40
    n = audio.size // win
    if n < 40:
        return False
    e = 10 * np.log10((audio[:n * win].reshape(n, win) ** 2).mean(axis=1) + 1e-10)
    floor, top = np.percentile(e, 15), np.percentile(e, 90)
    return bool(floor > FLOOR and top - floor < SPREAD)


def lifted(model, audio):
    """Nothing was read, yet there is sound: soft speech next to a few sharp clicks (a key, a cup)
    reads as silence. Turn it up until speech sits at a normal level, let the clicks clip, read again."""
    win = RATE // 40
    n = audio.size // win
    if n < 20 or audio.size > 40 * RATE:
        return ""
    e = 10 * np.log10((audio[:n * win].reshape(n, win) ** 2).mean(axis=1) + 1e-10)
    top = float(np.percentile(e, 90))
    # below -50 dB there is no soft speech to save: turned up 30+ dB, a quiet room read as "Yeah." / "Okay." (2026-10-22,
    # the clips he never said sat at -55..-68 dB); already loud enough: turning it up changes nothing
    if top < -50 or top > -30:
        return ""
    gain = min(40.0, 10 ** ((-16 - top) / 20))
    return read(model, np.clip(audio * gain, -1, 1).astype(np.float32), gate=False)


def quiet(audio):
    """No speech in this bit of sound: every 25 ms of it below -42 dB (speech sits at -35..-15, a quiet room near -63)."""
    win = RATE // 40
    n = audio.size // win
    if n == 0:
        return True
    e = 10 * np.log10((audio[:n * win].reshape(n, win) ** 2).mean(axis=1) + 1e-10)
    return bool(e.max() < -42)


def pause(audio):
    """The quietest fifth of a second in the open audio, not too near either end."""
    lo, hi = KEEP, audio.size - 2 * RATE
    win = RATE // 5
    body = audio[lo:hi]
    n = body.size // win
    if n < 1:
        return audio.size
    e = (body[:n * win].reshape(n, win) ** 2).mean(axis=1)
    return lo + int(e.argmin()) * win + win // 2


class Take:
    def __init__(self, model):
        self.model = model
        self.audio = np.zeros(0, np.float32)   # the open piece
        self.closed = []                         # (audio, fast text) of the pieces already cut
        self.loud = False

    def add(self, data):
        self.audio = np.concatenate([self.audio, data])

    def draft(self):
        while self.audio.size > PIECE:
            cut = pause(self.audio)
            self.closed.append((self.audio[:cut], read(self.model, self.audio[:cut])))
            self.audio = self.audio[cut:]
        self.covered = self.audio.size
        self.last = " ".join(t for t in [t for _, t in self.closed] + [read(self.model, self.audio)] if t)
        return self.last

    covered, last = 0, ""

    def text(self):
        whole = np.concatenate([a for a, _ in self.closed] + [self.audio])
        self.loud = loud(whole)
        # he stops talking, then presses: when all that came after the last draft is quiet, that draft is the text
        # (2026-10-21: the end no longer waits for a second reading of up to 28 s of sound, ~100-300 ms)
        if self.last and quiet(self.audio[self.covered:]):
            return self.last
        return self.draft() or lifted(self.model, whole)


def frames(inp):
    while True:
        head = inp.read(5)
        if len(head) < 5:
            return
        kind, n = head[0], struct.unpack("<I", head[1:])[0]
        if kind in (HINT_KIND, FILE_KIND):   # UTF-8 text: names on screen (248), or a recording to read (247, JSON)
            yield kind, inp.read(n).decode("utf-8", "ignore")
            continue
        if kind != 0:
            yield kind, None
            continue
        data = inp.read(n * 4)
        if len(data) < n * 4:
            return
        yield 0, np.frombuffer(data, dtype=np.float32)



import gc  # noqa: E402
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import guard  # noqa: E402

guard.start(float(os.environ.get("DRAFTER_VOICE_CAP_GB", "2.8")))   # Whisper peaks ~2.5 GB
# 2026-11-14: 4 h -> 30 min. 4 h held it ~10.5 h a day for ~1.9 cold presses a day; 30 min holds it ~2.7 h for ~3.0
# (app.log, 210 takes 7-14 Nov). A reload after an idle drop logged 0.07-0.13 s (weights in the file cache), and the
# press itself sends the warm frame (250) while the microphone starts, so the load overlaps the first words.
IDLE = float(os.environ.get("DRAFTER_VOICE_IDLE", "1800"))


class Readers:
    def __init__(self):
        self.fast = None

    def warm(self):
        if self.fast is None:
            t = time.perf_counter()
            self.fast = online(lambda: from_pretrained(MODEL))
            # the first pass is slow: pay for it now, on soft noise past the speech gate (silence never reached the model,
            # so until 2026-11-14 the first words of a take after each load cost 160-1,300 ms instead of ~85; the text
            # read here is thrown away)
            read(self.fast, (np.random.default_rng(0).standard_normal(RATE) * 0.05).astype(np.float32), gate=False)
            emit({"loaded": "parakeet", "s": round(time.perf_counter() - t, 2)})
        return self.fast

    def drop(self, why):
        if self.fast is not None:
            self.fast = None
            gc.collect(); mx.clear_cache()
            emit({"unloaded": "parakeet", "why": why})

    def read_file(self, path, names="", lang=None):
        """A whole recording (one side of a call, or a long note) as timed segments. Parakeet first: it is the model
        already loaded, reads 6.6 min in ~5 s and kept Ukrainian Ukrainian, where Whisper turned the same call
        Russian (2026-10-22 call, compared 2026-10-29). Whisper is the fallback. The guard allows 3.4 GB for this
        job only: the old whole-file Whisper pass peaked at 2.93 GB and the 2.8 GB guard killed it, so calls lost
        their final transcript."""
        with guard.allow(float(os.environ.get("DRAFTER_FILE_CAP_GB", "3.4"))):
            try:
                return self.read_file_fast(path)
            except Exception as ex:
                emit({"file_fallback": str(ex)[:200]})
            return self.read_file_whisper(path, names, lang)

    def read_file_fast(self, path):
        m = self.warm()
        pcm = load_pcm16(path)
        r = m.transcribe(path, chunk_duration=60, overlap_duration=10)
        out = []
        for x in r.sentences:
            t = x.text.strip()
            if not t: continue
            part = pcm[int(x.start * RATE):int(x.end * RATE) + 1].astype(np.float32) / 32768
            if not has_speech(part): continue   # Parakeet writes "Yeah." / "Okay." into silence
            out.append({"start": round(float(x.start), 2), "end": round(float(x.end), 2), "text": t})
        return out

    def read_file_whisper(self, path, names="", lang=None, fast_text=None, fast_segments=None):
        """Whisper, 4 minutes at a time cut at a quiet spot (memory stays flat on hour-long calls); silent pieces are
        skipped (made-up lines); `lang` ("uk", "en") comes from the live text."""
        if fast_text is not None and not fast_text.strip():
            return []
        self.drop("file")
        import mlx_whisper
        try:
            a = load_pcm16(path).astype(np.float32) / 32768
            hint = (("Names: " + names + ". " if names else "") + (HINT or ""))[:900]
            out = []
            for s, e in pieces(a):
                part = a[s:e]
                # Timed fast text gives each piece its own language. An untimed
                # result belongs here only if this piece is the entire file.
                fast_piece = (piece_text(fast_segments, s / RATE, e / RATE) if fast_segments is not None
                              else fast_text if s == 0 and e == a.size else None)
                if not careful_allowed(part, fast_piece):
                    if fast_piece:
                        out.append({"start": round(s / RATE, 2), "end": round(e / RATE, 2), "text": fast_piece})
                    continue
                language = fast_language(fast_piece) or (lang if lang in ("uk", "en") else None)
                r = online(lambda: mlx_whisper.transcribe(part, path_or_hf_repo=CAREFUL, condition_on_previous_text=False, word_timestamps=False,
                                                          verbose=None, initial_prompt=hint[:900] or None,
                                                          no_speech_threshold=WHISPER_NO_SPEECH, logprob_threshold=WHISPER_LOGPROB,
                                                          compression_ratio_threshold=WHISPER_COMPRESSION,
                                                          language=language))
                off = s / RATE
                segments = r.get("segments", [])
                kept = whisper_segments(segments, language, hint, fast_piece, standalone=fast_piece is None)
                text = " ".join(x["text"].strip() for x in kept)
                if fast_piece and retain_fast(text, fast_piece, rejected_words(segments, language, hint, fast_piece)) == fast_piece:
                    # Fast text has piece bounds, not Whisper's rejected timings.
                    out.append({"start": round(off, 2), "end": round(e / RATE, 2), "text": fast_piece})
                else:
                    out += [{"start": round(x["start"] + off, 2), "end": round(x["end"] + off, 2), "text": x["text"].strip()}
                            for x in kept]
            return out
        finally:
            wt = sys.modules.get("mlx_whisper.transcribe")
            if wt is not None: wt.ModelHolder.model = None; wt.ModelHolder.model_path = None
            gc.collect(); mx.clear_cache()

    def careful(self, audio, names="", fast_text=None):
        if not careful_allowed(audio, fast_text):
            return retain_fast("", fast_text)
        self.drop("careful pass")
        try:
            return careful(audio, names, fast_text)
        finally:
            wt = sys.modules.get("mlx_whisper.transcribe")
            if wt is not None: wt.ModelHolder.model = None; wt.ModelHolder.model_path = None
            gc.collect(); mx.clear_cache()


def serve():
    q = queue.Queue()

    def pump():
        for f in frames(sys.stdin.buffer):
            q.put(f)
        q.put((None, None))

    threading.Thread(target=pump, daemon=True).start()
    emit({"ready": True})
    r = Readers()
    # Draft pace: every 0.15 s of new sound until the first words show (first words sooner), then as often as the
    # reading allows - 1.5x what the last draft cost, 0.2-0.5 s - so drafts never pile up late in a long piece.
    FIRST = 0.15
    take, fresh, gap, since = None, 0, FIRST, time.time()
    pending = []          # samples for a careful pass
    pending_text = None   # final fast result for exactly those samples; None = not read yet
    names = ""            # names on screen for this take
    while True:
        try:
            kind, data = q.get(timeout=5)
        except queue.Empty:
            if take is None and time.time() - since > IDLE: r.drop("idle")
            continue
        batch = [(kind, data)]
        while not q.empty():
            batch.append(q.get())
        for kind, data in batch:
            since = time.time()
            if kind is None:
                return
            if kind == HINT_KIND:
                names = data or ""
                continue
            if kind == FILE_KIND:
                try:
                    job = json.loads(data or "{}")
                    t = time.perf_counter()
                    segs = r.read_file(job["path"], job.get("names", ""), job.get("lang"))
                    emit({"file": job["path"], "segments": segs, "took": round(time.perf_counter() - t, 1)})
                except Exception as ex:
                    emit({"file": "", "segments": [], "error": str(ex)[:200]})
                r.warm()
                continue
            if kind == WARM:
                pending = []      # a new take: what a careful pass reads starts here
                pending_text = None
                r.warm()
            elif kind == 0:
                pending_text = None
                if take is None: take = Take(r.warm())
                take.add(data); pending.append(data)
                fresh += data.size
            elif kind in (END, AGAIN):
                t = time.perf_counter()
                text = take.text() if take else ""
                emit({"text": text, "loud": take.loud if take else False, "took": round(time.perf_counter() - t, 3)})
                # a careful pass reads only this part: an Enter piece before it is already in the field
                pending = [np.concatenate([a for a, _ in take.closed] + [take.audio])] if take else []
                pending_text = text
                take, fresh, gap = None, 0, FIRST
            elif kind == DROP:
                take, fresh, gap, pending = None, 0, FIRST, []
                pending_text = None
            elif kind == LONG:
                gap = 2.0
            elif kind == CAREFUL_END:
                t = time.perf_counter()
                try:
                    text = r.careful(np.concatenate(pending), names, fast_text=pending_text) if pending else ""
                except Exception as ex:
                    text = pending_text or ""; sys.stderr.write(str(ex)[:200] + "\n")
                pending = []
                pending_text = None
                emit({"careful": text, "took": round(time.perf_counter() - t, 3)})
                r.warm()          # ready again for the next take
        if take is not None and fresh >= RATE * gap:
            fresh = 0
            t = time.perf_counter()
            d = take.draft()
            emit({"draft": d, "ms": int((time.perf_counter() - t) * 1000)})
            if gap < 1:   # not a long note (2 s)
                gap = FIRST if not d else max(0.2, min(0.5, 1.5 * (time.perf_counter() - t)))


if __name__ == "__main__":
    serve()
