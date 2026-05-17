// OpenAILLMCategorizationService.swift
// OpenAI (GPT-5.1) counterpart to LLMCategorizationService.
//
// Single GPT call: [ObservationRow] → [LLMCategoryGroup]

import Foundation

actor OpenAILLMCategorizationService {

    private let apiKey: String
    private let model:  String
    private let session: URLSession

    private static let endpoint = "https://api.openai.com/v1/chat/completions"

    init(apiKey: String, model: String = "gpt-5.1", session: URLSession = .shared) {
        self.apiKey  = apiKey
        self.model   = model
        self.session = session
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
        let classifications = try await callOpenAI(rows: rows, maxCategories: maxCategories)
        return groupByCategory(rows: rows, classifications: classifications)
    }

    // Delegates so persistence stays in one place (LLMCategorizationService).
    static func saveGroups(_ groups: [LLMCategoryGroup], to url: URL) throws {
        try LLMCategorizationService.saveGroups(groups, to: url)
    }
    static func loadGroups(from url: URL) throws -> [LLMCategoryGroup] {
        try LLMCategorizationService.loadGroups(from: url)
    }

    // MARK: - Private

    private func callOpenAI(
        rows: [ObservationRow],
        maxCategories: Int
    ) async throws -> [GeminiClassification] {
        guard let url = URL(string: Self.endpoint) else { throw OpenAILLMError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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
            "model": model,
            "messages": [
                ["role": "user", "content": prompt],
            ],
            "response_format": ["type": "json_object"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[OpenAILLMCategorize] → classify \(rows.count) rows, maxCats=\(maxCategories)")

        let (data, response) = try await session.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            print("[OpenAILLMCategorize] ✗ HTTP \(statusCode): \(msg.prefix(120))")
            throw OpenAILLMError.httpError(statusCode, msg)
        }

        let rawText = String(data: data, encoding: .utf8) ?? "(binary data)"
        guard
            let root     = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let choices  = root["choices"] as? [[String: Any]],
            let message  = choices.first?["message"] as? [String: Any],
            let content  = message["content"] as? String,
            let jsonData = content.data(using: .utf8)
        else { throw OpenAILLMError.malformedResponse(rawText) }

        do {
            let result = try JSONDecoder().decode(GeminiClassificationResponse.self, from: jsonData)
            print("[OpenAILLMCategorize] ✓ \(result.classifications.count) classifications received")
            return result.classifications
        } catch {
            throw OpenAILLMError.malformedResponse(
                "JSONDecoder failed: \(error) — raw: \(content.prefix(300))"
            )
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
            let cls      = map[row.id]
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

    enum OpenAILLMError: Error, LocalizedError {
        case invalidURL
        case httpError(Int, String)
        case malformedResponse(String)

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
