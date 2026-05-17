// AnalysisModels.swift
// Mirrors services/analysis/analysis/models.py
//
// JSON-Codable data structures for the per-row Gemini analysis output and
// the keyword-based category grouping. All CodingKeys match the Python
// snake_case JSON produced by analyze_csv() and categorize_results.py.

import Foundation

// MARK: - Per-row analysis result (matches analyze_csv JSON output)

struct ObservationRow: Codable, Identifiable {
    let id: String
    let date: String        // "YYYY-MM-DD"
    let time: String        // "HH:MM"
    let location: GPSLocation
    let importance: Importance
    let keynotes: [String]
    let imageName: String
    let imageReport: String
    let note: String

    struct GPSLocation: Codable {
        let latitude: Double
        let longitude: Double
    }

    enum Importance: String, Codable {
        case low, medium, high
    }

    enum CodingKeys: String, CodingKey {
        case id, date, time, location, importance, keynotes, note
        case imageName   = "image_name"
        case imageReport = "image_report"
    }
}

// MARK: - Category group (matches categorize_results JSON output)

struct CategoryGroup: Codable, Identifiable {
    var id: String { category }
    let category: String
    let priority: String   // "High" | "Medium" | "Low"
    let items: [ObservationRow]
}

// MARK: - Single-observation Gemini response (matches analyze_single() return)

struct RowAnalysis: Decodable {
    let importance: String
    let keynotes: [String]
    let imageReport: String

    enum CodingKeys: String, CodingKey {
        case importance, keynotes
        case imageReport = "image_report"
    }
}

// MARK: - LLM categorization output (matches categorize_results_llm.py)

struct LLMCategorizedItem: Codable {
    let id: String
    let date: String
    let time: String
    let location: ObservationRow.GPSLocation
    let importance: ObservationRow.Importance
    let keynotes: [String]
    let imageName: String
    let imageReport: String
    let note: String
    let category: String
    let priority: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case id, date, time, location, importance, keynotes, note, category, priority, reason
        case imageName   = "image_name"
        case imageReport = "image_report"
    }
}

struct LLMCategoryGroup: Codable, Identifiable {
    var id: String { category }
    let category: String
    let priority: String
    let items: [LLMCategorizedItem]
}

struct GeminiClassification: Decodable {
    let id: String
    let category: String
    let priority: String
    let reason: String
}

struct GeminiClassificationResponse: Decodable {
    let classifications: [GeminiClassification]
}
