#!/bin/zsh
# Create an uploadable source archive without build products or local credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import plistlib
import zipfile
from pathlib import Path

root = Path.cwd()
version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
destination = root / 'dist' / f'Atmos-{version}-source.zip'
destination.parent.mkdir(exist_ok=True)
entries = [
    '.github', '.gitignore', 'LICENSE', 'NOTICE.md', 'README.md', 'RELEASING.md',
    'Package.swift', 'Resources', 'Sources', 'Tests', 'docs', 'site', 'scripts',
    'weather-core', 'build.sh', 'install.command', 'make-installer.sh', 'release.sh', 'test.sh',
]
excluded = {'target', 'downloads', '.DS_Store', '__pycache__', '.env'}
private_suffixes = {'.p8', '.p12', '.pem', '.key', '.cer', '.mobileprovision', '.provisionprofile', '.log', '.pyc'}
with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for entry in entries:
        path = root / entry
        files = sorted(path.rglob('*')) if path.is_dir() else [path]
        for file in files:
            relative = file.relative_to(root)
            if any(part in excluded or part.startswith('.env.') for part in relative.parts):
                continue
            if file.is_file() and file.suffix not in private_suffixes and not file.is_symlink():
                archive.write(file, Path('Atmos') / relative)
print(destination)
PY
