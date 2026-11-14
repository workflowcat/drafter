"""Round nine: handwritten segments, numpy fixtures, inert model/Metal imports only."""
import contextlib
import ast
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
import wave
from unittest.mock import Mock, patch

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@contextlib.contextmanager
def fake_voice():
    mx = types.ModuleType('mlx.core')
    for name in ('set_cache_limit', 'clear_cache', 'set_memory_limit', 'reset_peak_memory', 'synchronize'):
        setattr(mx, name, Mock())
    mx.get_peak_memory = lambda: 0
    mlx = types.ModuleType('mlx')
    mlx.core = mx
    forbidden = Mock(side_effect=AssertionError('No model loads'))
    whisper = types.SimpleNamespace(transcribe=Mock())
    fake = {'mlx': mlx, 'mlx.core': mx,
            'stand_ins': types.SimpleNamespace(install=Mock()),
            'parakeet_mlx': types.SimpleNamespace(from_pretrained=forbidden),
            'parakeet_mlx.audio': types.SimpleNamespace(get_logmel=forbidden),
            'mlx_whisper': whisper,
            'guard': types.SimpleNamespace(start=Mock(), footprint_gb=lambda: 0.1)}
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        (root / 'settings.json').write_text('{}')
        (root / 'words.json').write_text('{"terms":[]}')
        with patch.dict(os.environ, DRAFTER_VOICE_SETTINGS=str(root / 'settings.json'),
                        DRAFTER_WORDS=str(root / 'words.json')), patch.dict(sys.modules, fake), \
                patch.object(sys, 'path', list(sys.path)):
            yield load('voice_guard_fixture', 'engine/voice.py'), whisper
        forbidden.assert_not_called()


def segment(text, **scores):
    return dict(start=0.0, end=1.0, text=text, avg_logprob=-0.2, no_speech_prob=0.05,
                compression_ratio=1.2, tokens=[1, 2, 3]) | scores


