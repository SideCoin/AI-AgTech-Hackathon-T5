import MWDATCore
import Observation
import SwiftUI

@Observable
@MainActor
final class GlassesConnectionViewModel {
    var devices: [DeviceIdentifier]
    var registrationState: RegistrationState
    var showGettingStartedSheet: Bool = false
    var showError: Bool = false
    var errorMessage: String = ""

    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var deviceStreamTask: Task<Void, Never>?
    @ObservationIgnored private var setupDeviceStreamTask: Task<Void, Never>?
    private let wearables: WearablesInterface

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.devices = wearables.devices
        self.registrationState = wearables.registrationState

        setupDeviceStreamTask = Task { await setupDeviceStream() }

        registrationTask = Task {
            for await registrationState in wearables.registrationStateStream() {
                let previousState = self.registrationState
                self.registrationState = registrationState
                if self.showGettingStartedSheet == false && registrationState == .registered && previousState == .registering {
                    self.showGettingStartedSheet = true
                }
            }
        }
    }

    isolated deinit {
        registrationTask?.cancel()
        deviceStreamTask?.cancel()
        setupDeviceStreamTask?.cancel()
    }

    func connectGlasses() {
        guard registrationState != .registering else { return }
        Task { @MainActor in
            do {
                try await wearables.startRegistration()
            } catch let error as RegistrationError {
                showError(error.description)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func disconnectGlasses() {
        Task { @MainActor in
            do {
                try await wearables.startUnregistration()
            } catch let error as UnregistrationError {
                showError(error.description)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func showError(_ error: String) {
        errorMessage = error
        showError = true
    }

    func dismissError() {
        showError = false
    }

    // MARK: - Private

    private func setupDeviceStream() async {
        if let task = deviceStreamTask, !task.isCancelled { task.cancel() }
        deviceStreamTask = Task {
            for await devices in wearables.devicesStream() {
                self.devices = devices
            }
        }
    }
}
