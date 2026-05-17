import MWDATCore
import Observation
import SwiftUI

/// Manages DeviceSession lifecycle with 1:1 device-to-session mapping.
/// Monitors device availability and creates sessions on demand via `getSession()`.
@Observable
@MainActor
final class DeviceSessionManager {
  private(set) var isReady: Bool = false
  private(set) var hasActiveDevice: Bool = false

  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceSession: DeviceSession?
  // nonisolated(unsafe) lets deinit cancel these tasks without main-actor isolation.
  @ObservationIgnored private nonisolated(unsafe) var deviceMonitorTask: Task<Void, Never>?
  @ObservationIgnored private nonisolated(unsafe) var stateObserverTask: Task<Void, Never>?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    startDeviceMonitoring()
  }

  deinit {
    // Tasks are nonisolated(unsafe), safe to cancel here.
    // deviceSession?.stop() is intentionally omitted — callers must invoke cleanup() first.
    deviceMonitorTask?.cancel()
    stateObserverTask?.cancel()
  }

  /// Stops the device session and cancels monitoring. Call before releasing.
  /// The stateObserverTask handles cleanup when .stopped arrives.
  func cleanup() {
    deviceMonitorTask?.cancel()
    deviceMonitorTask = nil
    deviceSession?.stop()
  }

  /// Returns a ready DeviceSession, creating one if needed.
  /// Waits for the session to reach .started state before returning.
  func getSession() async throws(DeviceSessionError) -> DeviceSession {
    if let session = deviceSession, session.state == .started {
      isReady = true
      return session
    }

    if deviceSession?.state == .stopped {
      deviceSession = nil
    }

    // Wait for an in-progress session to finish starting
    if let session = deviceSession {
      if session.state == .started {
        isReady = true
        startStateObserver(for: session)
        return session
      }

      try await waitForSessionStart(
        stateStream: session.stateStream(),
        errorStream: session.errorStream()
      )
      isReady = true
      startStateObserver(for: session)
      return session
    }

    // Wait for a device to be discoverable before creating a session
    try await waitForActiveDevice()

    // Create a new session
    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session

      let stateStream = session.stateStream()
      let errorStream = session.errorStream()
      try session.start()

      if session.state == .started {
        isReady = true
        startStateObserver(for: session)
        return session
      }

      try await waitForSessionStart(stateStream: stateStream, errorStream: errorStream)
      isReady = true
      startStateObserver(for: session)
      return session
    } catch {
      isReady = false
      deviceSession = nil
      throw error
    }
  }

  // MARK: - Private

  private func waitForActiveDevice(timeout: TimeInterval = 15) async throws(DeviceSessionError) {
    guard !hasActiveDevice else { return }
    let deadline = Date().addingTimeInterval(timeout)
    while !hasActiveDevice {
      if Date() > deadline {
        throw .unexpectedError(description: "No eligible device found. Make sure your glasses are on and Bluetooth is connected.")
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  private func waitForSessionStart(
    stateStream: AsyncStream<DeviceSessionState>,
    errorStream: AsyncStream<DeviceSessionError>
  ) async throws(DeviceSessionError) {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for await state in stateStream {
            if state == .started { return }
            if state == .stopped {
              throw DeviceSessionError.unexpectedError(description: "The session failed to start")
            }
          }
          guard !Task.isCancelled else { return }
          throw DeviceSessionError.unexpectedError(description: "The session failed to start")
        }

        group.addTask {
          for await error in errorStream {
            throw error
          }
          guard !Task.isCancelled else { return }
          throw DeviceSessionError.unexpectedError(description: "The session failed to start")
        }

        guard try await group.next() != nil else {
          throw DeviceSessionError.unexpectedError(description: "The session failed to start")
        }
        group.cancelAll()
      }
    } catch let error as DeviceSessionError {
      throw error
    } catch {
      throw .unexpectedError(description: error.localizedDescription)
    }
  }

  /// Monitors device availability only — does NOT create sessions.
  private func startDeviceMonitoring() {
    deviceMonitorTask = Task { [weak self] in
      guard let self else { return }
      for await device in deviceSelector.activeDeviceStream() {
        hasActiveDevice = device != nil
      }
    }
  }

  private func startStateObserver(for session: DeviceSession) {
    stateObserverTask?.cancel()
    stateObserverTask = Task { [weak self] in
      for await state in session.stateStream() {
        guard let self else { return }
        if state == .started {
          isReady = true
        } else if state == .stopped {
          isReady = false
          deviceSession = nil
          stateObserverTask = nil
          return
        }
      }
    }
  }
}
