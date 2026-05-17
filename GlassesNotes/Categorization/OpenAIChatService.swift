// OpenAIChatService.swift
// OpenAI (GPT-5.1) counterpart to GeminiAnalysisService.
//
// Sends one observation (voice note + optional JPEG) to the OpenAI Chat
// Completions API with vision and returns {importance, keynotes, image_report}.
//
// Usage:
//   let key     = try Secrets.require(.openAI)
//   let service = OpenAIChatService(apiKey: key)
//   let result  = try await service.analyzeSingle(
//       note: "The chicken looked sick near the water line.",
//       latitude: 38.544, longitude: -121.741,
//       timestamp: Date(),
//       imageData: jpegData   // or nil
//   )

import Foundation

actor OpenAIChatService {

    // MARK: - Configuration

    private let apiKey: String
    private let model:  String
    private let session: URLSession

    private static let endpoint = "https://api.openai.com/v1/chat/completions"

    init(
        apiKey: String,
        model: String = "gpt-5.1",
        session: URLSession = .shared
    ) {
        self.apiKey  = apiKey
        self.model   = model
        self.session = session
    }

    // MARK: - Public API

    /// Analyze one observation and return {importance, keynotes, image_report}.
    /// Public surface mirrors GeminiAnalysisService.analyzeSingle() so callers
    /// can swap backends without touching the orchestrator.
    func analyzeSingle(
        note: String,
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        imageData: Data? = nil
    ) async throws -> RowAnalysis {
        guard let url = URL(string: Self.endpoint) else { throw OpenAIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)",  forHTTPHeaderField: "Authorization")

        let body = try buildRequestBody(
            note: note, latitude: latitude, longitude: longitude,
            timestamp: timestamp, imageData: imageData
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[OpenAI] → \(model) | note: \"\(note.prefix(60))\(note.count > 60 ? "…" : "")\" | image: \(imageData != nil)")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            print("[OpenAI] ✗ HTTP \(statusCode): \(msg.prefix(120))")
            throw OpenAIError.httpError(statusCode, msg)
        }

        let result = try parseResponse(data: data)
        print("[OpenAI] ✓ importance=\(result.importance) keynotes=\(result.keynotes.count) hasImage=\(result.imageReport != "(no image)")")
        return result
    }

    // MARK: - Private helpers

    private func buildRequestBody(
        note: String,
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        imageData: Data?
    ) throws -> [String: Any] {
        let iso = ISO8601DateFormatter().string(from: timestamp)
        let meta: [String: Any] = [
            "timestamp": iso,
            "latitude":  latitude,
            "longitude": longitude,
            "note":      note.isEmpty ? "(no voice note)" : note,
            "has_image": imageData != nil,
        ]

        let schemaText = """
        Return ONLY valid JSON — no markdown, no extra keys:
        {
          "importance": "low|medium|high",
          "keynotes": ["<key finding 1>", "<key finding 2>"],
          "image_report": "<describe exactly what the photo shows, or '(no image)'>"
        }
        """

        let systemInstruction = """
        You are an agricultural field analyst. Analyze one farm inspection observation \
        which includes a voice note and optionally a photo. \
        Return JSON with importance ('low', 'medium', or 'high'), keynotes (2-3 short \
        key findings), and image_report (describe exactly what you see in the photo; \
        use '(no image)' if no photo is provided).
        """

        // User content is an array of parts (text + optional image) — required by
        // the Chat Completions vision format.
        var userContent: [[String: Any]] = [
            ["type": "text", "text": try jsonString(meta)],
        ]
        if let jpeg = imageData {
            // Inline base64 data URI — avoids a separate upload round-trip.
            let dataURI = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
            userContent.append([
                "type": "image_url",
                "image_url": ["url": dataURI],
            ])
        }
        userContent.append(["type": "text", "text": schemaText])

        return [
            "model": model,
            "messages": [
                ["role": "system", "content": systemInstruction],
                ["role": "user",   "content": userContent],
            ],
            "response_format": ["type": "json_object"],
        ]
    }

    /// Extract `choices[0].message.content` and decode the JSON string within.
    private func parseResponse(data: Data) throws -> RowAnalysis {
        let rawText = String(data: data, encoding: .utf8) ?? "(binary data)"
        guard
            let root     = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let choices  = root["choices"] as? [[String: Any]],
            let first    = choices.first,
            let message  = first["message"] as? [String: Any],
            let content  = message["content"] as? String,
            let jsonData = content.data(using: .utf8)
        else {
            throw OpenAIError.malformedResponse(rawText)
        }
        do {
            return try JSONDecoder().decode(RowAnalysis.self, from: jsonData)
        } catch {
            throw OpenAIError.malformedResponse(
                "JSONDecoder failed: \(error) — raw: \(content.prefix(300))"
            )
        }
    }

    private func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Errors

    enum OpenAIError: Error, LocalizedError {
        case invalidURL
        case httpError(Int, String)     // status code + response body
        case malformedResponse(String)  // raw response text for debugging

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid OpenAI API URL"
            case .httpError(let code, let msg):
                return "OpenAI HTTP \(code): \(msg)"
            case .malformedResponse(let raw):
                return "Could not parse OpenAI response: \(raw.prefix(200))"
            }
        }
    }
}
