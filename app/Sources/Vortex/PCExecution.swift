import Foundation
import Darwin

/// A stopped run stays revoked after the user resets the switch. The generation
/// belongs to the local execution session, never to model-supplied arguments.
final class PCExecutionState: @unchecked Sendable {
    static let shared = PCExecutionState(stopped: UserDefaults.standard.bool(forKey: "pc.killed"))
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var stopped: Bool
    private var cancellations: [UUID: () -> Void] = [:]

    init(stopped: Bool = false) { self.stopped = stopped }
    func issue() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        return generation
    }
    func check(_ token: UInt64?) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, token == nil || token == generation else { throw CancellationError() }
    }
    func register(_ token: UInt64, cancel: @escaping () -> Void) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, token == generation else { throw CancellationError() }
        let id = UUID(); cancellations[id] = cancel; return id
    }
    func remove(_ id: UUID) { lock.lock(); cancellations.removeValue(forKey: id); lock.unlock() }
    func revoke(stopped: Bool) {
        lock.lock(); generation &+= 1; self.stopped = stopped
        let pending = Array(cancellations.values); cancellations.removeAll(); lock.unlock()
        pending.forEach { $0() }
    }
    func resume() { revoke(stopped: false) }
}

enum PCExecutionContext {
    @TaskLocal static var token: UInt64?
    static func check() throws {
        try Task.checkCancellation()
        try PCExecutionState.shared.check(token)
    }
}

enum PCApprovalPolicy {
    static func needsApproval(source: String, destructive: Bool, alwaysAllow: Bool,
                              enabled: Bool, killed: Bool, kindEnabled: Bool) -> Bool {
        destructive && !(source.hasPrefix("pc:") && alwaysAllow && enabled && !killed && kindEnabled)
    }
}

/// The shell and every descendant inherit a private process group. Stop kills
/// that group, including commands that fork, rather than only the parent shell.
final class PCCancellableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true
        if pid > 0 { Darwin.kill(-pid, SIGKILL) }
        lock.unlock()
    }
    private func attach(_ value: pid_t) {
        lock.lock(); pid = value
        if cancelled { Darwin.kill(-value, SIGKILL) }
        lock.unlock()
    }
    private func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    private func finish() { lock.lock(); pid = 0; lock.unlock() }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
             token: UInt64?, state: PCExecutionState = .shared) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.execute(executable, arguments, timeout: timeout, token: token, state: state)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    private func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                         token: UInt64?, state: PCExecutionState) throws -> String {
        try check(); try state.check(token)
        let permit = try token ?? state.issue()
        let registration = try state.register(permit) { self.cancel() }
        var background = false
        defer { if !background { state.remove(registration); finish() } }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        let readFD = descriptors[0], writeFD = descriptors[1]
        defer { if !background { close(readFD) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        var child: pid_t = 0
        let code = posix_spawn(&child, executable, &actions, &attributes, &argv, &environment)
        close(writeFD)
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        attach(child)
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data(), total = 0, status: Int32 = 0
        var reaped = false, ended = false, limited = false, timedOut = false
        var chunk = [UInt8](repeating: 0, count: 4096)
        defer {
            if !reaped {
                Darwin.kill(-child, SIGKILL)
                while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            }
        }
        while !(ended && reaped) {
            do { try check(); try state.check(permit) } catch { cancel(); throw error }
            if Date() >= deadline { timedOut = true; cancel(); break }
            var descriptor = pollfd(fd: ended ? -1 : readFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&descriptor, 1, 50)
            while !ended {
                let count = read(readFD, &chunk, chunk.count)
                if count == 0 { ended = true; break }
                if count < 0 { if errno == EINTR { continue }; break }
                total += count
                if output.count < 20_000 { output.append(contentsOf: chunk.prefix(min(count, 20_000 - output.count))) }
                if total > 1_048_576 { limited = true; cancel(); ended = true; break }
            }
            if limited { break }
            if !reaped { reaped = waitpid(child, &status, WNOHANG) == child }
            if reaped {
                // Parent completion is the command result. A deliberately launched
                // service may retain the pipe; it must not turn success into a timeout.
                break
            }
        }
        if !reaped { while waitpid(child, &status, 0) == -1 && errno == EINTR {}; reaped = true }
        if !timedOut && !limited { try check(); try state.check(permit) }
        var result = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut { result += "\n(stopped after \(Int(timeout)) seconds)" }
        else if limited { result += "\n(stopped: command exceeded the 1 MB output limit)" }
        else if status != 0 { result += "\n(exit \((status >> 8) & 0xff), signal \(status & 0x7f))" }
        if total > output.count { result += "\n…[output truncated]" }
        if !timedOut && !limited && Darwin.kill(-child, 0) == 0 {
            background = true
            monitorBackground(readFD: readFD, registration: registration, token: permit, state: state)
            result += "\n(Background process running; Stop control will stop its process group.)"
        }
        return result
    }

    private func monitorBackground(readFD: Int32, registration: UUID, token: UInt64, state: PCExecutionState) {
        DispatchQueue.global(qos: .utility).async {
            defer { close(readFD); state.remove(registration); self.finish() }
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                do { try self.check(); try state.check(token) } catch { self.cancel(); return }
                self.lock.lock(); let group = self.pid; self.lock.unlock()
                guard group > 0, Darwin.kill(-group, 0) == 0 else { return }
                var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 100)
                // Bound each drain cycle so a noisy process cannot delay Stop.
                for _ in 0..<256 {
                    if read(readFD, &chunk, chunk.count) <= 0 { break }
                }
                if descriptor.revents & Int16(POLLHUP) != 0 { Thread.sleep(forTimeInterval: 0.1) }
            }
        }
    }
}


/// The remembered grant is a private local file. Revocation unlinks it so a full
/// disk cannot require allocating a replacement preferences file to disarm it.
enum PCAlwaysAllowGrant {
    static var url: URL { PCControl.baseDir.appendingPathComponent(".pc-always-allow") }
    static func allowed(killed: Bool, grantPresent: Bool) -> Bool { !killed && grantPresent }
    static func present(at url: URL = Self.url) -> Bool {
        // URL resource values can cache a previously existing grant after unlink.
        // Read the current inode directly, and never follow a grant symlink.
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }
    static func set(_ enabled: Bool, at url: URL = Self.url) throws {
        if enabled {
            try Data("Local PC tools explicitly allowed by the user.\n".utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
