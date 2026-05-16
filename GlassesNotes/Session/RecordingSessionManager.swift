import Foundation
import Observation

enum RecordingState {
    case idle
    case recording
    case ended
}

@Observable
@MainActor
final class RecordingSessionManager {
    private(set) var state: RecordingState = .idle
    private(set) var sessionID: String = ""
    private(set) var observationCount: Int = 0

    private let store: ObservationStoreProtocol

    init(store: ObservationStoreProtocol = ObservationStore()) {
        self.store = store
    }

    func startSession() {
        let newSessionID = UUID().uuidString
        self.sessionID = newSessionID
        self.observationCount = 0
        self.state = .recording

        let manifest = SessionManifest(id: newSessionID, startTime: Date(), endTime: nil)
        do {
            try store.saveSessionManifest(manifest)
        } catch {
            assertionFailure("Failed to save session manifest: \(error)")
        }
    }

    func endSession() {
        guard state == .recording else { return }
        state = .ended

        do {
            var manifest = try store.loadSessionManifest(sessionID: sessionID)
            manifest.endTime = Date()
            try store.saveSessionManifest(manifest)
        } catch {
            assertionFailure("Failed to update session manifest: \(error)")
        }
    }

    func recordObservation(_ observation: CaptureObservation, photo: Data) {
        guard state == .recording else { return }

        do {
            try store.save(observation, photo: photo, to: sessionID)
            observationCount += 1
        } catch {
            assertionFailure("Failed to record observation: \(error)")
        }
    }
}
