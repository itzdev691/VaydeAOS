"""Offline packaged-helper smoke check; never uses the user's ChatGPT storage."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
helper = root / 'build/VaydeAOS.app/Contents/Resources/ChatGPT'
with tempfile.TemporaryDirectory(prefix='vaydeaos-chatgpt-smoke-') as directory:
    result = subprocess.run(
        [str(helper / 'node'), str(helper / 'helper.mjs'), directory],
        input=json.dumps({'id': 'offline-check', 'method': 'state'}) + '\n',
        text=True, capture_output=True, timeout=10,
        env={'PATH': '/usr/bin:/bin', 'HOME': directory, 'TMPDIR': tempfile.gettempdir()},
    )
    assert result.returncode == 0, 'Bundled helper failed to launch or stop'
    responses = [json.loads(line) for line in result.stdout.splitlines()]
    response = next(item for item in responses if item.get('id') == 'offline-check')
    assert response == {'id': 'offline-check', 'kind': 'result',
                        'session': {'status': 'disconnected', 'sharing': False}, 'profiles': []}
    assert result.stderr == '', 'Helper wrote diagnostics outside the protocol'
print('Bundled ChatGPT helper: offline state and clean EOF shutdown passed')
