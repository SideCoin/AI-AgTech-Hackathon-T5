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
    private(set) var startTime: Date?

    private let store: ObservationStoreProtocol

    init(store: ObservationStoreProtocol = ObservationStore()) {
        self.store = store
    }

    var isRecording: Bool { state == .recording }

    func startSession() {
        let newSessionID = UUID().uuidString
        self.sessionID = newSessionID
        self.observationCount = 0
        self.startTime = Date()
        self.state = .recording
    }

    func endSession() {
        guard state == .recording else { return }
        state = .ended
        let sessionStart = startTime
        startTime = nil

        guard observationCount > 0, sessionStart != nil else { return }

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
            if observationCount == 0, let sessionStart = startTime {
                let manifest = SessionManifest(id: sessionID, startTime: sessionStart, endTime: nil)
                try store.saveSessionManifest(manifest)
            }
            try store.save(observation, photo: photo, to: sessionID)
            observationCount += 1
        } catch {
            assertionFailure("Failed to record observation: \(error)")
        }
    }
}
