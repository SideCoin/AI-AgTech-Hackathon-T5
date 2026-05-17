import XCTest
@testable import GlassesNotes

final class ObservationStoreTests: XCTestCase {
    var store: ObservationStore!
    let testSessionID = "test-session-123"

    override func setUp() {
        super.setUp()
        store = ObservationStore()
    }

    override func tearDown() {
        super.tearDown()
        let sessionDir = store.sessionDirectory(id: testSessionID)
        try? FileManager.default.removeItem(at: sessionDir)
    }

    func testSaveAndLoadObservation() throws {
        let observation = CaptureObservation(
            id: UUID(),
            note: "Test observation near field edge",
            latitude: 40.7128,
            longitude: -74.0060,
            timestamp: Date(),
            category: nil
        )
        let testPhotoData = "fake jpeg data".data(using: .utf8)!

        try store.save(observation, photo: testPhotoData, to: testSessionID)

        let loaded = try store.load(sessionID: testSessionID)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].observation.id, observation.id)
        XCTAssertEqual(loaded[0].observation.note, "Test observation near field edge")
        XCTAssertEqual(loaded[0].observation.latitude, 40.7128)

        let photoURL = loaded[0].photoURL
        let loadedPhoto = try Data(contentsOf: photoURL)
        XCTAssertEqual(loadedPhoto, testPhotoData)
    }

    func testSessionManifest() throws {
        let manifest = SessionManifest(id: testSessionID, startTime: Date(), endTime: nil)
        try store.saveSessionManifest(manifest)

        let loaded = try store.loadSessionManifest(sessionID: testSessionID)
        XCTAssertEqual(loaded.id, testSessionID)
        XCTAssertNil(loaded.endTime)
    }

    func testMultipleObservations() throws {
        let obs1 = CaptureObservation(
            id: UUID(),
            note: "First observation",
            latitude: 40.0,
            longitude: -74.0,
            timestamp: Date(),
            category: nil
        )
        let obs2 = CaptureObservation(
            id: UUID(),
            note: "Second observation",
            latitude: 41.0,
            longitude: -75.0,
            timestamp: Date().addingTimeInterval(60),
            category: nil
        )
        let photoData = "photo".data(using: .utf8)!

        try store.save(obs1, photo: photoData, to: testSessionID)
        try store.save(obs2, photo: photoData, to: testSessionID)

        let loaded = try store.load(sessionID: testSessionID)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.map { $0.observation.note }.contains("First observation"))
        XCTAssertTrue(loaded.map { $0.observation.note }.contains("Second observation"))
    }
}

@MainActor
final class RecordingSessionManagerTests: XCTestCase {
    var manager: RecordingSessionManager!
    var mockStore: MockObservationStore!

    override func setUp() {
        super.setUp()
        mockStore = MockObservationStore()
        manager = RecordingSessionManager(store: mockStore)
    }

    func testSessionLifecycle() {
        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(manager.observationCount, 0)

        manager.startSession()
        XCTAssertEqual(manager.state, .recording)
        XCTAssertNotEqual(manager.sessionID, "")

        manager.endSession()
        XCTAssertEqual(manager.state, .ended)
    }

    func testRecordObservation() {
        manager.startSession()

        let observation = CaptureObservation(
            id: UUID(),
            note: "Test note",
            latitude: 0,
            longitude: 0,
            timestamp: Date(),
            category: nil
        )
        let photoData = "photo".data(using: .utf8)!

        manager.recordObservation(observation, photo: photoData)
        XCTAssertEqual(manager.observationCount, 1)
        XCTAssertEqual(mockStore.savedObservations.count, 1)
    }

    func testCannotRecordWhenNotRecording() {
        let observation = CaptureObservation(
            id: UUID(),
            note: "Test",
            latitude: 0,
            longitude: 0,
            timestamp: Date(),
            category: nil
        )
        let photoData = "photo".data(using: .utf8)!

        manager.recordObservation(observation, photo: photoData)
        XCTAssertEqual(manager.observationCount, 0)
        XCTAssertEqual(mockStore.savedObservations.count, 0)
    }
}

// Mock implementation for testing
final class MockObservationStore: ObservationStoreProtocol {
    var savedObservations: [(observation: CaptureObservation, photo: Data)] = []

    func save(_ observation: CaptureObservation, photo: Data, to sessionID: String) throws {
        savedObservations.append((observation, photo))
    }

    func load(sessionID: String) throws -> [(observation: CaptureObservation, photoURL: URL)] {
        return []
    }

    func loadSessionManifest(sessionID: String) throws -> SessionManifest {
        return SessionManifest(id: sessionID, startTime: Date(), endTime: nil)
    }

    func saveSessionManifest(_ manifest: SessionManifest) throws {
    }

    func sessionDirectory(id: String) -> URL {
        return FileManager.default.temporaryDirectory
    }

    func listSessionManifests() throws -> [SessionManifest] {
        return []
    }
}
