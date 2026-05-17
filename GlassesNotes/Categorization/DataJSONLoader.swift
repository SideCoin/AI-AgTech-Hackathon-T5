// DataJSONLoader.swift
// Mirrors services/analysis/analysis/json_loader.py → iter_entries()
//
// Parses the iOS data.json format:
//   { "entries": [{ "id", "time", "latitude", "longitude", "notes", "imageBase64" }] }

import Foundation

struct LoadedEntry {
    let entryID:   String
    let timestamp: Date
    let latitude:  Double
    let longitude: Double
    let note:      String
    let imageName: String  // "<uuid-lowercase>.jpg"
    let imageData: Data?
}

enum DataJSONLoader {

    private struct DataFile: Decodable {
        let entries: [DataEntry]
    }

    private struct DataEntry: Decodable {
        let id:          String
        let time:        String
        let latitude:    Double
        let longitude:   Double
        let notes:       String?
        let imageBase64: String?

        enum CodingKeys: String, CodingKey {
            case id, time, latitude, longitude, notes
            case imageBase64 = "imageBase64"
        }
    }

    static func iterEntries(from url: URL) throws -> [LoadedEntry] {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(DataFile.self, from: data)

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        return file.entries.map { entry in
            let ts = isoFull.date(from: entry.time)
                  ?? isoBasic.date(from: entry.time)
                  ?? Date()

            let imgData: Data?
            if let b64 = entry.imageBase64, !b64.isEmpty, b64 != "..." {
                imgData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
            } else {
                imgData = nil
            }

            return LoadedEntry(
                entryID:   entry.id,
                timestamp: ts,
                latitude:  entry.latitude,
                longitude: entry.longitude,
                note:      entry.notes ?? "",
                imageName: "\(entry.id.lowercased()).jpg",
                imageData: imgData
            )
        }
    }
}
