import SwiftUI

struct SessionView: View {
    @Environment(\.dismiss) var dismiss
    var recordingSessionManager: RecordingSessionManager
    var captureCoordinator: CaptureCoordinator
    var streamManager: GlassesStreamManager

    var body: some View {
        ZStack {
            Color(.systemBackground).edgesIgnoringSafeArea(.all)

            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                            .opacity(0.8)

                        Text("Recording Session")
                            .font(.headline)

                        Spacer()
                    }

                    HStack {
                        Text("Observations captured:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("\(recordingSessionManager.observationCount)")
                            .font(.title2)
                            .fontWeight(.bold)

                        Spacer()
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)

                if captureCoordinator.isListeningForWakeWord {
                    HStack {
                        Image(systemName: "mic.circle.fill")
                            .font(.title3)
                            .foregroundColor(.purple)
                        Text("Listening for \"take a photo\"…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding()
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(8)
                }

                if captureCoordinator.isListeningForNote {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "waveform.circle.fill")
                                .font(.title)
                                .foregroundColor(.blue)
                                .animation(.easeInOut(duration: 0.6).repeatForever(), value: captureCoordinator.isListeningForNote)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Listening for note...")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                if !captureCoordinator.transcribedNote.isEmpty {
                                    Text(captureCoordinator.transcribedNote)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    }
                }

                if !streamManager.isStreaming && streamManager.hasActiveDevice {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)

                            Text("Camera stream not active. Tap the button below to start.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)

                        Button(action: {
                            Task {
                                await streamManager.handleStartStreaming()
                            }
                        }) {
                            HStack {
                                Image(systemName: "camera.fill")
                                Text("Start Camera Stream")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    }
                }

                Spacer()

                VStack(spacing: 12) {
                    Button(action: {
                        streamManager.capturePhotoManually()
                    }) {
                        HStack {
                            Image(systemName: "camera.circle.fill")
                            Text("Capture Photo (Manual)")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(!streamManager.isStreaming)
                    .opacity(streamManager.isStreaming ? 1 : 0.5)

                    Button(action: {
                        Task {
                            await streamManager.stopSession()
                            recordingSessionManager.endSession()
                            dismiss()
                        }
                    }) {
                        HStack {
                            Image(systemName: "stop.circle.fill")
                            Text("End Session")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }

                VStack(spacing: 8) {
                    Text("Session ID: \(recordingSessionManager.sessionID.prefix(8))...")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Device: \(streamManager.hasActiveDevice ? "Connected" : "Disconnected")")
                        .font(.caption)
                        .foregroundColor(streamManager.hasActiveDevice ? .green : .gray)
                }
                .padding(.top, 12)
            }
            .padding()
        }
        .onAppear {
            captureCoordinator.onVoiceTrigger = { [weak streamManager] in
                streamManager?.capturePhotoManually()
            }
            captureCoordinator.startWakeWordListening()
            Task {
                await streamManager.handleStartStreaming()
            }
        }
        .onDisappear {
            captureCoordinator.stopWakeWordListening()
            captureCoordinator.onVoiceTrigger = nil
        }
    }
}
