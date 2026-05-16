import Foundation
import CoreLocation
import Speech
import Observation

@Observable
@MainActor
final class CaptureCoordinator: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var isListeningForNote: Bool = false
    private(set) var transcribedNote: String = ""

    private let locationManager = CLLocationManager()
    private let speechRecognizer: SFSpeechRecognizer?
    private let sessionManager: RecordingSessionManager

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var lastLocation: CLLocationCoordinate2D?
    private var captureTimestamp: Date = Date()

    init(sessionManager: RecordingSessionManager) {
        self.sessionManager = sessionManager
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()

        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()

        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                print("Speech recognition not authorized")
            }
        }
    }

    func handleCapturedPhoto(_ photoData: Data) {
        guard sessionManager.state == .recording else { return }

        captureTimestamp = Date()
        transcribedNote = ""
        lastLocation = locationManager.location?.coordinate

        startVoiceNoteCapture(photoData: photoData)
    }

    // MARK: - Private

    private func startVoiceNoteCapture(photoData: Data) {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            finalizeCaptureWithNote("", photoData: photoData)
            return
        }

        isListeningForNote = true

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        self.recognitionRequest = request

        guard let inputNode = audioEngine.inputNode as AVAudioInputNode? else {
            isListeningForNote = false
            finalizeCaptureWithNote("", photoData: photoData)
            return
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            isListeningForNote = false
            finalizeCaptureWithNote("", photoData: photoData)
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                self.transcribedNote = result.bestTranscription.formattedString
                if result.isFinal {
                    self.stopVoiceNoteCapture(photoData: photoData)
                }
            } else if let error = error as NSError?, error.code != NSURLErrorCancelled {
                self.stopVoiceNoteCapture(photoData: photoData)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.stopVoiceNoteCapture(photoData: photoData)
        }
    }

    private func stopVoiceNoteCapture(photoData: Data) {
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.finalizeCaptureWithNote(self?.transcribedNote ?? "", photoData: photoData)
        }
    }

    private func finalizeCaptureWithNote(_ note: String, photoData: Data) {
        isListeningForNote = false

        let observation = CaptureObservation(
            id: UUID(),
            note: note,
            latitude: lastLocation?.latitude ?? 0,
            longitude: lastLocation?.longitude ?? 0,
            timestamp: captureTimestamp,
            category: nil
        )

        sessionManager.recordObservation(observation, photo: photoData)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager error: \(error)")
    }
}

import AVFoundation
