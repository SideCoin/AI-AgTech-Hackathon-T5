// SessionCategorizationService.swift
// One OpenAI gpt-5.1 call per session-end. Sends the {id, note, image_report}
// for every observation in the session plus the list of existing category names,
// and asks the model to assign each observation a short category label,
// reusing existing labels when applicable.

import Foundation

actor SessionCategorizationService {

    struct Row {
        let id: UUID
        let note: String
        let imageReport: String?
    }

    private let apiKey: String
    private let model: String
    private let session: URLSession

    private static let endpoint = "https://api.openai.com/v1/chat/completions"

    init(apiKey: String, model: String = "gpt-5.1", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// Returns a map of observation id → category label. Observations that are
    /// missing from the response are simply omitted (caller treats them as
    /// uncategorized).
    func categorize(rows: [Row], existingCategories: [String]) async throws -> [UUID: String] {
        guard !rows.isEmpty else {
            print("[SessionCategorize] no rows to categorize — returning empty map")
            return [:]
        }
        guard let url = URL(string: Self.endpoint) else {
            print("[SessionCategorize] ✗ invalid endpoint URL: \(Self.endpoint)")
            throw ServiceError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let systemPrompt = """
        You are categorizing a batch of agricultural field observations from a single \
        walk. Each row has an id, a voice note, and an image_report describing the \
        photo. Assign each row to a short (2-4 word) lowercase category label such as \
        "powdery mildew", "irrigation issue", or "equipment check".

        Prefer reusing one of the EXISTING labels listed below when the phenomenon \
        matches; only mint a new label when nothing existing fits. Every row must be \
        assigned exactly one category.

        Return ONLY valid JSON — no markdown:
        {"assignments": [{"id": "<uuid>", "category": "<label>"}, ...]}
        """

        let existingBlock: String
        if existingCategories.isEmpty {
            existingBlock = "Existing categories: (none yet — mint new labels as needed)"
        } else {
            existingBlock = "Existing categories:\n" +
                existingCategories.map { "- \($0)" }.joined(separator: "\n")
        }

        let rowsJSON: [[String: Any]] = rows.map { r in
            [
                "id": r.id.uuidString,
                "note": r.note.isEmpty ? "(no voice note)" : r.note,
                "image_report": r.imageReport ?? "(no image report)",
            ]
        }
        let rowsText = (try? JSONSerialization.data(withJSONObject: rowsJSON, options: [.prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let userPrompt = """
        \(existingBlock)

        Observations (JSON):
        \(rowsText)
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt],
            ],
            "response_format": ["type": "json_object"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let bodyBytes = req.httpBody?.count ?? 0

        print("[SessionCategorize] → \(model) | rows=\(rows.count) | existing=\(existingCategories.count) | requestBodyBytes=\(bodyBytes)")
        if existingCategories.isEmpty {
            print("[SessionCategorize]   existing labels: (none)")
        } else {
            print("[SessionCategorize]   existing labels: \(existingCategories.joined(separator: ", "))")
        }
        for (i, r) in rows.enumerated() {
            let notePreview = r.note.isEmpty ? "(no note)" : r.note.prefix(60) + (r.note.count > 60 ? "…" : "")
            let reportPreview = (r.imageReport ?? "(no report)").prefix(80) + ((r.imageReport?.count ?? 0) > 80 ? "…" : "")
            print("[SessionCategorize]   row[\(i)] id=\(r.id.uuidString.prefix(8)) note=\"\(notePreview)\" report=\"\(reportPreview)\"")
        }

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            print("[SessionCategorize] ✗ network error after \(elapsedMs(since: started))ms: \(error)")
            throw error
        }
        let elapsed = elapsedMs(since: started)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[SessionCategorize]   HTTP \(status) in \(elapsed)ms | responseBytes=\(data.count)")

        guard status == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "(no body)"
            print("[SessionCategorize] ✗ HTTP \(status): \(msg.prefix(400))")
            throw ServiceError.httpError(status, msg)
        }

        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            let contentData = content.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: contentData)) as? [String: Any],
            let assignments = parsed["assignments"] as? [[String: Any]]
        else {
            let preview = String(data: data, encoding: .utf8) ?? "(binary)"
            print("[SessionCategorize] ✗ malformed response (first 400 chars): \(preview.prefix(400))")
            throw ServiceError.malformedResponse(preview)
        }

        if let usage = root["usage"] as? [String: Any] {
            let pt = usage["prompt_tokens"] ?? "?"
            let ct = usage["completion_tokens"] ?? "?"
            let tt = usage["total_tokens"] ?? "?"
            print("[SessionCategorize]   tokens: prompt=\(pt) completion=\(ct) total=\(tt)")
        }
        print("[SessionCategorize]   raw content: \(content)")

        var out: [UUID: String] = [:]
        var skippedCount = 0
        for entry in assignments {
            guard
                let idStr = entry["id"] as? String,
                let id = UUID(uuidString: idStr),
                let raw = entry["category"] as? String
            else {
                print("[SessionCategorize]   ! skipping malformed entry: \(entry)")
                skippedCount += 1
                continue
            }
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !label.isEmpty else {
                print("[SessionCategorize]   ! skipping empty label for id=\(idStr.prefix(8))")
                skippedCount += 1
                continue
            }
            out[id] = label
            print("[SessionCategorize]   ↳ \(idStr.prefix(8)) → \"\(label)\"")
        }
        let missing = rows.filter { out[$0.id] == nil }
        for r in missing {
            print("[SessionCategorize]   ! row \(r.id.uuidString.prefix(8)) had no assignment in response")
        }
        print("[SessionCategorize] ✓ assigned \(out.count)/\(rows.count) rows (skipped=\(skippedCount), missing=\(missing.count))")
        return out
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
