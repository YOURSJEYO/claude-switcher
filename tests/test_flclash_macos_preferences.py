"""macOS CFPreferences and quoted fake-IP regressions; never reads real preferences."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

class MacPreferences(unittest.TestCase):
    def setUp(self):
        source = (ROOT / 'core/claude-switch.sh').read_text()
        code = source[source.index('def current_profile(home):'):source.index('\n\ndef repair(home, configured):')]
        def fail(message):
            raise ValueError(message)
        self.ns = {'Path': Path, 'json': json, 'fail': fail}
        exec(code, self.ns)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.config = self.home / 'Library/Application Support/com.follow.clash'
        self.config.mkdir(parents=True)
        self.expression = re.search(r'if not re.search\(r"(.+?)", config, re.I\)', source).group(1)

    def test_macos_current_profile(self):
        result = subprocess.CompletedProcess([], 0, json.dumps({'currentProfileId': 123}), '')
        with patch.object(Path, 'home', return_value=self.home), patch('subprocess.run', return_value=result) as run:
            self.assertEqual(self.ns['current_profile'](self.config), 123)
            self.assertEqual(run.call_args.args[0], ['/usr/bin/defaults', 'read', 'com.follow.clash', 'flutter.config'])

    def test_defaults_failure_is_reported_without_traceback(self):
        for error in [subprocess.TimeoutExpired('defaults', 5), subprocess.CalledProcessError(1, 'defaults')]:
            with self.subTest(error=type(error).__name__), patch.object(Path, 'home', return_value=self.home), patch('subprocess.run', side_effect=error):
                with self.assertRaisesRegex(ValueError, '无法读取当前 Profile'):
                    self.ns['current_profile'](self.config)

    def test_invalid_profile_is_rejected(self):
        for value in [None, True, 0, '123']:
            result = subprocess.CompletedProcess([], 0, json.dumps({'currentProfileId': value}), '')
            with self.subTest(value=value), patch.object(Path, 'home', return_value=self.home), patch('subprocess.run', return_value=result):
                with self.assertRaisesRegex(ValueError, '当前 Profile'):
                    self.ns['current_profile'](self.config)

    def test_quoted_fake_ip(self):
        for value in ['fake-ip', '"fake-ip"', "'fake-ip'"]:
            self.assertIsNotNone(re.search(self.expression, '  enhanced-mode: ' + value, re.I))
        self.assertIsNone(re.search(self.expression, 'enhanced-mode: "redir-host"', re.I))
