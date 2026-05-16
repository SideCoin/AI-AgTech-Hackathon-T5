import Foundation

protocol ObservationStoreProtocol {
    func save(_ observation: CaptureObservation, photo: Data, to sessionID: String) throws
    func load(sessionID: String) throws -> [(observation: CaptureObservation, photoURL: URL)]
    func loadSessionManifest(sessionID: String) throws -> SessionManifest
    func saveSessionManifest(_ manifest: SessionManifest) throws
    func sessionDirectory(id: String) -> URL
}

final class ObservationStore: ObservationStoreProtocol {
    private let fileManager = FileManager.default

    func save(_ observation: CaptureObservation, photo: Data, to sessionID: String) throws {
        let sessionDir = sessionDirectory(id: sessionID)
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(observation)

        let jsonURL = sessionDir.appendingPathComponent("\(observation.id.uuidString).json")
        let photoURL = sessionDir.appendingPathComponent("\(observation.id.uuidString).jpg")

        try jsonData.write(to: jsonURL)
        try photo.write(to: photoURL)
    }

    func load(sessionID: String) throws -> [(observation: CaptureObservation, photoURL: URL)] {
        let sessionDir = sessionDirectory(id: sessionID)
        let files = try fileManager.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var results: [(CaptureObservation, URL)] = []
        for jsonFile in files where jsonFile.pathExtension == "json" && jsonFile.lastPathComponent != "categories.json" && jsonFile.lastPathComponent != "session.json" {
            let jsonData = try Data(contentsOf: jsonFile)
            let observation = try decoder.decode(CaptureObservation.self, from: jsonData)
            let photoURL = sessionDir.appendingPathComponent("\(observation.id.uuidString).jpg")
            results.append((observation, photoURL))
        }

        return results
    }

    func loadSessionManifest(sessionID: String) throws -> SessionManifest {
        let sessionDir = sessionDirectory(id: sessionID)
        let manifestURL = sessionDir.appendingPathComponent("session.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: manifestURL)
        return try decoder.decode(SessionManifest.self, from: data)
    }

    func saveSessionManifest(_ manifest: SessionManifest) throws {
        let sessionDir = sessionDirectory(id: manifest.id)
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        let manifestURL = sessionDir.appendingPathComponent("session.json")
        try data.write(to: manifestURL)
    }

    func sessionDirectory(id: String) -> URL {
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("sessions").appendingPathComponent(id)
    }
}
