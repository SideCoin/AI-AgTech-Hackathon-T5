import MWDATCamera
import MWDATCore
import Observation
import SwiftUI

enum StreamingStatus {
    case streaming
    case waiting
    case stopped
}

@Observable
@MainActor
final class GlassesStreamManager {
    private(set) var streamingStatus: StreamingStatus = .stopped
    private(set) var showError: Bool = false
    var errorMessage: String = ""
    var onPhotoCaptured: ((Data) -> Void)?

    var hasActiveDevice: Bool { sessionManager.hasActiveDevice }
    var isDeviceSessionReady: Bool { sessionManager.isReady }
    var isStreaming: Bool { streamingStatus != .stopped }

    private let sessionManager: DeviceSessionManager
    private let wearables: WearablesInterface
    private var stream: MWDATCamera.Stream?

    private var stateListenerToken: AnyListenerToken?
    private var errorListenerToken: AnyListenerToken?
    private var photoDataListenerToken: AnyListenerToken?

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.sessionManager = DeviceSessionManager(wearables: wearables)
    }

    func handleStartStreaming() async {
        let permission = Permission.camera
        do {
            var status = try await wearables.checkPermissionStatus(permission)
            if status != .granted {
                status = try await wearables.requestPermission(permission)
            }
            guard status == .granted else {
                showError("Camera permission denied")
                return
            }
            await startSession()
        } catch {
            showError("Permission error: \(error.localizedDescription)")
        }
    }

    func stopSession() async {
        guard let activeStream = stream else { return }
        stream = nil
        clearListeners()
        streamingStatus = .stopped
        await activeStream.stop()
    }

    func endSession() {
        stream = nil
        clearListeners()
        streamingStatus = .stopped
        sessionManager.cleanup()
    }

    func capturePhotoManually() {
        guard streamingStatus == .streaming else {
            showError("Cannot capture photo: streaming not active")
            return
        }
        let success = stream?.capturePhoto(format: .jpeg) ?? false
        if !success {
            showError("Failed to capture photo")
        }
    }

    func dismissError() {
        showError = false
        errorMessage = ""
    }

    // MARK: - Private

    private func startSession() async {
        let deviceSession: DeviceSession
        do {
            deviceSession = try await sessionManager.getSession()
        } catch {
            showError("Failed to start session: \(error.localizedDescription)")
            return
        }

        guard deviceSession.state == .started else {
            showError("Device session is not ready")
            return
        }

        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .low,
            frameRate: 24
        )

        guard let newStream = try? deviceSession.addStream(config: config) else {
            showError("Failed to add stream")
            return
        }

        stream = newStream
        streamingStatus = .waiting
        setupListeners(for: newStream)
        await newStream.start()
    }

    private func setupListeners(for stream: MWDATCamera.Stream) {
        stateListenerToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.handleStateChange(state) }
        }

        errorListenerToken = stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in self?.handleError(error) }
        }

        photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in self?.handlePhotoData(photoData) }
        }
    }

    private func clearListeners() {
        stateListenerToken = nil
        errorListenerToken = nil
        photoDataListenerToken = nil
    }

    private func handleStateChange(_ state: StreamState) {
        switch state {
        case .stopped:
            streamingStatus = .stopped
        case .waitingForDevice, .starting, .stopping, .paused:
            streamingStatus = .waiting
        case .streaming:
            streamingStatus = .streaming
        }
    }

    private func handleError(_ error: StreamError) {
        let message = error.localizedDescription
        if message != errorMessage {
            showError(message)
        }
    }

    private func handlePhotoData(_ data: PhotoData) {
        onPhotoCaptured?(data.data)
    }

    private func showError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
