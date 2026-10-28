from pathlib import Path
import subprocess
r=Path.cwd()
def edit(name,old,new):
 p=r/name;s=p.read_text();assert old in s,(name,old);p.write_text(s.replace(old,new))
edit('desktop/internal/bridge/agents_unified.go','\n\t"github.com/grimvirusoffical-source/red-xai-vortex/desktop/internal/keyring"','')
edit('desktop/internal/bridge/account_runtime.go','s.accounts.mu.Lock()\n\ts.accounts.epoch++','s.accounts.mu.Lock()\n\tdefer s.accounts.mu.Unlock()\n\ts.accounts.epoch++')
edit('desktop/internal/bridge/account_runtime.go','\ts.accounts.mu.Unlock()\n\tif old != nil {\n\t\told.closeAccountWorkspace()','\tif old != nil {\n\t\told.closeAccountWorkspace()')
edit('app/Sources/Vortex/WorkspaceHosting.swift','process.terminationHandler = { [weak self] ended in Task { @MainActor in','process.terminationHandler = { [weak self] ended in Task { @MainActor [weak self] in')
edit('app/Sources/Vortex/RoyalTheme.swift','{ [weak self] _ in Task { @MainActor in self?.update() } }','{ [weak self] _ in Task { @MainActor [weak self] in self?.update() } }')
edit('app/Sources/Vortex/WebBrowser.swift','Task { @MainActor in self?.port = l.port?.rawValue ?? 0 }','Task { @MainActor [weak self] in self?.port = l.port?.rawValue ?? 0 }')
edit('app/Sources/Vortex/Servers.swift','var all = ""\n                pipe.fileHandleForReading','let all = ReplyBuffer()\n                pipe.fileHandleForReading')
edit('app/Sources/Vortex/Servers.swift','                    all += t','                    all.append(t)')
edit('app/Sources/Vortex/Servers.swift','return (p.terminationStatus, all)','return (p.terminationStatus, all.text)')
edit('app/Sources/Vortex/Servers.swift','            await MainActor.run {\n                ServerStore.shared.installLog[s.id, default: ""] += msg','            let finalMessage = msg\n            await MainActor.run {\n                ServerStore.shared.installLog[s.id, default: ""] += finalMessage')
subprocess.run(['gofmt','-w','desktop/internal/bridge/agents_unified.go','desktop/internal/bridge/account_runtime.go'],check=True)
print('Native concurrency and serialized cleanup fixes applied; existing source and tests preserved.')
