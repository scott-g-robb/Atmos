#!/usr/bin/env python3
"""Reject non-distributable signatures before uploading anything to Apple."""
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(app)], check=True)
for architecture in ('arm64', 'x86_64'):
    info = subprocess.run(['codesign', '-dv', '--verbose=4', '--arch', architecture, str(app)],
                          check=True, capture_output=True, text=True).stderr
    if 'Authority=Developer ID Application:' not in info or 'Timestamp=' not in info or '(runtime)' not in info:
        raise SystemExit(f'{architecture}: Developer ID, hardened runtime and a secure timestamp are required.')
    data = subprocess.run(['codesign', '-d', '--entitlements', ':-', '--arch', architecture, str(app)],
                          check=True, capture_output=True).stdout
    entitlements = plistlib.loads(data)
    if entitlements.get('com.apple.security.get-task-allow'):
        raise SystemExit(f'{architecture}: a public release must not allow debugger attachment.')
print('Both architectures have timestamped Developer ID runtime signatures without debug entitlements.')
