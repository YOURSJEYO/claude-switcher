import hashlib
import io
from pathlib import Path
import tempfile
import unittest
import zipfile

from linux.update_check import compare


class LinuxUpdateTests(unittest.TestCase):
    def test_verified_content_and_install_settings(self):
        path = 'linux/claude-switch.sh'
        data = b'PROXY_GROUP="GLOBAL"\necho ok\n'
        sums = hashlib.sha256(data).hexdigest() + '  ' + path
        with tempfile.TemporaryDirectory() as tmp, zipfile.ZipFile(io.BytesIO(), 'w') as archive:
            archive.writestr('repo/' + path, data)
            local = Path(tmp) / 'installed'
            files = {path: [local]}
            local.write_bytes(data.replace(b'GLOBAL', b'my group'))
            self.assertEqual(compare(archive, sums, 'repo/', files), [])
            local.write_bytes(b'echo old\n')
            self.assertEqual(compare(archive, sums, 'repo/', files), [path])
            with self.assertRaisesRegex(ValueError, 'SHA256'):
                compare(archive, '0' * 64 + '  ' + path, 'repo/', files)
            with self.assertRaisesRegex(ValueError, '缺少'):
                compare(archive, '', 'repo/', files)
