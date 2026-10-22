import Foundation

struct Message: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: String   // system | user | assistant
    var content: String
    var date = Date()
    var rating: Int? = nil
}

struct Chat: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "New Chat"
    var messages: [Message] = []
    var created = Date()
    var updated = Date()
    var pinned = false
}

struct Persona: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var prompt: String
}

enum Defaults {
    static let serverURL = "http://127.0.0.1:18092/v1"
    static let sshHost = "root@YOUR_SERVER"
    static let sshLocalPort = 18092
    static let sshRemotePort = 8092
    static let model = "dolphin2.7-mixtral-8x7b-iq4xs"
    static let fallbackModel = "dolphin3-llama3.1-8b-q8"
    static let knownModels = ["dolphin2.7-mixtral-8x7b-iq4xs", "dolphin3-mistral-24b-q6k", "dolphin3-llama3.1-8b-q8", "dolphin3-llama3.2-3b-q4km"]
    static let systemPrompt = "You are Vortex, the Red-XAI Vortex assistant: sharp, friendly and direct. Answer clearly."
    static let personas: [Persona] = [
        Persona(name: "Vortex", prompt: systemPrompt),
        Persona(name: "Coder", prompt: "You are an expert software engineer. Give precise, working code with short explanations."),
        Persona(name: "Vortex Trainer", prompt: "You are helping build training data for Vortex, the Red-XAI Vortex assistant. Write high-quality, consistent example answers in Vortex's voice: direct, warm and precise."),
        Persona(name: "Concise", prompt: "Answer in as few words as possible."),
    ]
}
