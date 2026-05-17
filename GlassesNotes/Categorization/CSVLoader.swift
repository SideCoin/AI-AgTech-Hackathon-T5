// CSVLoader.swift
// Mirrors services/analysis/analysis/csv_loader.py → iter_rows()
//
// Parses a flat CSV file into CSVRow values for per-row analysis.
// Expected columns: id, time, gps_lat, gps_lng, note, jpg_name
// Time format:      M/d/yyyy H:mm  (e.g. "5/16/2026 6:35")

import Foundation

// MARK: - CSVRow

/// One parsed row from the input CSV — mirrors the tuple yielded by iter_rows().
struct CSVRow {
    let csvID: String
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let note: String
    let jpgName: String
    let jpgURL: URL?       // resolved path; nil if the file doesn't exist
}

// MARK: - CSVLoader

enum CSVLoader {

    enum CSVError: Error, LocalizedError {
        case fileNotReadable(URL)
        case missingHeader([String])
        case badRow(Int, String)

        var errorDescription: String? {
            switch self {
            case .fileNotReadable(let url):   return "Cannot read CSV at \(url.path)"
            case .missingHeader(let cols):    return "CSV missing required columns: \(cols.joined(separator: ", "))"
            case .badRow(let line, let msg):  return "CSV row \(line): \(msg)"
            }
        }
    }

    private static let requiredColumns = ["id", "time", "gps_lat", "gps_lng", "note", "jpg_name"]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat  = "M/d/yyyy H:mm"
        f.timeZone    = TimeZone(identifier: "UTC")
        f.locale      = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Parse all rows from a CSV file.
    /// Mirrors `iter_rows(csv_path, jpg_dir)` in csv_loader.py.
    ///
    /// - Parameters:
    ///   - csvURL:  URL of the CSV file.
    ///   - jpgDir:  Directory that contains the JPG images named in `jpg_name`.
    /// - Returns:   Array of CSVRow in file order.
    static func iterRows(csvURL: URL, jpgDir: URL) throws -> [CSVRow] {
        guard let raw = try? String(contentsOf: csvURL, encoding: .utf8) else {
            throw CSVError.fileNotReadable(csvURL)
        }

        var lines = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        // Parse header
        let headers = parseFields(lines.removeFirst())
        let headerIndex = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1, $0) })

        let missing = requiredColumns.filter { headerIndex[$0] == nil }
        if !missing.isEmpty { throw CSVError.missingHeader(missing) }

        let idIdx   = headerIndex["id"]!
        let timeIdx = headerIndex["time"]!
        let latIdx  = headerIndex["gps_lat"]!
        let lngIdx  = headerIndex["gps_lng"]!
        let noteIdx = headerIndex["note"]!
        let imgIdx  = headerIndex["jpg_name"]!

        var rows: [CSVRow] = []

        for (lineNumber, line) in lines.enumerated() {
            let fields = parseFields(line)
            guard fields.count > max(idIdx, timeIdx, latIdx, lngIdx, noteIdx, imgIdx) else {
                throw CSVError.badRow(lineNumber + 2, "not enough columns")
            }

            guard let ts = dateFormatter.date(from: fields[timeIdx]) else {
                throw CSVError.badRow(lineNumber + 2, "invalid time '\(fields[timeIdx])'")
            }
            guard let lat = Double(fields[latIdx]) else {
                throw CSVError.badRow(lineNumber + 2, "invalid latitude '\(fields[latIdx])'")
            }
            guard let lng = Double(fields[lngIdx]) else {
                throw CSVError.badRow(lineNumber + 2, "invalid longitude '\(fields[lngIdx])'")
            }

            let jpgName = fields[imgIdx].trimmingCharacters(in: .whitespaces)
            let jpgURL: URL? = jpgName.isEmpty ? nil : {
                let candidate = jpgDir.appendingPathComponent(jpgName)
                return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
            }()

            rows.append(CSVRow(
                csvID:     fields[idIdx],
                timestamp: ts,
                latitude:  lat,
                longitude: lng,
                note:      fields[noteIdx],
                jpgName:   jpgName,
                jpgURL:    jpgURL
            ))
        }

        return rows
    }

    // MARK: - CSV field parser (handles double-quoted fields with embedded commas)

    private static func parseFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            switch char {
            case "\"":
                inQuotes.toggle()
            case "," where !inQuotes:
                fields.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }
}
