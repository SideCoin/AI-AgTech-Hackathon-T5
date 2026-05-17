import Foundation
import SwiftUI

struct Category: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var colorHex: String
    var count: Int

    static let uncategorizedID = "uncategorized"
    static let uncategorizedColorHex = "#9E9E9E"

    static func makeUncategorized(count: Int = 0) -> Category {
        Category(id: uncategorizedID, name: "Uncategorized", colorHex: uncategorizedColorHex, count: count)
    }

    var isUncategorized: Bool { id == Category.uncategorizedID }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

@Observable
@MainActor
final class CategoryStore {
    private(set) var categories: [Category] = []
    private(set) var enabledCategoryIds: Set<String> = []

    private let categoriesKey = "app.categories.v2"
    private let enabledKey = "app.enabledCategoryIds.v2"

    init() {
        load()
        if categories.isEmpty {
            categories = [
                Category.makeUncategorized(),
                Category(id: UUID().uuidString, name: "Crop Health",   colorHex: "#4CAF50", count: 0),
                Category(id: UUID().uuidString, name: "Irrigation",    colorHex: "#2196F3", count: 0),
                Category(id: UUID().uuidString, name: "Pest & Disease",colorHex: "#F44336", count: 0),
                Category(id: UUID().uuidString, name: "Equipment",     colorHex: "#FF9800", count: 0),
            ]
            enabledCategoryIds = Set(categories.map(\.id))
            persist()
        }
        ensureUncategorized()
    }

    private func ensureUncategorized() {
        if !categories.contains(where: { $0.isUncategorized }) {
            categories.insert(Category.makeUncategorized(), at: 0)
        }
        enabledCategoryIds.insert(Category.uncategorizedID)
        persist()
    }

    var totalPinCount: Int     { categories.reduce(0) { $0 + $1.count } }
    var visiblePinCount: Int   { categories.filter { enabledCategoryIds.contains($0.id) }.reduce(0) { $0 + $1.count } }
    var enabledCount: Int      { enabledCategoryIds.count }
    var enabledCategories: [Category] { categories.filter { enabledCategoryIds.contains($0.id) } }

    func isEnabled(_ id: String) -> Bool { enabledCategoryIds.contains(id) }

    func toggle(_ id: String) {
        if enabledCategoryIds.contains(id) { enabledCategoryIds.remove(id) }
        else { enabledCategoryIds.insert(id) }
        persist()
    }

    func selectAll()  { enabledCategoryIds = Set(categories.map(\.id)); persist() }
    func selectNone() { enabledCategoryIds = []; persist() }

    func incrementCount(for categoryId: String) {
        guard let idx = categories.firstIndex(where: { $0.id == categoryId }) else { return }
        categories[idx].count += 1
        persist()
    }

    /// Recomputes every category's `count` from the given observations so the
    /// numbers shown in the drawer match the pins actually on disk. Anything
    /// with no category, or a category id that no longer exists, falls into
    /// Uncategorized. Call this after loading observations from disk.
    func recomputeCounts(from observations: [CaptureObservation]) {
        let validIDs = Set(categories.map(\.id))
        var tally: [String: Int] = [:]
        for obs in observations {
            let raw = obs.categoryOrUncategorized
            let id = validIDs.contains(raw) ? raw : Category.uncategorizedID
            tally[id, default: 0] += 1
        }
        var changed = false
        for i in categories.indices {
            let newCount = tally[categories[i].id] ?? 0
            if categories[i].count != newCount {
                categories[i].count = newCount
                changed = true
            }
        }
        if changed { persist() }
    }

    /// Case-insensitive name lookup. Returns nil if no category has that name.
    func category(named name: String) -> Category? {
        let target = name.lowercased()
        return categories.first { $0.name.lowercased() == target }
    }

    /// Returns an existing category that matches `name` (case-insensitive) or
    /// mints a brand-new one with the given color. New categories are enabled
    /// by default so their pins show up on the map immediately.
    @discardableResult
    func upsertCategory(name: String, colorHex: String) -> Category {
        if let existing = category(named: name) { return existing }
        let new = Category(id: UUID().uuidString, name: name, colorHex: colorHex, count: 0)
        categories.append(new)
        enabledCategoryIds.insert(new.id)
        persist()
        return new
    }

    /// Deletes a category and reassigns any observations it owned to "uncategorized".
    /// Uncategorized itself cannot be deleted.
    func deleteCategory(id: String) {
        guard id != Category.uncategorizedID,
              let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        let movedCount = categories[idx].count
        categories.remove(at: idx)
        enabledCategoryIds.remove(id)
        if let uIdx = categories.firstIndex(where: { $0.isUncategorized }) {
            categories[uIdx].count += movedCount
        }
        try? ObservationStore().reassignCategory(from: id, to: nil)
        persist()
    }

    private func load() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: categoriesKey),
           let cats = try? JSONDecoder().decode([Category].self, from: data) {
            categories = cats
        }
        if let ids = d.array(forKey: enabledKey) as? [String] {
            enabledCategoryIds = Set(ids)
        } else {
            enabledCategoryIds = Set(categories.map(\.id))
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(categories) { d.set(data, forKey: categoriesKey) }
        d.set(Array(enabledCategoryIds), forKey: enabledKey)
    }
}
