import Foundation

/// Assembles fragmented OpenAI-compatible content and native tool calls. Tool
/// arguments remain private until the complete call has passed the normal gate.
struct ModelStreamAccumulator {
    var content = ""
    private var calls: [Int: [String: Any]] = [:]
    private var bytes = 0
    private(set) var finishReason: String?

    mutating func consume(_ event: [String: Any]) throws {
        if let error = event["error"] as? [String: Any] {
            throw NSError(domain: "Vortex", code: 502, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "The model stream failed."])
        }
        guard let choice = (event["choices"] as? [[String: Any]])?.first else { return }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty { finishReason = reason }
        let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
        if let value = delta["content"] as? String { content += value; bytes += value.utf8.count }
        for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let index = fragment["index"] as? Int ?? 0
            guard (0..<64).contains(index) else { throw Self.error("Too many model tool calls.") }
            var call = calls[index] ?? ["type": "function"]
            if let id = fragment["id"] as? String { call["id"] = id }
            var function = call["function"] as? [String: Any] ?? [:]
            if let f = fragment["function"] as? [String: Any] {
                for key in ["name", "arguments"] {
                    if let value = f[key] as? String {
                        function[key] = (function[key] as? String ?? "") + value
                        bytes += value.utf8.count
                    }
                }
            }
            call["function"] = function; calls[index] = call
        }
        guard bytes <= 2_097_152 else { throw Self.error("The model response exceeded the 2 MB limit.") }
    }
    var preview: String {
        let start = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard calls.isEmpty, !start.hasPrefix("<"), !start.hasPrefix("{"), !start.hasPrefix("```json"), !content.contains("<tool_call>") else { return "" }
        return content
    }
    var result: [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": content]
        if !calls.isEmpty { message["tool_calls"] = calls.keys.sorted().compactMap { calls[$0] } }
        return ["choices": [["message": message]]]
    }
    func completedResult(done: Bool) throws -> [String: Any] {
        guard done || finishReason != nil else { throw Self.error("The model stream ended before completion. No tool action was executed.") }
        if !calls.isEmpty, let reason = finishReason, !["tool_calls", "function_call", "stop"].contains(reason) {
            throw Self.error("The model tool call was interrupted (" + reason + "). No tool action was executed.")
        }
        return result
    }
    static func error(_ message: String) -> NSError { NSError(domain: "Vortex", code: 502, userInfo: [NSLocalizedDescriptionKey: message]) }
}
