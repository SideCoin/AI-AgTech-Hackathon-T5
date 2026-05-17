// GeminiAnalysisService.swift
// Mirrors services/analysis/analysis/gemini_client.py → analyze_single()
//
// Sends one observation (voice note + optional JPEG) to the Gemini REST API
// and returns {importance, keynotes, image_report}.
//
// Usage:
//   let service = GeminiAnalysisService(apiKey: "YOUR_KEY")
//   let result  = try await service.analyzeSingle(
//       note: "The chicken looked sick near the water line.",
//       latitude: 38.544, longitude: -121.741,
//       timestamp: Date(),
//       imageData: jpegData   // or nil
//   )

import Foundation

actor GeminiAnalysisService {

    // MARK: - Configuration

    private let apiKey: String
    private let model: String
    private let session: URLSession

    private static let endpoint =
        "https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent"

    init(
        apiKey: String,
        model: String = "gemini-2.5-flash",
        session: URLSession = .shared
    ) {
        self.apiKey   = apiKey
        self.model    = model
        self.session  = session
    }

    // MARK: - Public API

    /// Analyze one observation and return {importance, keynotes, image_report}.
    /// Mirrors GeminiAnalyzer.analyze_single() in gemini_client.py.
    func analyzeSingle(
        note: String,
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        imageData: Data? = nil
    ) async throws -> RowAnalysis {
        let url = try buildURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Fix: buildRequestBody is now throwing — propagate instead of try!
        let body = try buildRequestBody(
            note: note, latitude: latitude, longitude: longitude,
            timestamp: timestamp, imageData: imageData
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[Gemini] → \(model) | note: \"\(note.prefix(60))\(note.count > 60 ? "…" : "")\" | image: \(imageData != nil)")

        let (data, response) = try await session.data(for: request)
        // Fix: capture status code so httpError message includes it (needed for 429 retry detection)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            print("[Gemini] ✗ HTTP \(statusCode): \(msg.prefix(120))")
            throw GeminiError.httpError(statusCode, msg)
        }

        let result = try parseResponse(data: data)
        print("[Gemini] ✓ importance=\(result.importance) keynotes=\(result.keynotes.count) hasImage=\(result.imageReport != "(no image)")")
        return result
    }

    // MARK: - Private helpers

    private func buildURL() throws -> URL {
        let urlString = String(format: Self.endpoint, model)
            + "?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw GeminiError.invalidURL
        }
        return url
    }

    /// Mirrors GeminiAnalyzer._build_parts() for a single observation.
    // Fix: was non-throwing but used try! internally — now properly throws
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

        // Fix: was try! — now properly propagates the error
        var parts: [[String: Any]] = [
            ["text": try jsonString(meta)],
        ]

        if let jpeg = imageData {
            parts.append([
                "inline_data": [
                    "mime_type": "image/jpeg",
                    "data": jpeg.base64EncodedString(),
                ]
            ])
        }
        parts.append(["text": schemaText])

        let systemInstruction = """
        You are an agricultural field analyst. Analyze one farm inspection observation \
        which includes a voice note and optionally a photo. \
        Return JSON with importance ('low', 'medium', or 'high'), keynotes (2-3 short \
        key findings), and image_report (describe exactly what you see in the photo; \
        use '(no image)' if no photo is provided).
        """

        return [
            "system_instruction": ["parts": [["text": systemInstruction]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "temperature":        0.3,
                "response_mime_type": "application/json",
            ],
        ]
    }

    /// Extract the JSON text from Gemini's response envelope and decode it.
    private func parseResponse(data: Data) throws -> RowAnalysis {
        let rawText = String(data: data, encoding: .utf8) ?? "(binary data)"
        // Fix: use try? so a JSON parse failure falls through to malformedResponse
        // instead of throwing an untyped Foundation error that bypasses our error type.
        guard
            let root       = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let first      = candidates.first,
            let content    = first["content"] as? [String: Any],
            let parts      = content["parts"] as? [[String: Any]],
            let text       = parts.first?["text"] as? String,
            let jsonData   = text.data(using: .utf8)
        else {
            throw GeminiError.malformedResponse(rawText)
        }
        do {
            return try JSONDecoder().decode(RowAnalysis.self, from: jsonData)
        } catch {
            // Fix: wrap decode failure with the raw model text for easier debugging
            throw GeminiError.malformedResponse("JSONDecoder failed: \(error) — raw: \(text.prefix(300))")
        }
    }

    private func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Errors

    enum GeminiError: Error, LocalizedError {
        case invalidURL
        case httpError(Int, String)     // status code + response body
        case malformedResponse(String)  // raw response text for debugging

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid Gemini API URL"
            case .httpError(let code, let msg):
                return "Gemini HTTP \(code): \(msg)"
            case .malformedResponse(let raw):
                return "Could not parse Gemini response: \(raw.prefix(200))"
            }
        }
    }
}
