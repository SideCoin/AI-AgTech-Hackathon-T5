import Foundation
import CoreLocation
import Speech
import Observation

@Observable
@MainActor
final class CaptureCoordinator: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum Mode {
        case idle
        case wakeWord
        case noteCapture
    }

    private(set) var isListeningForNote: Bool = false
    private(set) var isListeningForWakeWord: Bool = false
    private(set) var transcribedNote: String = ""
    private(set) var mode: Mode = .idle

    var onVoiceTrigger: (() -> Void)?

    private let locationManager = CLLocationManager()
    private let speechRecognizer: SFSpeechRecognizer?
    private let sessionManager: RecordingSessionManager

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var lastLocation: CLLocationCoordinate2D?
    private var captureTimestamp: Date = Date()

    private let triggerPhrases = ["take a photo", "take photo", "snap a photo"]
    private var wakeWordBuffer: String = ""

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

        stopWakeWordListening()

        captureTimestamp = Date()
        transcribedNote = ""
        lastLocation = locationManager.location?.coordinate

        startVoiceNoteCapture(photoData: photoData)
    }

    // MARK: - Wake-word listening

    func startWakeWordListening() {
        guard mode == .idle else { return }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request

        guard startAudioEngineTap(request: request) else { return }

        mode = .wakeWord
        isListeningForWakeWord = true
        wakeWordBuffer = ""

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString.lowercased()
                self.wakeWordBuffer = text
                if self.triggerPhrases.contains(where: { text.contains($0) }) {
                    self.handleWakeWordTriggered()
                }
            } else if error != nil {
                // Recognition died; restart if we're still in wake-word mode.
                if self.mode == .wakeWord {
                    self.stopWakeWordListening()
                    if self.sessionManager.state == .recording {
                        self.startWakeWordListening()
                    }
                }
            }
        }
    }

    func stopWakeWordListening() {
        guard mode == .wakeWord else { return }
        teardownAudioEngine()
        mode = .idle
        isListeningForWakeWord = false
        wakeWordBuffer = ""
    }

    private func handleWakeWordTriggered() {
        // Reset buffer so the same phrase can't fire twice; tear down listening
        // before invoking the trigger so the note-capture pass can claim the mic.
        wakeWordBuffer = ""
        stopWakeWordListening()
        onVoiceTrigger?()
    }

    // MARK: - Voice note capture

    private func startVoiceNoteCapture(photoData: Data) {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            finalizeCaptureWithNote("", photoData: photoData)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request

        guard startAudioEngineTap(request: request) else {
            finalizeCaptureWithNote("", photoData: photoData)
            return
        }

        mode = .noteCapture
        isListeningForNote = true

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
            guard let self = self, self.mode == .noteCapture else { return }
            self.stopVoiceNoteCapture(photoData: photoData)
        }
    }

    private func stopVoiceNoteCapture(photoData: Data) {
        guard mode == .noteCapture else { return }
        teardownAudioEngine()
        mode = .idle

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

        if sessionManager.state == .recording {
            startWakeWordListening()
        }
    }

    // MARK: - Shared audio engine helpers

    private func startAudioEngineTap(request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        // Fresh engine each time — reusing a stopped engine produces stale input-node state.
        audioEngine = AVAudioEngine()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return false
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // A zero sample rate means no audio hardware is available (e.g. simulator without mic).
        guard recordingFormat.sampleRate > 0 else { return false }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            return true
        } catch {
            inputNode.removeTap(onBus: 0)
            return false
        }
    }

    private func teardownAudioEngine() {
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager error: \(error)")
    }
}

import AVFoundation
