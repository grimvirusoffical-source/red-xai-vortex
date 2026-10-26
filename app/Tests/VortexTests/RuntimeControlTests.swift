import XCTest
@testable import Vortex

final class RuntimeControlTests: XCTestCase {
    func testAlwaysAllowCoversOnlyEnabledLocalPCTools() {
        func asks(_ source: String, _ allowed: Bool = true, _ enabled: Bool = true, _ killed: Bool = false, _ kind: Bool = true) -> Bool {
            PCApprovalPolicy.needsApproval(source: source, destructive: true, alwaysAllow: allowed, enabled: enabled, killed: killed, kindEnabled: kind)
        }
        XCTAssertFalse(asks("pc:shell"))
        XCTAssertTrue(asks("pc:shell", false)); XCTAssertTrue(asks("pc:shell", true, false))
        XCTAssertTrue(asks("pc:shell", true, true, true)); XCTAssertTrue(asks("pc:shell", true, true, false, false))
        XCTAssertTrue(asks("plugin:example")); XCTAssertTrue(asks("mcp:example"))
    }
    func testRememberedPermissionDefaultsToOffAndRevocationDeletesGrant() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let grant = folder.appendingPathComponent("grant")
        XCTAssertFalse(PCAlwaysAllowGrant.present(at: grant))
        try PCAlwaysAllowGrant.set(true, at: grant); XCTAssertTrue(PCAlwaysAllowGrant.present(at: grant))
        try PCAlwaysAllowGrant.set(false, at: grant); XCTAssertFalse(PCAlwaysAllowGrant.present(at: grant))
        try PCAlwaysAllowGrant.set(false, at: grant)
        let target = folder.appendingPathComponent("target")
        try Data("fixture".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: grant, withDestinationURL: target)
        XCTAssertFalse(PCAlwaysAllowGrant.present(at: grant), "Grant symlinks must never authorize control")
        try PCAlwaysAllowGrant.set(false, at: grant)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "Revocation removes only the symlink")
    }
    func testStopRevokesRunningAndQueuedTokensEvenAfterReset() throws {
        let state = PCExecutionState(), token = try state.issue()
        var cancelled = 0
        _ = try state.register(token) { cancelled += 1 }
        state.revoke(stopped: true)
        XCTAssertEqual(cancelled, 1); XCTAssertThrowsError(try state.issue())
        state.resume()
        XCTAssertThrowsError(try state.check(token)); XCTAssertThrowsError(try state.register(token) {})
        XCTAssertNoThrow(try state.check(state.issue()))
    }
    func testStopKillsShellDescendantsAndPreventsTheirLaterWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ready = folder.appendingPathComponent("ready"), escaped = folder.appendingPathComponent("should-not-exist")
        let state = PCExecutionState(), token = try state.issue()
        let command = "(sleep 0.8; echo escaped > \"$2\") & echo ready > \"$1\"; wait"
        let task = Task { try await PCCancellableProcess().run("/bin/sh", ["-c", command, "fixture", ready.path, escaped.path], timeout: 10, token: token, state: state) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let start = Date(); state.revoke(stopped: true)
        do { _ = try await task.value; XCTFail("Stopped command must not report success") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }
    func testCommandTimeoutWorksWhenChildClosesOutputAndBoundsOutput() async throws {
        let state = PCExecutionState()
        let start = Date()
        let result = try await PCCancellableProcess().run("/bin/sh", ["-c", "exec 1>&- 2>&-; sleep 10"], timeout: 0.2, token: try state.issue(), state: state)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5); XCTAssertTrue(result.contains("stopped after"))
        let bounded = try await PCCancellableProcess().run("/usr/bin/yes", ["fixture"], timeout: 3, token: try state.issue(), state: state)
        XCTAssertLessThan(bounded.utf8.count, 21_000); XCTAssertTrue(bounded.contains("output limit"))
    }
    func testFragmentedNativeToolCallsStayHiddenAndAssembleExactly() throws {
        var accumulator = ModelStreamAccumulator()
        try accumulator.consume(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "pc_", "arguments": "{\"command\":"]]]]]]])
        try accumulator.consume(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["name": "shell", "arguments": "\"echo ok\"}"]]]]]]])
        XCTAssertEqual(accumulator.preview, "")
        let message = try XCTUnwrap((accumulator.result["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        let call = try XCTUnwrap((message["tool_calls"] as? [[String: Any]])?.first)
        let function = try XCTUnwrap(call["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "pc_shell"); XCTAssertEqual(function["arguments"] as? String, #"{"command":"echo ok"}"#)
    }
    func testTextStreamsProgressivelyAndFallbackToolTagsAreHidden() throws {
        var accumulator = ModelStreamAccumulator()
        try accumulator.consume(["choices": [["delta": ["content": "Hello"]]]])
        XCTAssertEqual(accumulator.preview, "Hello")
        try accumulator.consume(["choices": [["delta": ["content": " world"]]]])
        XCTAssertEqual(accumulator.preview, "Hello world")
        var hidden = ModelStreamAccumulator()
        try hidden.consume(["choices": [["delta": ["content": "<tool_call>{\"name\":\"pc_shell\"}"]]]])
        XCTAssertEqual(hidden.preview, "")
        XCTAssertThrowsError(try hidden.consume(["error": ["message": "stream failed"]]))
    }
    func testNaturalMediaRequestsUseGenerationButQuestionsDoNot() {
        XCTAssertEqual(MediaSpec.parseRequest("Please generate an image of a golden fox")?.prompt, "a golden fox")
        XCTAssertEqual(MediaSpec.parseRequest("Create a video showing clouds moving")?.type, "video")
        XCTAssertEqual(MediaSpec.parseRequest("Make me music for a quiet night")?.type, "music")
        XCTAssertEqual(MediaSpec.parseRequest("Generate a sound effect of rain")?.type, "sfx")
        XCTAssertEqual(MediaSpec.parseRequest("Create speech saying hello there")?.type, "speech")
        XCTAssertEqual(MediaSpec.parseRequest("Generate an image of a fox --size 768x512")?.size, "768x512")
        XCTAssertNil(MediaSpec.parseRequest("How do I generate an image?"))
        XCTAssertNil(MediaSpec.parseRequest("Write code to create an image"))
        XCTAssertNil(MediaSpec.parseRequest("Do not generate an image of a fox"))
        XCTAssertNil(MediaSpec.parseRequest("Generate an image prompt for a golden fox"))
        XCTAssertNil(MediaSpec.parseRequest("Create an image editor in JavaScript"))
        XCTAssertNil(MediaSpec.parseRequest("Make a music player for my app"))
        XCTAssertNil(MediaSpec.parseRequest("Create a video generation script in Python"))
        XCTAssertEqual(MediaSpec.parseRequest("Generate an image of a music player on a desk")?.type, "image")
        XCTAssertNil(MediaSpec.parseRequest("Create an image    editor in JavaScript"))
        XCTAssertEqual(MediaSpec.parseRequest("Create an image of prompt cards on a table")?.type, "image")
        XCTAssertEqual(MediaSpec.parseRequest("/image editor interface")?.type, "image")
    }
    func testComputerIntentDoesNotActOnQuestionsNegationOrMultiStepRequests() {
        XCTAssertNil(Intent.guess("How do I open Safari?"))
        XCTAssertNil(Intent.guess("Do not open Safari"))
        XCTAssertNil(Intent.guess("Please don't close Safari"))
        XCTAssertNil(Intent.guess("Please don't open Safari"))
        XCTAssertNil(Intent.guess("Could you please never open Safari"))
        XCTAssertNil(Intent.guess("Could you explain why I should open Safari"))
        XCTAssertNil(Intent.guess("The instructions say open Safari"))
        XCTAssertNil(Intent.guess("What does screenshot mean?"))
        XCTAssertNil(Intent.guess("Open Safari and then type hello"))
        XCTAssertEqual(Intent.guess("Open Safari")?.name, "pc_open_app")
        XCTAssertEqual(Intent.guess("what's on my screen?")?.name, "pc_screenshot")
    }
    func testStoppedGrantCannotReturnAfterRestartOrReset() {
        XCTAssertFalse(PCAlwaysAllowGrant.allowed(killed: true, grantPresent: true))
        XCTAssertFalse(PCAlwaysAllowGrant.allowed(killed: false, grantPresent: false))
        XCTAssertTrue(PCAlwaysAllowGrant.allowed(killed: false, grantPresent: true))
    }
    func testCancelledReplyLeaseCannotWriteIntoNewTurn() {
        var lease = ChatGenerationLease()
        let stopped = lease.begin()
        XCTAssertTrue(lease.accepts(stopped))
        lease.invalidate()
        XCTAssertFalse(lease.accepts(stopped))
        let current = lease.begin()
        XCTAssertFalse(lease.accepts(stopped))
        XCTAssertTrue(lease.accepts(current))
        lease.invalidate()
        XCTAssertFalse(lease.accepts(current))
    }
    func testIncompleteStreamsAndMalformedToolArgumentsCannotExecute() throws {
        var stream = ModelStreamAccumulator()
        let function: [String: Any] = ["name": "pc_clipboard_write", "arguments": "{\"text\":"]
        let fragment: [String: Any] = ["index": 0, "id": "c1", "function": function]
        let delta: [String: Any] = ["tool_calls": [fragment]]
        try stream.consume(["choices": [["delta": delta]]])
        XCTAssertThrowsError(try stream.completedResult(done: false))
        XCTAssertThrowsError(try Agent.validatedArguments("{\"text\":"))
        XCTAssertThrowsError(try Agent.validatedArguments("[]"))
        let required: [String: Any] = ["required": ["text"], "properties": ["text": ["type": "string"]]]
        XCTAssertThrowsError(try Agent.validatedArguments([:], schema: required))
        XCTAssertThrowsError(try Agent.validatedArguments(["text": 42], schema: required))
        XCTAssertEqual(try Agent.validatedArguments(["text": "safe"], schema: required)["text"] as? String, "safe")
        XCTAssertNil(Agent.parseFallback(#"<tool_call>{"name":"pc_clipboard_write","arguments":"{"}</tool_call>"#, names: ["pc_clipboard_write"]))
        try stream.consume(["choices": [["delta": [:], "finish_reason": "length"]]])
        XCTAssertThrowsError(try stream.completedResult(done: true))
        var complete = ModelStreamAccumulator()
        try complete.consume(["choices": [["delta": ["content": "Done"], "finish_reason": "stop"]]])
        XCTAssertNoThrow(try complete.completedResult(done: false))
        XCTAssertNoThrow(try complete.completedResult(done: true))
    }
    func testSuccessfulBackgroundLaunchReturnsPromptlyAndRemainsRevocable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let survived = folder.appendingPathComponent("survived"), escaped = folder.appendingPathComponent("should-not-exist")
        let state = PCExecutionState(), token = try state.issue()
        let command = "(sleep 0.3; echo alive > \"$1\"; sleep 0.6; echo escaped > \"$2\") & echo launched"
        let start = Date()
        let result = try await PCCancellableProcess().run("/bin/sh", ["-c", command, "fixture", survived.path, escaped.path], timeout: 0.2, token: token, state: state)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6)
        XCTAssertTrue(result.contains("launched"))
        XCTAssertFalse(result.contains("stopped after"))
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: survived.path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: survived.path), "Background child must survive a successful parent exit")
        state.revoke(stopped: true)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path), "Stop must still cancel the registered background group")
    }

    func testProviderWithoutNativeToolsCanUseExistingTextProtocol() {
        XCTAssertTrue(Agent.shouldRetryTextTools(NSError(domain: "Vortex", code: 400, userInfo: [NSLocalizedDescriptionKey: "This model does not support tools"])))
        XCTAssertTrue(Agent.shouldRetryTextTools(NSError(domain: "Vortex", code: 422, userInfo: [NSLocalizedDescriptionKey: "function_call is unsupported"])))
        XCTAssertFalse(Agent.shouldRetryTextTools(NSError(domain: "Vortex", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid tool key"])))
        XCTAssertFalse(Agent.shouldRetryTextTools(NSError(domain: "Vortex", code: 400, userInfo: [NSLocalizedDescriptionKey: "Unknown model"])))
    }

}
