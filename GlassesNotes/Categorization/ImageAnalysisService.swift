// ImageAnalysisService.swift
// One OpenAI gpt-5.1 vision call per captured observation. Returns a short
// factual image_report combining what's visible in the photo with the voice
// note context.

import Foundation

actor ImageAnalysisService {

    private let apiKey: String
    private let model: String
    private let session: URLSession

    private static let endpoint = "https://api.openai.com/v1/chat/completions"

    init(apiKey: String, model: String = "gpt-5.1", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// Sends note + JPEG to gpt-5.1 and returns the image_report string.
    func summarize(note: String, photoJPEG: Data) async throws -> String {
        guard let url = URL(string: Self.endpoint) else {
            print("[ImageAnalysis] ✗ invalid endpoint URL: \(Self.endpoint)")
            throw ServiceError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let systemPrompt = """
        You are an agricultural field analyst. The user has captured a single field \
        observation: a photo and optionally a short voice note. Write a one-paragraph \
        factual report (2-4 sentences) describing exactly what is visible in the photo \
        and how, if at all, the voice note relates. Be concrete about colors, symptoms, \
        equipment, crops, or terrain. Avoid speculation about causes.

        Return ONLY valid JSON — no markdown:
        {"image_report": "<the report>"}
        """

        let noteText = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let userText = noteText.isEmpty
            ? "Voice note: (none — describe the photo on its own)"
            : "Voice note: \(noteText)"

        let dataURI = "data:image/jpeg;base64,\(photoJPEG.base64EncodedString())"
        let userContent: [[String: Any]] = [
            ["type": "text", "text": userText],
            ["type": "image_url", "image_url": ["url": dataURI]],
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userContent],
            ],
            "response_format": ["type": "json_object"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let bodyBytes = req.httpBody?.count ?? 0

        print("[ImageAnalysis] → \(model) | note=\"\(noteText.prefix(80))\(noteText.count > 80 ? "…" : "")\" | jpegBytes=\(photoJPEG.count) | requestBodyBytes=\(bodyBytes)")
        print("[ImageAnalysis]   userText=\"\(userText)\"")

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            print("[ImageAnalysis] ✗ network error after \(elapsedMs(since: started))ms: \(error)")
            throw error
        }
        let elapsed = elapsedMs(since: started)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[ImageAnalysis]   HTTP \(status) in \(elapsed)ms | responseBytes=\(data.count)")

        guard status == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "(no body)"
            print("[ImageAnalysis] ✗ HTTP \(status): \(msg.prefix(400))")
            throw ServiceError.httpError(status, msg)
        }

        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            let contentData = content.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: contentData)) as? [String: Any],
            let report = parsed["image_report"] as? String
        else {
            let preview = String(data: data, encoding: .utf8) ?? "(binary)"
            print("[ImageAnalysis] ✗ malformed response (first 400 chars): \(preview.prefix(400))")
            throw ServiceError.malformedResponse(preview)
        }

        if let usage = root["usage"] as? [String: Any] {
            let pt = usage["prompt_tokens"] ?? "?"
            let ct = usage["completion_tokens"] ?? "?"
            let tt = usage["total_tokens"] ?? "?"
            print("[ImageAnalysis]   tokens: prompt=\(pt) completion=\(ct) total=\(tt)")
        }

        let trimmed = report.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[ImageAnalysis] ✓ report (\(trimmed.count) chars): \"\(trimmed)\"")
        return trimmed
    }

    private func elapsedMs(since: Date) -> Int {
        Int(Date().timeIntervalSince(since) * 1000)
    }

    enum ServiceError: Error, LocalizedError {
        case invalidURL
        case httpError(Int, String)
        case malformedResponse(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid OpenAI URL"
            case .httpError(let c, let m): return "HTTP \(c): \(m.prefix(160))"
            case .malformedResponse(let r): return "Malformed response: \(r.prefix(160))"
            }
        }
    }
}
