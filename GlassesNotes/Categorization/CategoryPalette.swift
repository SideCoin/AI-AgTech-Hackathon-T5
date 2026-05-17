import Foundation

/// Fixed pool of distinct hex colors used when auto-minting categories from
/// LLM output. Picks the next color not already used by an existing category;
/// wraps around when exhausted.
enum CategoryPalette {
    static let colors: [String] = [
        "#9C27B0", // purple
        "#00BCD4", // cyan
        "#8BC34A", // light green
        "#FFC107", // amber
        "#E91E63", // pink
        "#3F51B5", // indigo
        "#795548", // brown
        "#009688", // teal
        "#FF5722", // deep orange
        "#607D8B", // blue grey
    ]

    static func nextColor(usedHex: Set<String>) -> String {
        for candidate in colors where !usedHex.contains(candidate.lowercased()) {
            return candidate
        }
        return colors[usedHex.count % colors.count]
    }
}
