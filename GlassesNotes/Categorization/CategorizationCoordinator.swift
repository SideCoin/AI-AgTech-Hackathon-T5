// CategorizationCoordinator.swift
// Orchestrates the two-phase categorization flow:
//   • processCapture(...) — per photo: write image_report into the obs JSON
//   • processSessionEnd(...) — per session: batch-assign category labels,
//     auto-mint new categories only when ≥2 observations share the label.
//
// Both phases bump `refreshToken` after disk writes so MapView re-renders.
// `isAnalyzingImage` / `isCategorizingSession` are read by SessionLiveBanner.

import Foundation
import Observation

@Observable
@MainActor
final class CategorizationCoordinator {

    // Read by SwiftUI views; mutating triggers re-render.
    private(set) var isAnalyzingImage: Bool = false
    private(set) var isCategorizingSession: Bool = false
    private(set) var refreshToken: Int = 0

    private let imageService: ImageAnalysisService?
    private let sessionService: SessionCategorizationService?
    private let store: ObservationStore
    private let categoryStore: CategoryStore

    private var inflightImageCount: Int = 0
    private let minCountForNewCategory: Int = 2

    init(categoryStore: CategoryStore, store: ObservationStore = ObservationStore()) {
        self.categoryStore = categoryStore
        self.store = store

        if let key = Secrets.get(.openAI) {
            self.imageService = ImageAnalysisService(apiKey: key)
            self.sessionService = SessionCategorizationService(apiKey: key)
            let keyPreview = key.count > 8 ? "\(key.prefix(4))…\(key.suffix(4))" : "(short)"
            print("[Categorization] init: enabled (model=gpt-5.1, key=\(keyPreview))")
        } else {
            print("[Categorization] init: OPENAI_API_KEY not set — categorization disabled (all process* calls will no-op)")
            self.imageService = nil
            self.sessionService = nil
        }
    }

    /// Bumps `refreshToken` so MapView reloads pins + recomputes category
    /// counts. Used by non-categorization callers (e.g. DataView after the
    /// user deletes a session) to keep the map in sync with disk.
    func notifyDataChanged() {
        refreshToken &+= 1
    }

    // MARK: - Per-capture

    /// Called from CaptureCoordinator right after an observation is persisted.
    /// Loads the JPEG from disk, asks gpt-5.1 for an image_report, and writes
    /// it back into the observation JSON.
    func processCapture(observationID: UUID, sessionID: String) async {
        guard let imageService else {
            print("[Categorization] processCapture: skipped (no API key) obs=\(observationID.uuidString.prefix(8)) session=\(sessionID.prefix(8))")
            return
        }

        let started = Date()
        inflightImageCount += 1
        isAnalyzingImage = true
        print("[Categorization] processCapture: START obs=\(observationID.uuidString.prefix(8)) session=\(sessionID.prefix(8)) inflight=\(inflightImageCount)")
        defer {
            inflightImageCount -= 1
            if inflightImageCount <= 0 {
                inflightImageCount = 0
                isAnalyzingImage = false
            }
            print("[Categorization] processCapture: END   obs=\(observationID.uuidString.prefix(8)) elapsed=\(elapsedMs(since: started))ms inflight=\(inflightImageCount)")
        }

        let dir = store.sessionDirectory(id: sessionID)
        let jsonURL = dir.appendingPathComponent("\(observationID.uuidString).json")
        let photoURL = dir.appendingPathComponent("\(observationID.uuidString).jpg")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let jsonData: Data
        let photoData: Data
        var observation: CaptureObservation
        do {
            jsonData = try Data(contentsOf: jsonURL)
        } catch {
            print("[Categorization] processCapture: cannot read JSON at \(jsonURL.path): \(error)")
            return
        }
        do {
            observation = try decoder.decode(CaptureObservation.self, from: jsonData)
        } catch {
            print("[Categorization] processCapture: cannot decode obs JSON for \(observationID.uuidString.prefix(8)): \(error)")
            return
        }
        do {
            photoData = try Data(contentsOf: photoURL)
        } catch {
            print("[Categorization] processCapture: cannot read photo at \(photoURL.path): \(error)")
            return
        }
        print("[Categorization] processCapture: loaded obs (note=\"\(observation.note.prefix(60))\(observation.note.count > 60 ? "…" : "")\") + photo (\(photoData.count) bytes)")

        let report = await callWithRetry {
            try await imageService.summarize(note: observation.note, photoJPEG: photoData)
        }
        guard let report else {
            print("[Categorization] processCapture: bailed for \(observationID.uuidString.prefix(8)) — image_report left nil")
            return
        }

        observation.imageReport = report
        do {
            try store.updateObservation(observation, in: sessionID)
            refreshToken &+= 1
            print("[Categorization] processCapture: wrote image_report for \(observationID.uuidString.prefix(8)) → refreshToken=\(refreshToken)")
        } catch {
            print("[Categorization] processCapture: failed to write JSON for \(observationID.uuidString.prefix(8)): \(error)")
        }
    }

    // MARK: - Per-session

