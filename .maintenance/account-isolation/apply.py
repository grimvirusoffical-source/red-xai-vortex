"""Apply the reviewed, hash-verified source repair on its isolated feature branch.
Temporary transfer parts are removed by the workflow after normal source is committed.
No credentials, settings, user files, or production services are touched.
"""
from pathlib import Path
import hashlib, lzma, re, subprocess
root = Path.cwd()
parts = root / '.maintenance/account-isolation'
patch = lzma.decompress(b''.join((parts / f'part-{i}.xz').read_bytes() for i in range(1, 5)))
assert hashlib.sha256(patch).hexdigest() == 'b0e3c5094551f2bf7c5d5710ff0557fa1daa35b275351b9ab46a690796e94515', 'Transfer checksum mismatch'
assert not (root / 'app/Sources/Vortex/AccountProfile.swift').exists(), 'Repair already applied; do not overwrite'
for p in (root / 'app/Sources/Vortex').glob('*.swift'):
    s = p.read_text().replace('UserDefaults.standard', 'AccountProfile.defaults')
    s = re.sub(r'@AppStorage\(("[^"\n]+")\)', r'@AppStorage(\1, store: AccountProfile.defaults)', s)
    p.write_text(s)
files = ['desktop/internal/bridge/account_isolation_test.go', 'desktop/internal/bridge/account_runtime.go', 'desktop/internal/bridge/agents_unified.go', 'desktop/internal/bridge/bridge.go', 'desktop/internal/bridge/link.go', 'desktop/internal/bridge/media.go', 'desktop/internal/bridge/phone.go', 'desktop/internal/bridge/plugins.go', 'desktop/internal/bridge/redx.go', 'desktop/internal/bridge/redx_alternative_auth_test.go', 'desktop/internal/bridge/redx_quick.go', 'desktop/internal/bridge/redx_switch.go', 'desktop/internal/bridge/redx_switch_test.go', 'desktop/internal/bridge/runs.go', 'desktop/internal/bridge/workspace.go', 'desktop/internal/bridge/workspace_hosting.go', 'desktop/internal/bridge/workspace_ingestion.go', 'desktop/internal/bridge/workspace_remote.go', 'desktop/internal/keyring/keyring.go', 'desktop/internal/keyring/keyring_test.go']
for name in files:
    if (root / name).exists(): subprocess.run(['gofmt', '-w', name], check=True)
subprocess.run(['git', 'apply', '--check', '-'], input=patch, check=True)
subprocess.run(['git', 'apply', '-'], input=patch, check=True)
print('Account-scoped source, MCP authentication, scrolling and regression tests applied.')
