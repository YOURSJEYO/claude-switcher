#!/usr/bin/env python3
"""Read-only comparison with the checksum-verified Linux payload on upstream main."""
import hashlib
import json
import io
import os
from pathlib import Path
import re
import sys
from urllib.request import Request, urlopen
import zipfile

REPO = 'YOURSJEYO/claude-switcher'
CONFIG = re.compile(rb'^(PROXY_MODE|PROXY_GROUP|TZ_TARGET|COUNTRY_TARGET|LOCALE_TARGET)="[^\n]*$', re.M)


def fetch(url, limit):
    request = Request(url, headers={'User-Agent': 'ClaudeSwitcher-Linux'})
    with urlopen(request, timeout=25) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError('上游响应超过大小限制')
    return data


def installed_files():
    ui = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'claude-switcher'
    base = Path.home() / '.claude-switcher'
    full = (base / 'claude-switch.sh').is_file()
    files = {f'linux/{name}': [ui / name] for name in ('monitor.py', 'monitor.css', 'update_check.py',
                                                         'claude-switch.sh', 'stun-probe.py')}
    files['core/claude-switch.sh'] = [ui / 'clash-support.sh']
    if full:
        for name in ('update_check.py', 'claude-switch.sh', 'stun-probe.py'):
            files['linux/' + name].append(base / name)
        files['core/claude-switch.sh'].append(base / 'clash-support.sh')
        files['linux/claude-bodyguard.sh'] = [base / 'claude-bodyguard.sh']
    return files


def normalize(name, data):
    if name == 'linux/claude-switch.sh':
        return CONFIG.sub(b'', data)
    if name == 'linux/claude-bodyguard.sh':
        return re.sub(rb'^MODE="[^"\n]*"$', b'MODE', data, flags=re.M)
    return data


def compare(archive, manifest, prefix, files):
    sums = dict((name, sha) for sha, name in re.findall(r'^([a-f0-9]{64})  (\S+)$', manifest, re.M))
    if not files.keys() <= sums.keys():
        raise ValueError('上游 main 缺少 Linux 工件校验项，无法判断更新')
    changed = []
    for name, paths in files.items():
        info = archive.getinfo(prefix + name)
        if info.file_size > 4 * 1024 * 1024:
            raise ValueError('上游工件大小异常')
        data = archive.read(info)
        if hashlib.sha256(data).hexdigest() != sums[name]:
            raise ValueError('上游工件 SHA256 校验失败')
        if any(not path.is_file() or normalize(name, path.read_bytes()) != normalize(name, data) for path in paths):
            changed.append(name)
    return changed


def main():
    ref = fetch(f'https://api.github.com/repos/{REPO}/git/ref/heads/main', 64 * 1024)
    sha = json.loads(ref)['object']['sha']
    if not re.fullmatch('[a-f0-9]{40}', sha):
        raise ValueError('上游提交号无效')
    manifest = fetch(f'https://raw.githubusercontent.com/{REPO}/{sha}/SHA256SUMS', 64 * 1024).decode()
    payload = fetch(f'https://codeload.github.com/{REPO}/zip/{sha}', 64 * 1024 * 1024)
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        changes = compare(archive, manifest, 'claude-switcher-' + sha + '/', installed_files())
    print(('本机与上游版本不同：' + '、'.join(changes) if changes else '已是最新版本') + f'（main {sha[:7]}）')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as exc:
        print('检查失败：' + str(exc))
        sys.exit(1)
