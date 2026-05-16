import Foundation

struct CaptureObservation: Codable, Identifiable {
    let id: UUID
    let note: String
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    var category: String?

    enum CodingKeys: String, CodingKey {
        case id, note, latitude, longitude, timestamp, category
    }
}

struct SessionManifest: Codable {
    let id: String
    let startTime: Date
    var endTime: Date?
}
