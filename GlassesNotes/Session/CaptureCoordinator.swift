import Foundation
import CoreLocation
import Speech
import UIKit
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
    private(set) var audioLevel: Float = 0

    var isAudioActive: Bool { mode == .noteCapture }

    var showPhoneCamera: Bool = false
    var triggerPhoneCapture: Bool = false

    var onVoiceTrigger: (() -> Void)?
    var onStartSessionVoice: (() -> Void)?
    var onEndSessionVoice: (() -> Void)?

    private let locationManager = CLLocationManager()
    private let speechRecognizer: SFSpeechRecognizer?
    private let sessionManager: RecordingSessionManager
    var categorizationCoordinator: CategorizationCoordinator?

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var lastLocation: CLLocationCoordinate2D?
    private var captureTimestamp: Date = Date()

    private let photoPhrases = ["take a photo", "take photo", "snap a photo", "open camera", "camera"]
    private let startSessionPhrases = ["start session"]
    private let endSessionPhrases = ["end session"]
    private let endNotePhrase = "end note"
    private let noteSilenceTimeout: TimeInterval = 3.0
    private var wakeWordBuffer: String = ""
    private var lastNoteTranscript: String = ""
    private var silenceWorkItem: DispatchWorkItem?

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

        print("[wake] init auth=\(SFSpeechRecognizer.authorizationStatus().rawValue) recognizerLocale=\(speechRecognizer?.locale.identifier ?? "nil") available=\(speechRecognizer?.isAvailable ?? false)")
    }

    func handleCapturedPhoto(_ photoData: Data) {
        print("[voice-note] handleCapturedPhoto bytes=\(photoData.count) sessionState=\(sessionManager.state) mode=\(mode)")
        guard sessionManager.state == .recording else {
            print("[voice-note] session not recording — dropping photo")
            return
        }

        stopWakeWordListening()

        captureTimestamp = Date()
        transcribedNote = ""
        lastLocation = locationManager.location?.coordinate

        startVoiceNoteCapture(photoData: photoData)
    }

    // MARK: - iPhone-camera capture entry points

    func beginPhoneCameraCapture() {
        guard sessionManager.state == .recording else { return }
        stopWakeWordListening()
        showPhoneCamera = true
        triggerPhoneCapture = true
    }

    func handlePhoneCapturedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.5) else { return }
        handleCapturedPhoto(data)
    }

    // MARK: - Wake-word listening

    func startWakeWordListening() {
        guard mode == .idle else {
            print("[wake] startWakeWordListening skip — mode=\(mode)")
            return
        }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("[wake] startWakeWordListening skip — recognizer=\(String(describing: speechRecognizer)) available=\(speechRecognizer?.isAvailable ?? false)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request

        guard startAudioEngineTap(request: request) else {
            print("[wake] startAudioEngineTap returned false")
            return
        }

        mode = .wakeWord
        isListeningForWakeWord = true
        wakeWordBuffer = ""
        print("[wake] listening started")

        attachWakeRecognitionTask(recognizer: recognizer, request: request)
    }

    private func attachWakeRecognitionTask(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest) {
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            // Late callback from a recognition task we already replaced — ignore.
            guard self.mode == .wakeWord, self.recognitionRequest === request else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString.lowercased()
                self.wakeWordBuffer = text
                print("[wake] heard=\"\(text)\" sessionState=\(self.sessionManager.state) hasHandler=\(self.onVoiceTrigger != nil)")
                self.dispatchWakeWord(in: text)
            } else if let error = error {
                print("[wake] recognizer error: \(error.localizedDescription) mode=\(self.mode) — swapping task, keeping mic")
                self.swapWakeRecognitionTask()
            }
        }
    }

    // Swap the SFSpeechRecognitionTask (and its backing request) without tearing down the audio
    // engine. The on-device recognizer ends a task after a brief silence with "No speech
    // detected"; if we restart the whole engine on each cycle we lose ~1s of mic frames and miss
    // the user's next command. Keeping the tap alive lets the new task start with continuous audio.
    private func swapWakeRecognitionTask() {
        guard mode == .wakeWord, let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request
        wakeWordBuffer = ""
        attachWakeRecognitionTask(recognizer: recognizer, request: request)
    }

    private func dispatchWakeWord(in text: String) {
        if sessionManager.state == .recording {
            if endSessionPhrases.contains(where: { text.contains($0) }) {
                print("[wake] dispatch — end-session phrase matched")
                handleEndSessionTriggered()
            } else if photoPhrases.contains(where: { text.contains($0) }) {
                print("[wake] dispatch — photo phrase matched")
                handleWakeWordTriggered()
            }
        } else {
            if startSessionPhrases.contains(where: { text.contains($0) }) {
                print("[wake] dispatch — start-session phrase matched")
                handleStartSessionTriggered()
            } else if photoPhrases.contains(where: { text.contains($0) }) {
                print("[wake] dispatch — photo phrase heard but IGNORED (session not recording, say \"start session\" first)")
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
        // No explicit snap sound — UIImagePickerController.takePicture() plays the
        // system shutter when the phone camera fires, so adding our own here doubles it up.
        wakeWordBuffer = ""
        stopWakeWordListening()
        print("[wake] firing onVoiceTrigger (handler=\(onVoiceTrigger != nil ? "set" : "NIL"))")
        onVoiceTrigger?()
    }

    private func handleStartSessionTriggered() {
        wakeWordBuffer = ""
        stopWakeWordListening()
        playRecordStartSound()
        onStartSessionVoice?()
    }

    private func handleEndSessionTriggered() {
        wakeWordBuffer = ""
        stopWakeWordListening()
        playRecordEndSound()
        onEndSessionVoice?()
    }

    // MARK: - Always-on listening bootstrap

    func startAlwaysOnListening() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { return }
            Task { @MainActor in
                self?.startWakeWordListening()
            }
        }
    }

    // MARK: - Voice note capture

    private func startVoiceNoteCapture(photoData: Data) {
        print("[voice-note] begin, photoData bytes=\(photoData.count)")

        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("[voice-note] recognizer unavailable (recognizer=\(String(describing: speechRecognizer)) available=\(speechRecognizer?.isAvailable ?? false)) — finalizing empty")
            finalizeCaptureWithNote("", photoData: photoData)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request

        guard startAudioEngineTap(request: request) else {
            print("[voice-note] startAudioEngineTap returned false — finalizing empty")
            finalizeCaptureWithNote("", photoData: photoData)
            return
        }

        mode = .noteCapture
        isListeningForNote = true
        lastNoteTranscript = ""
        playRecordStartSound()
        print("[voice-note] mode=noteCapture, awaiting partial results")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            // Once we've left noteCapture (silence-timer / explicit stop / end-note phrase),
            // ignore late callbacks. SFSpeechRecognitionTask still emits one isFinal=true
            // with an empty transcript after cancellation, which would otherwise clobber
            // the captured note.
            guard self.mode == .noteCapture else {
                print("[voice-note] late callback ignored, mode=\(self.mode)")
                return
            }
            if let result = result {
                let raw = result.bestTranscription.formattedString
                let lowered = raw.lowercased()
                print("[voice-note] partial=\"\(raw)\" isFinal=\(result.isFinal)")

                if lowered.contains(self.endNotePhrase) {
                    let cleaned = raw.replacingOccurrences(
                        of: self.endNotePhrase,
                        with: "",
                        options: .caseInsensitive
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    print("[voice-note] end-note phrase detected, cleaned=\"\(cleaned)\"")
                    self.transcribedNote = cleaned
                    self.cancelSilenceTimer()
                    self.playRecordEndSound()
                    self.stopVoiceNoteCapture(photoData: photoData)
                    return
                }

                if raw != self.lastNoteTranscript {
                    self.lastNoteTranscript = raw
                    self.transcribedNote = raw
                    self.scheduleSilenceTimer(photoData: photoData)
                }

                if result.isFinal {
                    print("[voice-note] result.isFinal — stopping")
                    self.cancelSilenceTimer()
                    self.stopVoiceNoteCapture(photoData: photoData)
                }
            } else if let error = error as NSError? {
                if error.code == NSURLErrorCancelled {
                    print("[voice-note] recognizer cancelled (expected on stop)")
                } else {
                    print("[voice-note] recognizer error code=\(error.code) domain=\(error.domain) desc=\(error.localizedDescription)")
                    self.cancelSilenceTimer()
                    self.stopVoiceNoteCapture(photoData: photoData)
                }
            }
        }

        // Start silence countdown immediately — if the user never speaks, finalize after the timeout.
        scheduleSilenceTimer(photoData: photoData)

        // Safety timeout — frees the mic if the silence timer somehow never fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60.0) { [weak self] in
            guard let self = self, self.mode == .noteCapture else { return }
            print("[voice-note] 60s safety timeout fired — forcing stop")
            self.stopVoiceNoteCapture(photoData: photoData)
        }
    }

    private func scheduleSilenceTimer(photoData: Data) {
        silenceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.mode == .noteCapture else {
                print("[voice-note] silence timer fired but mode=\(String(describing: self?.mode)) — ignoring")
                return
            }
            print("[voice-note] silence timer fired, transcribedNote=\"\(self.transcribedNote)\" audioLevel=\(self.audioLevel)")
            self.playRecordEndSound()
            self.stopVoiceNoteCapture(photoData: photoData)
        }
        silenceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + noteSilenceTimeout, execute: item)
    }

    private func cancelSilenceTimer() {
        silenceWorkItem?.cancel()
        silenceWorkItem = nil
    }

    private func stopVoiceNoteCapture(photoData: Data) {
        guard mode == .noteCapture else {
            print("[voice-note] stopVoiceNoteCapture called but mode=\(mode) — skipping")
            return
        }
        // Snapshot the note before teardown — once we flip mode to .idle, the recognizer
        // may still deliver a final empty callback. The guard in the recognition handler
        // protects against mutation, but capturing here removes the dependency entirely.
        let capturedNote = transcribedNote
        print("[voice-note] stopVoiceNoteCapture, transcribedNote=\"\(capturedNote)\"")
        cancelSilenceTimer()
        teardownAudioEngine()
        mode = .idle

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.finalizeCaptureWithNote(capturedNote, photoData: photoData)
        }
    }

    private func finalizeCaptureWithNote(_ note: String, photoData: Data) {
        print("[voice-note] finalize note=\"\(note)\" length=\(note.count)")
        isListeningForNote = false

        let observation = CaptureObservation(
            id: UUID(),
            note: note,
            latitude: lastLocation?.latitude ?? 0,
            longitude: lastLocation?.longitude ?? 0,
            timestamp: captureTimestamp,
            category: Category.uncategorizedID
        )

        sessionManager.recordObservation(observation, photo: photoData)

        if let coordinator = categorizationCoordinator {
            let obsID = observation.id
            let sessionID = sessionManager.sessionID
            Task { await coordinator.processCapture(observationID: obsID, sessionID: sessionID) }
        }

        startWakeWordListening()
    }

    // MARK: - System sound cues

    private func playRecordStartSound() {
        AudioServicesPlaySystemSound(1113)
    }

    private func playRecordEndSound() {
        AudioServicesPlaySystemSound(1114)
    }

    // MARK: - Shared audio engine helpers

    private func startAudioEngineTap(request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        // Fresh engine each time — reusing a stopped engine produces stale input-node state.
        audioEngine = AVAudioEngine()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print("[voice-note] audio session active, sampleRate=\(session.sampleRate) inputChannels=\(session.inputNumberOfChannels)")
        } catch {
            print("[voice-note] audio session setup threw: \(error)")
            return false
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        print("[voice-note] inputNode format sampleRate=\(recordingFormat.sampleRate) channels=\(recordingFormat.channelCount)")

        // A zero sample rate means no audio hardware is available (e.g. simulator without mic).
        guard recordingFormat.sampleRate > 0 else {
            print("[voice-note] zero sample rate — bailing")
            return false
        }

        // Forward to whatever the current recognitionRequest is, not the one captured at install
        // time — this lets us swap recognition tasks (e.g. on wake-word silence timeout) without
        // tearing down the mic, so we don't drop the user's next utterance.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            var sumSquares: Float = 0
            for i in 0..<frameCount {
                let sample = channelData[i]
                sumSquares += sample * sample
            }
            let rms = sqrtf(sumSquares / Float(frameCount))
            let normalized = min(1.0, max(0.0, rms * 8.0))
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.audioLevel = self.audioLevel * 0.6 + normalized * 0.4
            }
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            print("[voice-note] audioEngine started")
            return true
        } catch {
            print("[voice-note] audioEngine.start threw: \(error)")
            inputNode.removeTap(onBus: 0)
            return false
        }
    }

    private func teardownAudioEngine() {
        audioLevel = 0
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
import AudioToolbox
