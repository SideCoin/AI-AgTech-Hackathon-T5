// NoteCategorizationService.swift
// Mirrors services/analysis/categorize_results.py
//
// Pure keyword-based categorization — no network calls, no dependencies.
// Rules are applied in order; first keyword match wins.
// Call categorize(note:) for a single note, or group(rows:) for a full list.

import Foundation

enum NoteCategorizationService {

    struct Result {
        let category: String
        let priority: String  // "High" | "Medium" | "Low"
    }

    // Matches the RULES list in categorize_results.py — order matters.
    private static let rules: [(label: String, priority: String, keywords: [String])] = [
        ("Crop disease / pest issue",  "High",   ["fungal", "disease", "infection", "mold", "pest"]),
        ("Pesticide observation",      "High",   ["pesticide", "herbicide", "insecticide", "spray"]),
        ("Fertilizer observation",     "Medium", ["fertilizer", "nitrogen", "phosphorus", "potassium", "npk"]),
        ("Irrigation issue",           "High",   ["irrigation", "water", "leak", "pressure"]),
        ("Livestock observation",      "High",   ["cow", "chicken", "pig", "goat", "sheep", "livestock", "sick"]),
        ("Equipment issue",            "Medium", ["broken", "repair", "equipment", "tractor"]),
        ("General farm note",          "Low",    []),   // default catch-all
    ]

    // Mirrors: def categorize(note: str) -> tuple[str, str]
    static func categorize(note: String) -> Result {
        let lower = note.lowercased()
        for rule in rules {
            let matched = rule.keywords.isEmpty
                || rule.keywords.contains(where: { lower.contains($0) })
            if matched {
                return Result(category: rule.label, priority: rule.priority)
            }
        }
        return Result(category: "General farm note", priority: "Low")
    }

    // Mirrors: the grouping loop in main() of categorize_results.py
    static func group(rows: [ObservationRow]) -> [CategoryGroup] {
        var buckets: [String: [ObservationRow]] = [:]
        var priorityOf: [String: String] = [:]

        for row in rows {
            let result = categorize(note: row.note)
            buckets[result.category, default: []].append(row)
            priorityOf[result.category] = result.priority
        }

        // Emit groups in rule order, omitting empty categories.
        return rules.compactMap { rule in
            guard let items = buckets[rule.label] else { return nil }
            return CategoryGroup(
                category: rule.label,
                priority: rule.priority,
                items: items
            )
        }
    }
}