class Guard(unittest.TestCase):
    def setUp(self):
        self.voice, self.whisper = self.enterContext(fake_voice())

    def test_short_answers_kept_even_with_high_no_speech_when_confident(self):
        items = [segment(text, no_speech_prob=0.95) for text in ('так', 'ок', 'yes', 'добре')]
        self.assertEqual(self.voice.whisper_segments(items), items)
        # No added minimum word count or one-second duration gate.
        audio = np.ones(2400, np.float32) * 0.02  # 150 ms
        self.assertTrue(self.voice.careful_allowed(audio, 'так'))

    def test_no_speech_needs_both_scores_including_boundary(self):
        for probability, logprob, rejected in ((0.61, -1.01, True), (0.61, -1, True),
                                               (0.6, -2, False), (0.99, -0.99, False),
                                               (0.1, -2, False)):
            with self.subTest(probability=probability, logprob=logprob):
                item = segment('words', no_speech_prob=probability, avg_logprob=logprob)
                self.assertEqual(bool(self.voice.whisper_rejection(item)), rejected)
        self.assertIsNone(self.voice.whisper_rejection({'text': 'так', 'no_speech_prob': 0.99}))

    def test_word_token_and_compression_loops(self):
        cases = [(segment('And the Hidro S S S S S S S S'), 'word_loop'),
                 (segment('The, the THE the the.'), 'word_loop'),
                 (segment('так так так так так'), 'word_loop'),
                 (segment('unusual decoded text', tokens=[12] * 6), 'token_loop'),
                 (segment('repetitive window', compression_ratio=2.41), 'compression')]
        for item, reason in cases:
            self.assertEqual(self.voice.whisper_rejection(item), reason)
        self.assertIsNone(self.voice.whisper_rejection(segment('very very good')))
        self.assertIsNone(self.voice.whisper_rejection(segment('yes', tokens=[50364] * 9)))
        self.assertIsNone(self.voice.whisper_rejection(segment('yes', compression_ratio=2.4)))

    def test_long_real_speech_keeps_segments_times_and_repeated_topic_words(self):
        items = [segment(f'We discussed project {i}. The project needs another review tomorrow.',
                         start=i * 20, end=(i + 1) * 20) for i in range(180)]
        self.assertEqual(self.voice.whisper_segments(items), items)
        self.assertEqual(self.voice.whisper_segments([segment('yes')] * 10), [segment('yes')] * 10)

    def test_empty_and_missing_fields(self):
        self.assertEqual(self.voice.whisper_segments([]), [])
        self.assertEqual(self.voice.whisper_segments([{}, {'text': ' '}]), [])
        self.assertEqual(self.voice.whisper_segments([{'text': 'добре'}]), [{'text': 'добре'}])

    def test_careful_rebuilds_text_and_never_uses_unfiltered_top_level_text(self):
        self.whisper.transcribe.return_value = dict(text='THIS MUST NOT ESCAPE', segments=[
            segment('так'), segment('the the the the the'), segment('добре'),
            segment('noise', no_speech_prob=0.9, avg_logprob=-2)])
        audio = np.ones(16000, np.float32) * 0.02
        for model in ('fp16', 'q4', 'any/local/model'):
            self.voice.CAREFUL = model
            self.assertEqual(self.voice.Readers().careful(audio, fast_text='так добре'), 'так добре')
            self.assertEqual(self.whisper.transcribe.call_args.kwargs['path_or_hf_repo'], model)

    def test_no_whisper_for_silent_audio_or_known_empty_fast_result(self):
        quiet = np.zeros(16000, np.float32)
        loud = np.ones(16000, np.float32) * 0.2
        readers = self.voice.Readers()
        readers.drop = Mock()
        for audio, fast in ((quiet, None), (quiet, 'noise'), (loud, ''), (loud, '  ')):
            self.assertEqual(readers.careful(audio, fast_text=fast), fast or '')
            self.assertEqual(self.voice.careful(audio, fast_text=fast), fast or '')
        self.assertEqual(readers.read_file_whisper('/never/open', fast_text=''), [])
        readers.drop.assert_not_called()
        self.whisper.transcribe.assert_not_called()

    def test_file_uses_same_filter_preserves_offsets_and_language(self):
        self.whisper.transcribe.return_value = dict(text='unfiltered', segments=[
            segment('yes', start=0.1, end=0.3, no_speech_prob=0.9),
            segment('S S S S S'), segment('bad', compression_ratio=3)])
        pcm = np.concatenate([np.zeros(16000, np.int16), np.full(32000, 1000, np.int16)])
        with patch.object(self.voice, 'load_pcm16', return_value=pcm), \
                patch.object(self.voice, 'pieces', return_value=[(0, 16000), (16000, 32000), (32000, 48000)]):
            result = self.voice.Readers().read_file_whisper('fake.wav', lang='uk')
        self.assertEqual(result, [dict(start=1.1, end=1.3, text='yes'), dict(start=2.1, end=2.3, text='yes')])
        self.assertEqual(self.whisper.transcribe.call_count, 2)
        self.assertEqual(self.whisper.transcribe.call_args.kwargs['language'], 'uk')

    def test_file_all_silence_never_transcribes(self):
        with patch.object(self.voice, 'load_pcm16', return_value=np.zeros(16000, np.int16)):
            self.assertEqual(self.voice.Readers().read_file_whisper('fake.wav'), [])
        self.whisper.transcribe.assert_not_called()

    def test_pending_fast_text_follows_frame_branches_without_running_serve(self):
        # Execute only branch bodies, never serve(), its thread or stdin pump.
        tree = ast.parse((ROOT / 'engine/voice.py').read_text())
        serve = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'serve')
        branches = {ast.unparse(n.test): n.body for n in ast.walk(serve) if isinstance(n, ast.If)}
        audio = np.ones(16000, np.float32) * 0.02
        take = types.SimpleNamespace(text=lambda: '', loud=False, closed=[], audio=audio)
        readers = types.SimpleNamespace(careful=Mock(return_value=''), warm=Mock())
        state = dict(take=take, time=types.SimpleNamespace(perf_counter=lambda: 0), np=np,
                     emit=Mock(), FIRST=0.15, r=readers, names='', sys=sys)

        def branch(condition):
            exec(compile(ast.Module(body=branches[condition], type_ignores=[]), '<frame-branch>', 'exec'), state)

        branch('kind in (END, AGAIN)')
        self.assertEqual(state['pending_text'], '')
        branch('kind == CAREFUL_END')
        self.assertEqual(readers.careful.call_args.kwargs['fast_text'], '')
        self.assertIsNone(state['pending_text'])
        self.assertEqual(state['pending'], [])
        for condition in ('kind == DROP', 'kind == WARM'):
            state['pending_text'] = 'old words'
            branch(condition)
            self.assertIsNone(state['pending_text'])
        state.update(pending=[audio], pending_text='same audio fast words')
        readers.careful.side_effect = RuntimeError('synthetic reader failure')
        with contextlib.redirect_stderr(io.StringIO()):
            branch('kind == CAREFUL_END')
        self.assertEqual(state['emit'].call_args.args[0]['careful'], 'same audio fast words')
        self.assertIsNone(state['pending_text'])


