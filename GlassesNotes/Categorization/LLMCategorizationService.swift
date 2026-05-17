// LLMCategorizationService.swift
// Mirrors services/analysis/categorize_results_llm.py
//
// Single Gemini call: [ObservationRow] → [LLMCategoryGroup]

import Foundation

actor LLMCategorizationService {

    private let apiKey: String
    private let model:  String
    private let session: URLSession

    private static let endpoint =
        "https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent"

    init(apiKey: String, model: String = "gemini-2.5-flash", session: URLSession = .shared) {
        self.apiKey   = apiKey
        self.model    = model
        self.session  = session
    }

    // MARK: - Public API

    func classify(
        rows: [ObservationRow],
        maxCategories: Int? = nil
    ) async throws -> [LLMCategoryGroup] {
        let maxCats = maxCategories ?? max(1, Int(Double(rows.count) * 0.4))
        return try await classify(rows: rows, maxCategories: maxCats)
    }

    func classify(
        rows: [ObservationRow],
        maxCategories: Int
    ) async throws -> [LLMCategoryGroup] {
        let classifications = try await callGemini(rows: rows, maxCategories: maxCategories)
        return groupByCategory(rows: rows, classifications: classifications)
    }

    static func saveGroups(_ groups: [LLMCategoryGroup], to url: URL) throws {
        let data = try JSONEncoder().encode(groups)
        try data.write(to: url)
    }

    static func loadGroups(from url: URL) throws -> [LLMCategoryGroup] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([LLMCategoryGroup].self, from: data)
    }

    // MARK: - Private

    private func callGemini(
        rows: [ObservationRow],
        maxCategories: Int
    ) async throws -> [GeminiClassification] {
        let urlStr = String(format: Self.endpoint, model) + "?key=\(apiKey)"
        guard let url = URL(string: urlStr) else { throw LLMError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let rowsJSON = rows.map { r -> [String: Any] in
            ["id": r.id, "time": r.time, "note": r.note,
             "importance": r.importance.rawValue, "keynotes": r.keynotes]
        }
        let rowsText = (try? JSONSerialization.data(withJSONObject: rowsJSON))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let prompt = """
        You are an agricultural analyst. Group the following \(rows.count) farm observations \
        into AT MOST \(maxCategories) thematic categories.

        Observations (JSON):
        \(rowsText)

        Rules:
        - Every observation must be assigned to exactly one category.
        - Use at most \(maxCategories) categories total.
        - Each category gets a priority: "high", "medium", or "low".
        - Each item gets the same priority as its category.
        - Write a one-sentence reason for each assignment.

        Return ONLY valid JSON — no markdown:
        {
          "classifications": [
            {"id": "<obs id>", "category": "<name>", "priority": "high|medium|low", "reason": "<one sentence>"},
            ...
          ]
        }
        """

        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.2, "response_mime_type": "application/json"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[LLMCategorize] → classify \(rows.count) rows, maxCats=\(maxCategories)")

        let (data, response) = try await session.data(for: req)
        // Fix: include status code in error so 429 retry detection works
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            print("[LLMCategorize] ✗ HTTP \(statusCode): \(msg.prefix(120))")
            throw LLMError.httpError(statusCode, msg)
        }

        let rawText = String(data: data, encoding: .utf8) ?? "(binary data)"
        // Fix: use try? so JSON parse failure falls through to malformedResponse
        guard
            let root       = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let content    = candidates.first?["content"] as? [String: Any],
            let parts      = content["parts"] as? [[String: Any]],
            let text       = parts.first?["text"] as? String,
            let jsonData   = text.data(using: .utf8)
        else { throw LLMError.malformedResponse(rawText) }

        do {
            let result = try JSONDecoder().decode(GeminiClassificationResponse.self, from: jsonData)
            print("[LLMCategorize] ✓ \(result.classifications.count) classifications received")
            return result.classifications
        } catch {
            throw LLMError.malformedResponse("JSONDecoder failed: \(error) — raw: \(text.prefix(300))")
        }
    }

    private func groupByCategory(
        rows: [ObservationRow],
        classifications: [GeminiClassification]
    ) -> [LLMCategoryGroup] {
        let map = Dictionary(uniqueKeysWithValues: classifications.map { ($0.id, $0) })
        let priorityRank = ["high": 0, "medium": 1, "low": 2]

        var buckets: [String: (priority: String, items: [LLMCategorizedItem])] = [:]
        for row in rows {
            let cls = map[row.id]
            let cat      = cls?.category ?? "Uncategorised"
            let priority = cls?.priority ?? "low"
            let reason   = cls?.reason   ?? ""
            let item = LLMCategorizedItem(
                id: row.id, date: row.date, time: row.time, location: row.location,
                importance: row.importance, keynotes: row.keynotes,
                imageName: row.imageName, imageReport: row.imageReport, note: row.note,
                category: cat, priority: priority, reason: reason
            )
            if buckets[cat] == nil { buckets[cat] = (priority, []) }
            buckets[cat]!.items.append(item)
        }

        return buckets.map { LLMCategoryGroup(category: $0.key, priority: $0.value.priority, items: $0.value.items) }
            .sorted { (priorityRank[$0.priority] ?? 2) < (priorityRank[$1.priority] ?? 2) }
    }

    enum LLMError: Error, LocalizedError {
        case invalidURL
        case httpError(Int, String)     // status code + response body
        case malformedResponse(String)  // raw response text for debugging

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid URL"
            case .httpError(let code, let m):
                return "HTTP \(code): \(m)"
            case .malformedResponse(let raw):
                return "Malformed response: \(raw.prefix(200))"
            }
        }
    }
}
