// NOTE: Before running these tests, add MWDATMockDevice and MWDATMockDeviceTestClient
// to the GlassesNotesTests target in Xcode:
// Target → GlassesNotesTests → General → Frameworks and Libraries → +

import XCTest
import MWDATMockDevice
import MWDATCore
@testable import GlassesNotes

@MainActor
final class PhotoCaptureTests: XCTestCase {
    private var mockDevice: MockRaybanMeta!
    private var streamManager: GlassesStreamManager!

    override func setUp() async throws {
        try await super.setUp()

        // MockDeviceKit must be enabled before Wearables.configure() so it can
        // intercept device discovery. configure() is safe to call multiple times.
        MockDeviceKit.shared.enable()
        try? Wearables.configure()

        mockDevice = MockDeviceKit.shared.pairRaybanMeta()
        mockDevice.powerOn()
        mockDevice.unfold()
        mockDevice.don()

        let imageURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-photo", withExtension: "jpg"),
            "Add a test-photo.jpg to the GlassesNotesTests bundle"
        )
        let camera = mockDevice.services.camera
        // A video feed is required for the stream to reach .streaming state.
        // Re-use the JPEG as a static "feed" — MockDeviceKit accepts it for raw streams.
        camera.setCameraFeed(fileURL: imageURL)
        camera.setCapturedImage(fileURL: imageURL)

        streamManager = GlassesStreamManager(wearables: Wearables.shared)
    }

    override func tearDown() async throws {
        await streamManager.stopSession()
        streamManager = nil
        MockDeviceKit.shared.disable()
        mockDevice = nil
        try await super.tearDown()
    }

    func testPhotoCaptureDelivered() async throws {
        await streamManager.handleStartStreaming()

        // Wait for streaming state
        try await waitForStreaming()

        let expectation = expectation(description: "photo data received")
        var receivedData: Data?
        streamManager.onPhotoCaptured = { data in
            receivedData = data
            expectation.fulfill()
        }

        streamManager.capturePhotoManually()

        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertNotNil(receivedData, "Expected photo data from mock device")
    }

    func testCaptureFailsWhenNotStreaming() {
        // streamingStatus is .stopped — capture should set an error
        streamManager.capturePhotoManually()

        XCTAssertTrue(streamManager.showError)
        XCTAssertFalse(streamManager.errorMessage.isEmpty)
    }

    // MARK: - Helpers

    private func waitForStreaming(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while streamManager.streamingStatus != .streaming {
            if Date() > deadline {
                XCTFail("Stream did not reach .streaming state within \(timeout)s")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
