import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// A file attached to a chat message with the + button (or dropped on the chat).
/// Text, code and PDFs are sent as text context; images as OpenAI image_url parts (vision models).
struct Attachment: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var kind: String          // "text" | "image"
    var text: String? = nil   // extracted text (text/code/pdf)
    var dataURI: String? = nil // data:image/jpeg;base64,… (images, downscaled)
    var bytes: Int = 0
    var icon: String { kind == "image" ? "photo" : name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text" }
}

enum AttachmentLoader {
    static let maxChars = 120_000
    static let maxBytes = 25 << 20

    /// Read a file off the main thread. Throws a readable error for unsupported/huge files.
    static func load(_ url: URL) async throws -> Attachment {
        try await Task.detached(priority: .userInitiated) { try loadSync(url) }.value
    }

    static func loadSync(_ url: URL) throws -> Attachment {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxBytes { throw err("\(name) is larger than 25 MB.") }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .image) == true {
            guard let img = NSImage(contentsOf: url) else { throw err("Couldn't read image \(name).") }
            guard let jpg = jpeg(img, maxSide: 1536) else { throw err("Couldn't encode image \(name).") }
            return Attachment(name: name, kind: "image", dataURI: "data:image/jpeg;base64," + jpg.base64EncodedString(), bytes: size)
        }
        if type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw err("Couldn't open PDF \(name).") }
            var out = ""
            for i in 0..<doc.pageCount {
                if let s = doc.page(at: i)?.string { out += "\n--- page \(i + 1) ---\n" + s }
                if out.count > maxChars { break }
            }
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw err("\(name) has no extractable text (scanned PDF?).") }
            return Attachment(name: name, kind: "text", text: clip(out), bytes: size)
        }
        guard let d = try? Data(contentsOf: url) else { throw err("Couldn't read \(name).") }
        if d.prefix(8000).contains(0) { throw err("\(name) looks like a binary file. Attach text, code, PDF or images.") }
        let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        return Attachment(name: name, kind: "text", text: clip(s), bytes: size)
    }

    static func clip(_ s: String) -> String {
        s.count <= maxChars ? s : String(s.prefix(maxChars)) + "\n…[truncated at \(maxChars) characters]"
    }
    static func jpeg(_ img: NSImage, maxSide: CGFloat) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height), s = min(1, maxSide / max(w, h))
        let nw = Int(w * s), nh = Int(h * s)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
    static func err(_ m: String) -> NSError { NSError(domain: "Vortex", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }

    /// Fence language from the file extension so code keeps its highlighting hint.
    static func lang(_ name: String) -> String {
        let e = (name as NSString).pathExtension.lowercased()
        return ["py": "python", "js": "javascript", "ts": "typescript", "swift": "swift", "go": "go", "rs": "rust", "rb": "ruby",
                "java": "java", "kt": "kotlin", "c": "c", "h": "c", "cpp": "cpp", "cs": "csharp", "sh": "bash", "zsh": "bash",
                "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml", "md": "markdown", "html": "html", "css": "css",
                "sql": "sql", "php": "php", "xml": "xml", "csv": "csv"][e] ?? ""
    }
}

extension Message {
    /// Text sent to the model: attached text files as fenced context, then the user's message.
    var promptText: String {
        let files = (attachments ?? []).filter { $0.kind == "text" }
        guard !files.isEmpty else { return content }
        let ctx = files.map { "File: \($0.name)\n```\(AttachmentLoader.lang($0.name))\n\($0.text ?? "")\n```" }.joined(separator: "\n\n")
        return "Attached files (use them as context):\n\n" + ctx + "\n\n" + content
    }
    /// OpenAI chat "content": a string, or parts with image_url when images are attached.
    var apiContent: Any {
        let imgs = (attachments ?? []).filter { $0.kind == "image" }
        guard !imgs.isEmpty else { return promptText }
        var parts: [[String: Any]] = [["type": "text", "text": promptText.isEmpty ? "Describe the image." : promptText]]
        for a in imgs { if let u = a.dataURI { parts.append(["type": "image_url", "image_url": ["url": u]]) } }
        return parts
    }
    var promptChars: Int { promptText.count + (attachments ?? []).filter { $0.kind == "image" }.count * 3000 }
}

/// Chips for pending (removable) or sent attachments.
struct AttachmentChips: View {
    let items: [Attachment]
    var onRemove: ((Attachment) -> Void)? = nil
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { a in
                    HStack(spacing: 4) {
                        if a.kind == "image", let u = a.dataURI, let d = Data(base64Encoded: String(u.split(separator: ",").last ?? "")), let img = NSImage(data: d) {
                            Image(nsImage: img).resizable().scaledToFill().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
                        } else { Image(systemName: a.icon) }
                        Text(a.name).lineLimit(1).font(.caption)
                        if let onRemove { Button { onRemove(a) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))
                }
            }
        }
    }
}
