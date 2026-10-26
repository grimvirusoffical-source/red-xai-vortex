import Foundation
import Vision
import ImageIO
import AVFoundation
import Speech
import PDFKit
import Darwin

struct NativeIngestionResult { var text: String; var detail: String }
enum NativeWorkspaceIngestion {
    static func imageText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .fast; request.usesLanguageCorrection = false
        request.revision = VNRecognizeTextRequestRevision2; request.recognitionLanguages = ["en-US"]
        do { try VNImageRequestHandler(cgImage: image).perform([request]) }
        catch { throw NSError(domain: "VortexIngestionUnavailable", code: 2, userInfo: [NSLocalizedDescriptionKey: "On-device Vision OCR is unavailable on this Mac. The original media remains stored; a compatible vision model or supplied transcript can still be used."]) }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    static func extract(_ url: URL, kind: String, requestSpeechPermission: Bool = false) async throws -> NativeIngestionResult {
        if kind == "audio" { return try await speech(url, requestPermission: requestSpeechPermission) }
        if kind == "video" {
            let asset = AVURLAsset(url: url), duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw WorkspaceStore.error("The video duration could not be read.") }
            return try await Task.detached(priority: .utility) {
                let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1280, height: 1280)
                let count = min(12, max(1, Int(duration / 2)))
                var rows: [String] = []
                for index in 0..<count {
                    try Task.checkCancellation()
                    let second = min(max(0, duration - 0.1), Double(index) * duration / Double(count))
                    if let image = try? generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: nil), let text = try? imageText(image), !text.isEmpty { rows.append(String(format: "[%.1fs] ", second) + text) }
                }
                guard !rows.isEmpty else { throw WorkspaceStore.error("No readable text was found in sampled video frames. Add a transcript or a configured media description for scene meaning.") }
                return NativeIngestionResult(text: String(rows.joined(separator: "\n\n").prefix(100_000)), detail: "On-device OCR of \(count) sampled video frames; timestamps identify samples. This does not describe unseen frames or infer scene meaning.")
            }.value
        }
        return try await Task.detached(priority: .utility) {
            if kind == "image" {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WorkspaceStore.error("The image could not be decoded for OCR.") }
                let text = try imageText(image)
                guard !text.isEmpty else { throw WorkspaceStore.error("No readable image text found. Vision models can still use the image itself.") }
                return NativeIngestionResult(text: String(text.prefix(100_000)), detail: "Text extracted on this Mac with the Vision English OCR recognizer. Other languages and general image understanding require a compatible vision model.")
            }
            if kind == "document", url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) {
                var pages: [String] = []
                for i in 0..<min(document.pageCount, 50) {
                    guard let page = document.page(at: i) else { continue }
                    var text = page.string ?? ""
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let thumbnail = page.thumbnail(of: CGSize(width: 1600, height: 2000), for: .mediaBox)
                        if let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) { text = (try? imageText(image)) ?? "" }
                    }
                    if !text.isEmpty { pages.append("Page \(i + 1):\n" + text) }
                    if pages.reduce(0, { $0 + $1.count }) >= 100_000 { break }
                }
                guard !pages.isEmpty else { throw WorkspaceStore.error("No PDF text could be extracted from the first 50 pages.") }
                return NativeIngestionResult(text: String(pages.joined(separator: "\n\n").prefix(100_000)), detail: "PDF text extraction with on-device OCR for scanned pages; at most 50 pages.")
            }
            throw WorkspaceStore.error("This format needs an exported text snapshot or an enabled compatible extraction adapter.")
        }.value
    }
    private static func speech(_ url: URL, requestPermission: Bool) async throws -> NativeIngestionResult {
        var authorization = SFSpeechRecognizer.authorizationStatus()
        if authorization == .notDetermined, requestPermission { authorization = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } } }
        guard authorization == .authorized else { throw WorkspaceStore.error("Audio is stored but not transcribed. Use the explicit Transcribe action to grant Speech Recognition permission, or supply a transcript.") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw WorkspaceStore.error("On-device speech recognition is unavailable for this Mac/language. No audio was sent to a cloud service; supply a transcript or configure an authorized adapter.") }
        let request = SFSpeechURLRecognitionRequest(url: url); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            let holder = NativeSpeechContinuation(continuation)
            holder.task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal { holder.finish(.success(NativeIngestionResult(text: String(result.bestTranscription.formattedString.prefix(100_000)), detail: "On-device Speech transcription. Recognition may contain errors; review before relying on it."))) }
                else if error != nil { holder.finish(.failure(WorkspaceStore.error("On-device speech transcription failed. The audio remains stored; add a transcript manually."))) }
            }
            Task { try? await Task.sleep(for: .seconds(90)); holder.finish(.failure(WorkspaceStore.error("Speech transcription timed out; no cloud fallback was used."))) }
        }
    }
    static func documentURL(_ raw: String) throws -> URL {
        guard let citation = try BaseClient.documentCitation(raw), var url = URLComponents(string: citation), let host = url.host?.lowercased() else { throw WorkspaceStore.error("Enter a public HTTPS document URL.") }
        if host == "docs.google.com" {
            let parts = url.path.split(separator: "/")
            guard parts.count >= 3, ["document", "spreadsheets", "presentation"].contains(String(parts[0])), parts[1] == "d", parts[2].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw WorkspaceStore.error("Use the standard Google Docs /document/d/ID link or a public text export URL.") }
            url.path = "/\(parts[0])/d/\(parts[2])/export"; url.query = "format=" + (parts[0] == "spreadsheets" ? "csv" : "txt"); url.fragment = nil
        }
        guard let result = url.url else { throw WorkspaceStore.error("The document URL is invalid.") }
        return result
    }
    static func validatePublicHost(_ host: String) throws {
        let lower = host.lowercased()
        guard lower != "localhost", !lower.hasSuffix(".local"), !lower.hasSuffix(".internal"), !lower.contains(":"), lower.contains("."), lower.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) == nil else { throw WorkspaceStore.error("Live document fetches require a public HTTPS hostname.") }
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { throw WorkspaceStore.error("The document host could not be resolved.") }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let entry = current {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { throw WorkspaceStore.error("The document host could not be verified.") }
            let address = String(cString: buffer).lowercased()
            if entry.pointee.ai_family == AF_INET {
                let n = address.split(separator: ".").compactMap { Int($0) }
                guard n.count == 4, n[0] != 0, n[0] != 10, n[0] != 127, n[0] < 224, !(n[0] == 169 && n[1] == 254), !(n[0] == 172 && (16...31).contains(n[1])), !(n[0] == 192 && n[1] == 168), !(n[0] == 100 && (64...127).contains(n[1])) else { throw WorkspaceStore.error("Private-network document hosts are not allowed.") }
            } else if address == "::" || address == "::1" || address.hasPrefix("fc") || address.hasPrefix("fd") || address.hasPrefix("fe8") || address.hasPrefix("fe9") || address.hasPrefix("fea") || address.hasPrefix("feb") || address.hasPrefix("::ffff:") { throw WorkspaceStore.error("Private-network document hosts are not allowed.") }
            current = entry.pointee.ai_next
        }
    }
    static func fetchDocument(_ raw: String) async throws -> NativeIngestionResult {
        let url = try documentURL(raw)
        try await Task.detached { try validatePublicHost(url.host ?? "") }.value
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30; config.httpShouldSetCookies = false; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NativeDocumentRedirects(initialHost: url.host ?? ""), delegateQueue: nil); defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw WorkspaceStore.error("The document is unavailable or requires sign-in. Publish a text export or provide an authorized snapshot; redirects are not followed.") }
        guard response.expectedContentLength <= 2 * 1024 * 1024 else { throw WorkspaceStore.error("Document export exceeds 2 MB.") }
        let mime = (response.mimeType ?? "").lowercased()
        guard mime.hasPrefix("text/"), mime != "text/html" || url.host != "docs.google.com" else { throw WorkspaceStore.error("The host returned a sign-in page or unsupported document export. Use a public text/CSV/Markdown export URL.") }
        var data = Data()
        for try await byte in stream { guard data.count < 2 * 1024 * 1024 else { throw WorkspaceStore.error("Document export exceeds 2 MB.") }; data.append(byte) }
        guard var text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw WorkspaceStore.error("The document export is not valid UTF-8 text.") }
        if mime == "text/html" { text = text.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: "", options: .regularExpression).replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression) }
        return NativeIngestionResult(text: String(text.prefix(100_000)), detail: "Fetched a live public HTTPS export on \(ISO8601DateFormatter().string(from: Date())). Private Google OAuth is not configured in the native client.")
    }
}
private final class NativeSpeechContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NativeIngestionResult, Error>?
    var task: SFSpeechRecognitionTask?
    init(_ continuation: CheckedContinuation<NativeIngestionResult, Error>) { self.continuation = continuation }
    func finish(_ result: Result<NativeIngestionResult, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        guard let value else { return }; task?.cancel(); task = nil; value.resume(with: result)
    }
}

/// Public Google exports may redirect to their own download domain. No cookies or credentials
/// are forwarded; arbitrary cross-host redirects and private destinations remain refused.
private final class NativeDocumentRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let initialHost: String
    var count = 0
    init(initialHost: String) { self.initialHost = initialHost.lowercased() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard initialHost == "docs.google.com", count < 3, let url = request.url, url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(), host == "docs.google.com" || host.hasSuffix(".googleusercontent.com"), (try? NativeWorkspaceIngestion.validatePublicHost(host)) != nil else { completionHandler(nil); return }
        count += 1; var sanitized = request; sanitized.setValue(nil, forHTTPHeaderField: "Authorization"); sanitized.setValue(nil, forHTTPHeaderField: "Cookie"); completionHandler(sanitized)
    }
}
