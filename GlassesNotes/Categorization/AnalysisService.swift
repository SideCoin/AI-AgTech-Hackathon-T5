// AnalysisService.swift
// Mirrors services/analysis/analysis/service.py → analyze_csv()
//
// Orchestrates the per-row analysis pipeline:
//   CSVLoader.iterRows()
//     → GeminiAnalysisService.analyzeSingle() per row
//     → [ObservationRow]
//   (optional) NoteCategorizationService.group()
//     → [CategoryGroup]
//
// Usage:
//   let service = AnalysisService(apiKey: "YOUR_GEMINI_KEY")
//   let rows    = try await service.analyzeCSV(csvURL: ..., jpgDir: ...)
//   let groups  = NoteCategorizationService.group(rows: rows)

import Foundation

actor AnalysisService {

    // MARK: - Dependencies

    private let gemini: GeminiAnalysisService

    init(apiKey: String, model: String = "gemini-2.5-flash") {
        self.gemini = GeminiAnalysisService(apiKey: apiKey, model: model)
    }

    // MARK: - Public API

    /// Analyze each CSV row individually and return a flat list of ObservationRow.
    /// Mirrors `analyze_csv()` in service.py — one Gemini call per row.
    ///
    /// - Parameters:
    ///   - csvURL:   URL of the input CSV file.
    ///   - jpgDir:   Directory containing the JPG images referenced by jpg_name.
    ///   - onProgress: Optional callback fired after each row with (rowIndex, total).
    /// - Returns: Array of ObservationRow in CSV order.
    func analyzeCSV(
        csvURL: URL,
        jpgDir: URL,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> [ObservationRow] {

        let csvRows = try CSVLoader.iterRows(csvURL: csvURL, jpgDir: jpgDir)
        var results: [ObservationRow] = []
        results.reserveCapacity(csvRows.count)

        // Fix: create formatters once outside the loop (DateFormatter is expensive to initialise)
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone   = TimeZone(identifier: "UTC")
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        timeFmt.timeZone   = TimeZone(identifier: "UTC")

        print("[AnalysisService] analyzeCSV: \(csvRows.count) rows")

        for (index, csvRow) in csvRows.enumerated() {
            let imageData: Data? = csvRow.jpgURL.flatMap { try? Data(contentsOf: $0) }

            let analysis = try await gemini.analyzeSingle(
                note:      csvRow.note,
                latitude:  csvRow.latitude,
                longitude: csvRow.longitude,
                timestamp: csvRow.timestamp,
                imageData: imageData
            )

            let importance = ObservationRow.Importance(rawValue: analysis.importance) ?? .low

            results.append(ObservationRow(
                id:          csvRow.csvID,
                date:        dateFmt.string(from: csvRow.timestamp),
                time:        timeFmt.string(from: csvRow.timestamp),
                location:    .init(latitude: csvRow.latitude, longitude: csvRow.longitude),
                importance:  importance,
                keynotes:    analysis.keynotes,
                imageName:   csvRow.jpgName,
                imageReport: analysis.imageReport,
                note:        csvRow.note
            ))

            onProgress?(index + 1, csvRows.count)
        }

        return results
    }

    /// Analyze each entry in an iOS data.json file individually.
    /// Mirrors analyze_json() — one Gemini call per entry.
    func analyzeJSON(
        jsonURL: URL,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> [ObservationRow] {
        let entries = try DataJSONLoader.iterEntries(from: jsonURL)
        var results: [ObservationRow] = []
        results.reserveCapacity(entries.count)

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone   = TimeZone(identifier: "UTC")
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        timeFmt.timeZone   = TimeZone(identifier: "UTC")

        for (index, entry) in entries.enumerated() {
            let analysis = try await gemini.analyzeSingle(
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

    /// Convenience: analyze all rows then group by keyword category.
    /// Equivalent to running analyze_csv() then categorize_results.py.
    func analyzeAndGroup(
        csvURL: URL,
        jpgDir: URL,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> [CategoryGroup] {
        let rows = try await analyzeCSV(csvURL: csvURL, jpgDir: jpgDir, onProgress: onProgress)
        return NoteCategorizationService.group(rows: rows)
    }

    // MARK: - JSON persistence (mirrors output_path.write_text in service.py)

    /// Encode rows to JSON and write to a file.
    static func saveRows(_ rows: [ObservationRow], to url: URL) throws {
        let data = try JSONEncoder().encode(rows)
        try data.write(to: url)
    }

    /// Encode category groups to JSON and write to a file.
    static func saveGroups(_ groups: [CategoryGroup], to url: URL) throws {
        let data = try JSONEncoder().encode(groups)
        try data.write(to: url)
    }

    /// Load ObservationRow list from a JSON file (e.g. results/*.json).
    static func loadRows(from url: URL) throws -> [ObservationRow] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ObservationRow].self, from: data)
    }

    /// Load CategoryGroup list from a categorized JSON file.
    static func loadGroups(from url: URL) throws -> [CategoryGroup] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CategoryGroup].self, from: data)
    }
}
