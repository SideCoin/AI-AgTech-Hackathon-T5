import Foundation
import SwiftUI

struct Category: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var colorHex: String
    var count: Int
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
                Category(id: UUID().uuidString, name: "Crop Health",   colorHex: "#4CAF50", count: 0),
                Category(id: UUID().uuidString, name: "Irrigation",    colorHex: "#2196F3", count: 0),
                Category(id: UUID().uuidString, name: "Pest & Disease",colorHex: "#F44336", count: 0),
                Category(id: UUID().uuidString, name: "Equipment",     colorHex: "#FF9800", count: 0),
            ]
            enabledCategoryIds = Set(categories.map(\.id))
            persist()
        }
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
