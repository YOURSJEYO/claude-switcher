"""Route vendor desktop actions through the selected account; preserve user overrides."""
import os
from pathlib import Path
import sys
import tempfile


def install(apps, launcher, vendor):
    entry = apps / vendor.name
    target = entry if entry.exists() else vendor
    if not target.exists() or entry.is_symlink():
        return
    text = target.read_text()
    if target == entry and 'X-Claude-Generated=true' not in text.splitlines():
        return
    if 'Exec=claude-desktop %U' not in text.splitlines():
        return
    if entry.exists():
        backup = entry.with_suffix('.desktop.pre-switcher')
        if not backup.exists():
            backup.write_text(text)
    # Escape the two levels of the desktop file Exec field.
    path = str(launcher).replace('%', '%%')
    for char in ('\\', '"', '`', '$'):
        path = path.replace(char, '\\' + char)
    command = '"' + path.replace('\\', '\\\\') + '"'
    lines = [line.replace('Exec=claude-desktop ', 'Exec=' + command + ' ', 1)
             if line.startswith('Exec=claude-desktop ') else line for line in text.splitlines()
             if line != 'X-Claude-Generated=true']
    lines.insert(lines.index('[Desktop Entry]') + 1, 'X-Claude-Switcher=true')
    with tempfile.NamedTemporaryFile(dir=apps, mode='w', delete=False) as handle:
        handle.write('\n'.join(lines) + '\n')
    os.replace(handle.name, entry)


if __name__ == '__main__':
    install(Path(sys.argv[1]), Path(sys.argv[2]), Path('/usr/share/applications/com.anthropic.Claude.desktop'))
