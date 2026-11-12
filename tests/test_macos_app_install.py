"""Exercise app placement in temporary directories, with signing/copy tools stubbed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'installer/install-app.sh'

class AppInstallation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'build/New App.app'
        self.source.mkdir(parents=True)
        (self.source / 'version').write_text('new')
        self.apps = self.root / 'Applications'
        self.apps.mkdir()
        self.target = self.apps / 'Claude切换器.app'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.stub('codesign', '#!/bin/bash\n[ "${BAD_SIGNATURE:-0}" != 1 ]\n')
        self.stub('ditto', '#!/bin/bash\ncp -R "$1" "$2"\n')
        self.stub('mv', '#!/bin/bash\nif [ "${FAIL_INSTALL:-0}" = 1 ] && [ "$(basename "$1")" = app ]; then exit 1; fi\n/bin/mv "$@"\n')
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'])

    def stub(self, name, content):
        p = self.bin / name
        p.write_text(content)
        p.chmod(0o755)

    def install(self, **env):
        return subprocess.run(['bash', str(HELPER), str(self.source), str(self.target)], env=dict(self.env, **env), capture_output=True, text=True)

    def old_app(self):
        self.target.mkdir()
        (self.target / 'version').write_text('old')

    def test_first_install(self):
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.target / 'version').read_text(), 'new')

    def test_reinstall_preserves_previous(self):
        self.old_app()
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stderr)
        backups = list(self.apps.glob('.claude-switcher-install.*/previous-app/version'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), 'old')
        self.assertEqual((self.target / 'version').read_text(), 'new')

    def test_bad_signature_keeps_old_app(self):
        self.old_app()
        self.assertNotEqual(self.install(BAD_SIGNATURE='1').returncode, 0)
        self.assertEqual((self.target / 'version').read_text(), 'old')

    def test_failed_replacement_restores_old_app(self):
        self.old_app()
        self.assertNotEqual(self.install(FAIL_INSTALL='1').returncode, 0)
        self.assertEqual((self.target / 'version').read_text(), 'old')

    def test_symlink_target_is_rejected(self):
        self.target.symlink_to(self.source)
        self.assertNotEqual(self.install().returncode, 0)
        self.assertTrue(self.target.is_symlink())
