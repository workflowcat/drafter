"""Compile only the real Settings value type; never compile or start the app."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SettingsRoundTrip(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_voice_choices_survive_app_settings_round_trip(self):
        source = (ROOT / 'app/Main.swift').read_text()
        settings = source.split('struct Settings: Codable {', 1)[1].split('// MARK: engine process', 1)[0]
        settings = 'struct Settings: Codable {' + settings
        with tempfile.TemporaryDirectory(prefix='drafter-settings-test-') as folder:
            path = Path(folder)
            program = ('import Foundation\n'
                       'enum LocalConfig { static let skipApps: [String] = [] }\n'
                       'enum QuickRules { static let defaultKey = "k"; static let defaultSecrets: [String] = [] }; enum Home { static let bundleID = "drafter.test"; static let settings = URL(fileURLWithPath: ' +
                       json.dumps(str(path / 'settings.json')) + ') }\n' + settings + r'''
let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
precondition(old.voiceFast == nil && old.voiceCareful == nil)
let input = Data(#"{"voiceFast":"~/models/fast","voiceCareful":"repo/q4","voice":true}"#.utf8)
var choices = try JSONDecoder().decode(Settings.self, from: input)
choices.paused = true
choices.save()
let saved = Settings.load()
precondition(saved.voiceFast == "~/models/fast" && saved.voiceCareful == "repo/q4")
precondition(saved.voice && saved.paused)
let invalid = Data(#"{"voiceFast":false,"voiceCareful":[],"voice":true}"#.utf8)
let fallback = try JSONDecoder().decode(Settings.self, from: invalid)
precondition(fallback.voiceFast == nil && fallback.voiceCareful == nil && fallback.voice)
print("PASS Settings defaults, save/load, malformed model values")
''')
            (path / 'main.swift').write_text(program)
            subprocess.run(['swiftc', '-module-cache-path', str(path / 'cache'), str(path / 'main.swift'),
                            '-o', str(path / 'check')], check=True, capture_output=True, timeout=60)
            result = subprocess.run([str(path / 'check')], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn('PASS Settings', result.stdout)


if __name__ == '__main__':
    unittest.main()