    /// Called from RecordingSessionManager.endSession (or ContentView's
    /// endRecordingFlow) once the manifest's endTime has been written.
    func processSessionEnd(sessionID: String) async {
        guard let sessionService else {
            print("[Categorization] processSessionEnd: skipped (no API key) session=\(sessionID.prefix(8))")
            return
        }

        let started = Date()
        print("[Categorization] processSessionEnd: START session=\(sessionID.prefix(8))")

        let loaded: [(CaptureObservation, URL)]
        do {
            loaded = try store.load(sessionID: sessionID)
        } catch {
            print("[Categorization] processSessionEnd: load failed for session=\(sessionID.prefix(8)): \(error)")
            return
        }
        guard !loaded.isEmpty else {
            print("[Categorization] processSessionEnd: no observations in session=\(sessionID.prefix(8)) — nothing to do")
            return
        }
        let withReport = loaded.filter { $0.0.imageReport != nil }.count
        print("[Categorization] processSessionEnd: loaded \(loaded.count) observation(s) (\(withReport) with image_report)")

        isCategorizingSession = true
        defer {
            isCategorizingSession = false
            print("[Categorization] processSessionEnd: END   session=\(sessionID.prefix(8)) elapsed=\(elapsedMs(since: started))ms")
        }

        let rows = loaded.map { (obs, _) in
            SessionCategorizationService.Row(
                id: obs.id,
                note: obs.note,
                imageReport: obs.imageReport
            )
        }
        let existingNames = categoryStore.categories
            .filter { !$0.isUncategorized }
            .map(\.name)

        let assignments = await callWithRetry {
            try await sessionService.categorize(rows: rows, existingCategories: existingNames)
        }
        guard let assignments else {
            print("[Categorization] processSessionEnd: bailed (both attempts failed), leaving observations uncategorized")
            return
        }

        // Count how many obs each proposed label got, so we can suppress
        // singletons that aren't already known categories.
        var labelCounts: [String: Int] = [:]
        for label in assignments.values { labelCounts[label, default: 0] += 1 }
        print("[Categorization] label counts: \(labelCounts.map { "\"\($0.key)\"×\($0.value)" }.joined(separator: ", "))")

        // Resolve each label to a category id. Singletons that don't match
        // an existing category resolve to nil (treated as Uncategorized).
        var labelToCategoryID: [String: String] = [:]
        for (label, count) in labelCounts {
            if let existing = categoryStore.category(named: label) {
                labelToCategoryID[label] = existing.id
                print("[Categorization] resolved \"\(label)\" → existing category id=\(existing.id.prefix(8)) name=\"\(existing.name)\"")
                continue
            }
            if count >= minCountForNewCategory {
                let usedHex = Set(categoryStore.categories.map { $0.colorHex.lowercased() })
                let color = CategoryPalette.nextColor(usedHex: usedHex)
                // Title-case the LLM's lowercase label for display.
                let displayName = label.capitalized
                let new = categoryStore.upsertCategory(name: displayName, colorHex: color)
                labelToCategoryID[label] = new.id
                print("[Categorization] minted new category \"\(displayName)\" id=\(new.id.prefix(8)) color=\(color) count=\(count)")
            } else {
                print("[Categorization] suppressed singleton label \"\(label)\" (count=\(count) < \(minCountForNewCategory)) — those obs stay uncategorized")
            }
        }

        // Write each observation's new category back to disk, and bump
        // category counts. Observations whose label didn't resolve to a
        // category id are left as-is (Uncategorized).
        var writeCount = 0
        var skippedNoChange = 0
        var skippedUncategorized = 0
        for (obs, _) in loaded {
            let shortID = obs.id.uuidString.prefix(8)
            guard let label = assignments[obs.id] else {
                print("[Categorization]   obs \(shortID) → no assignment from LLM (uncategorized)")
                skippedUncategorized += 1
                continue
            }
            guard let newID = labelToCategoryID[label] else {
                print("[Categorization]   obs \(shortID) → label \"\(label)\" not resolved (uncategorized)")
                skippedUncategorized += 1
                continue
            }
            if obs.category == newID {
                print("[Categorization]   obs \(shortID) → \"\(label)\" already set, skipping write")
                skippedNoChange += 1
                continue
            }
            var updated = obs
            updated.category = newID
            do {
                try store.updateObservation(updated, in: sessionID)
                categoryStore.incrementCount(for: newID)
                writeCount += 1
                print("[Categorization]   obs \(shortID) → \"\(label)\" (catID=\(newID.prefix(8))) ✓ written")
            } catch {
                print("[Categorization]   obs \(shortID) → write FAILED: \(error)")
            }
        }
        print("[Categorization] session done — wrote=\(writeCount) skippedNoChange=\(skippedNoChange) uncategorized=\(skippedUncategorized) labelsResolved=\(labelToCategoryID.count)")
        refreshToken &+= 1
        print("[Categorization] refreshToken bumped → \(refreshToken)")
    }

    // MARK: - Retry helper

    /// Runs `work` once; on throw, waits 2s and runs it again. If the second
    /// attempt also throws, returns nil (caller decides graceful fallback).
    private func callWithRetry<T>(_ work: () async throws -> T) async -> T? {
        let started = Date()
        do {
            let result = try await work()
            print("[Categorization] callWithRetry: attempt 1 succeeded in \(elapsedMs(since: started))ms")
            return result
        } catch {
            print("[Categorization] callWithRetry: attempt 1 FAILED after \(elapsedMs(since: started))ms: \(error) — retrying in 2s")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let secondStart = Date()
        do {
            let result = try await work()
            print("[Categorization] callWithRetry: attempt 2 succeeded in \(elapsedMs(since: secondStart))ms")
            return result
        } catch {
            print("[Categorization] callWithRetry: attempt 2 FAILED after \(elapsedMs(since: secondStart))ms: \(error) — giving up")
            return nil
        }
    }

    private func elapsedMs(since: Date) -> Int {
        Int(Date().timeIntervalSince(since) * 1000)
    }
}
