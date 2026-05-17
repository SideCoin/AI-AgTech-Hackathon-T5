// OpenAIAnalysisService.swift
// OpenAI (GPT-5.1) counterpart to AnalysisService.
//
// Orchestrates the per-row analysis pipeline:
//   DataJSONLoader.iterEntries()
//     → OpenAIChatService.analyzeSingle() per entry
//     → [ObservationRow]
//
// Public surface intentionally mirrors AnalysisService so the two are
// interchangeable in higher-level code.

import Foundation

actor OpenAIAnalysisService {

    // MARK: - Dependencies

    private let client: OpenAIChatService

    init(apiKey: String, model: String = "gpt-5.1") {
        self.client = OpenAIChatService(apiKey: apiKey, model: model)
    }

    // MARK: - Public API

    /// Analyze each entry in an iOS data.json file individually.
    /// Mirrors AnalysisService.analyzeJSON() — one OpenAI call per entry.
    func analyzeJSON(
        jsonURL: URL,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> [ObservationRow] {
        let entries = try DataJSONLoader.iterEntries(from: jsonURL)
        var results: [ObservationRow] = []
        results.reserveCapacity(entries.count)

        // DateFormatters created once — they're expensive to instantiate.
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone   = TimeZone(identifier: "UTC")
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        timeFmt.timeZone   = TimeZone(identifier: "UTC")

        print("[OpenAIAnalysisService] analyzeJSON: \(entries.count) entries")

        for (index, entry) in entries.enumerated() {
            let analysis = try await client.analyzeSingle(
                note:      entry.note,
                latitude:  entry.latitude,
                longitude: entry.longitude,
                timestamp: entry.timestamp,
                imageData: entry.imageData
            )
            let importance = ObservationRow.Importance(rawValue: analysis.importance) ?? .low
            results.append(ObservationRow(
                id:          entry.entryID,
                date:        dateFmt.string(from: entry.timestamp),
                time:        timeFmt.string(from: entry.timestamp),
                location:    .init(latitude: entry.latitude, longitude: entry.longitude),
                importance:  importance,
                keynotes:    analysis.keynotes,
                imageName:   entry.imageName,
                imageReport: analysis.imageReport,
                note:        entry.note
            ))
            onProgress?(index + 1, entries.count)
        }
        return results
    }

    // MARK: - JSON persistence (delegates to AnalysisService for byte-for-byte parity)

    static func saveRows(_ rows: [ObservationRow], to url: URL) throws {
        try AnalysisService.saveRows(rows, to: url)
    }
    static func loadRows(from url: URL) throws -> [ObservationRow] {
        try AnalysisService.loadRows(from: url)
    }
}
