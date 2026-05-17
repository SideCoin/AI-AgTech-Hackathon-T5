import Foundation

protocol ObservationStoreProtocol {
    func save(_ observation: CaptureObservation, photo: Data, to sessionID: String) throws
    func load(sessionID: String) throws -> [(observation: CaptureObservation, photoURL: URL)]
    func loadSessionManifest(sessionID: String) throws -> SessionManifest
    func saveSessionManifest(_ manifest: SessionManifest) throws
    func sessionDirectory(id: String) -> URL
    func listSessionManifests() throws -> [SessionManifest]
    func deleteSession(id: String) throws
    func deleteObservation(id: UUID, from sessionID: String) throws
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

    func deleteSession(id: String) throws {
        let dir = sessionDirectory(id: id)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.removeItem(at: dir)
    }

    func deleteObservation(id: UUID, from sessionID: String) throws {
        let dir = sessionDirectory(id: sessionID)
        let jsonURL = dir.appendingPathComponent("\(id.uuidString).json")
        let photoURL = dir.appendingPathComponent("\(id.uuidString).jpg")
        if fileManager.fileExists(atPath: jsonURL.path) {
            try fileManager.removeItem(at: jsonURL)
        }
        if fileManager.fileExists(atPath: photoURL.path) {
            try fileManager.removeItem(at: photoURL)
        }
    }

    /// Rewrites every observation whose `category` matches `oldId` so its category
    /// becomes `newId` (pass `nil` to mark them uncategorized).
    func reassignCategory(from oldId: String, to newId: String?) throws {
        let manifests = try listSessionManifests()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for manifest in manifests {
            let items = (try? load(sessionID: manifest.id)) ?? []
            for (obs, _) in items where obs.category == oldId {
                var updated = obs
                updated.category = newId
                let data = try encoder.encode(updated)
                let url = sessionDirectory(id: manifest.id)
                    .appendingPathComponent("\(obs.id.uuidString).json")
                try data.write(to: url)
            }
        }
    }

    func listSessionManifests() throws -> [SessionManifest] {
        let sessionsRoot = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions")
        guard fileManager.fileExists(atPath: sessionsRoot.path) else { return [] }

        let dirs = try fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var manifests: [SessionManifest] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestURL = dir.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(SessionManifest.self, from: data) else { continue }
            manifests.append(manifest)
        }

        return manifests.sorted { ($0.startTime) > ($1.startTime) }
    }
}