class NoiseBench(unittest.TestCase):
    def setUp(self):
        self.bench = load('noise_bench', 'bench/voice_models.py')

    def test_noise_is_reproducible_pcm_and_exercises_energy_gate(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b, fake_voice() as (voice, _):
            left, right = self.bench.noise(Path(a)), self.bench.noise(Path(b))
            self.assertEqual(len(left), 4)
            flags = []
            for p, q in zip(left, right):
                self.assertEqual(p.read_bytes(), q.read_bytes())
                with wave.open(str(p)) as audio:
                    self.assertEqual((audio.getframerate(), audio.getnchannels(), audio.getsampwidth()), (16000, 1, 2))
                    self.assertGreaterEqual(audio.getnframes(), 2 * 16000)
                    self.assertLessEqual(audio.getnframes(), 10 * 16000)
                flags.append(voice.has_speech(voice.load_pcm16(str(p)).astype(np.float32) / 32768))
            self.assertEqual(flags, [False, False, True, True])

    def test_made_up_flags_include_blocked_and_current_noise_and_missing_baseline(self):
        base = dict(take='a', reader='careful', status='ok')
        rows = [dict(base, pair='current', text=''), dict(base, pair='q4', text='invented'),
                dict(base, pair='blocked', text='', guard_dropped=[{'reason': 'word_loop'}]),
                dict(base, pair='noise', take='noise', text='yes', expected_speech=False),
                dict(base, pair='error', take='missing', status='error')]
        self.bench.compare(rows)
        self.assertEqual([r['made_up'] for r in rows], [[], ['current empty'], ['blocked', 'word_loop'], ['noise text'], []])

    def test_noise_option_includes_speech_once_and_keeps_modes(self):
        for mode in ('take', 'file'):
            calls = []
            def pair(name, fast, careful, wav, mode, folder):
                calls.append((wav.name, mode))
                return [dict(pair=name, take=str(wav), reader=r, status='ok',
                             text='real speech' if wav.name == 'en.wav' else '') for r in ('fast', 'careful')]
            with patch.object(sys, 'argv', ['voice_models.py', '--noise', '--synthetic', '--mode', mode]), \
                    patch.object(sys, 'platform', 'darwin'), \
                    patch.object(self.bench, 'synthetic', side_effect=lambda p: [p / 'en.wav']) as speech, \
                    patch.object(self.bench, 'run_pair', side_effect=pair), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(self.bench.main(), 0)
                speech.assert_called_once()
            self.assertEqual(len(calls), 10)
            self.assertTrue(all(m == mode for _, m in calls))

    def test_worker_passes_fast_empty_and_audits_rejections_in_both_modes(self):
        for mode in ('take', 'file'):
            for fast_text in ('', 'yes'):
                with fake_voice() as (voice, whisper), tempfile.TemporaryDirectory() as folder:
                    readers = voice.Readers()
                    readers.warm = Mock(return_value='inert fast model')
                    readers.read_file_fast = Mock(return_value=[{'text': fast_text, 'start': 0, 'end': 1}] if fast_text else [])
                    whisper.transcribe.return_value = dict(text='raw', language='en', segments=[segment('yes'), segment('S S S S S')])
                    fake_take = types.SimpleNamespace(add=Mock(), text=lambda: fast_text)
                    with patch.dict(sys.modules, voice=voice), \
                            patch.object(voice, 'Readers', return_value=readers), \
                            patch.object(voice, 'Take', return_value=fake_take), \
                            patch.object(voice, 'load_pcm16', return_value=np.full(16000, 1000, np.int16)), \
                            contextlib.redirect_stdout(io.StringIO()) as output:
                        self.assertEqual(self.bench.worker('f', 'c', Path(folder) / 'fake.wav', mode, Path(folder)), 0)
                    rows = [json.loads(line) for line in output.getvalue().splitlines()]
                    result = rows[-1]
                    self.assertEqual(result['text'], fast_text)
                    self.assertEqual(result['guard_skipped'], not bool(fast_text))
                    self.assertEqual(whisper.transcribe.call_count, int(bool(fast_text)))
                    self.assertEqual([s['reason'] for s in result['guard_dropped']], ['word_loop'] if fast_text else [])
                    self.assertEqual(result['raw_careful_text'], 'yes S S S S S' if fast_text else '')
                    self.assertEqual(result['guarded_careful_text'], fast_text)
                    self.assertEqual(result['decoded_languages'], ['en'] if fast_text else [])


if __name__ == '__main__':
    unittest.main()
