#!/usr/bin/env python3
"""Bundle the locked official Codex native package, including rg and license notices."""
import base64
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import tarfile
import urllib.request

root = pathlib.Path(__file__).resolve().parent.parent
lock = json.loads((root / 'scripts/codex-runtime-lock.json').read_text())
arch = {'arm64': 'arm64', 'x86_64': 'x64'}[platform.machine()]
spec = lock['platforms'][arch]
cache = root / 'build/codex-runtime'
cache.mkdir(parents=True, exist_ok=True)
archive = cache / f"codex-{lock['version']}-{arch}.tgz"

def valid():
    return archive.exists() and base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode() == spec['integrity'].removeprefix('sha512-')

if not valid():
    with urllib.request.urlopen(spec['url'], timeout=120) as response:
        data = response.read()
    if 'sha512-' + base64.b64encode(hashlib.sha512(data).digest()).decode() != spec['integrity']:
        raise SystemExit('Codex archive checksum mismatch')
    archive.write_bytes(data)

extracted = cache / f"{lock['version']}-{arch}"
if extracted.exists():
    shutil.rmtree(extracted)
extracted.mkdir()
with tarfile.open(archive) as package:
    # The integrity-checked archive is still subject to path and link validation.
    for member in package.getmembers():
        if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
            raise SystemExit('Unexpected Codex archive member')
        destination = (extracted / member.name).resolve()
        if not destination.is_relative_to(extracted.resolve()):
            raise SystemExit('Unsafe Codex archive path')
    package.extractall(extracted)
package = extracted / 'package'
binaries = list(package.glob('vendor/*/bin/codex'))
if len(binaries) != 1:
    raise SystemExit('Expected exactly one Codex executable')
binary = binaries[0]
output = root / 'build/VaydeAOS.app/Contents/Resources/Codex'
if output.exists():
    shutil.rmtree(output)
output.mkdir(parents=True)
shutil.copytree(binary.parent.parent, output, dirs_exist_ok=True)
for name in ['LICENSE', 'NOTICE', 'README.md', 'package.json']:
    if (package / name).exists():
        shutil.copy2(package / name, output / name)
for name in ['LICENSE', 'NOTICE']:
    shutil.copy2(root / 'Resources/Codex' / name, output / name)
(output / 'runtime-version.txt').write_text(lock['version'] + '\n')
# Nested executables must be signed before the outer app bundle.
for path in output.rglob('*'):
    if path.is_file() and (os.access(path, os.X_OK) or path.suffix == '.dylib'):
        subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True)
subprocess.run([str(output / 'bin/codex'), '--version'], check=True)
