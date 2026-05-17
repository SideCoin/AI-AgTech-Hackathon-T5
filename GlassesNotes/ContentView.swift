//
//  ContentView.swift
//  GlassesNotes
//

import MWDATCore
import SwiftUI

struct ContentView: View {
    @State private var connectionViewModel: GlassesConnectionViewModel?
    @State private var streamManager: GlassesStreamManager?
    @State private var recordingSessionManager = RecordingSessionManager()
    @State private var captureCoordinator: CaptureCoordinator?
    @State private var categoryStore = CategoryStore()
    @State private var selectedTab = 0

    private var isRecording: Bool { recordingSessionManager.isRecording }

    var body: some View {
        Group {
            if let connectionViewModel {
                mainTabView(connectionViewModel: connectionViewModel)
            } else {
                ProgressView("Initializing...")
                    .onAppear { setup() }
            }
        }
    }

    // MARK: - Setup

    private func setup() {
        connectionViewModel = GlassesConnectionViewModel(wearables: Wearables.shared)
        streamManager = GlassesStreamManager(wearables: Wearables.shared)
        captureCoordinator = CaptureCoordinator(sessionManager: recordingSessionManager)

        if let streamManager, let captureCoordinator {
            streamManager.onPhotoCaptured = { photoData in
                captureCoordinator.handleCapturedPhoto(photoData)
            }
            captureCoordinator.onVoiceTrigger = { [weak captureCoordinator] in
                captureCoordinator?.beginPhoneCameraCapture()
            }
            captureCoordinator.onStartSessionVoice = {
                if !recordingSessionManager.isRecording {
                    startRecordingFlow()
                }
            }
            captureCoordinator.onEndSessionVoice = {
                if recordingSessionManager.isRecording {
                    endRecordingFlow()
                }
            }
            captureCoordinator.startAlwaysOnListening()
        }
    }

    private func startRecordingFlow() {
        recordingSessionManager.startSession()
        captureCoordinator?.startWakeWordListening()
        Task { await streamManager?.handleStartStreaming() }
    }

    private func endRecordingFlow() {
        Task {
            await streamManager?.stopSession()
            recordingSessionManager.endSession()
        }
    }

    // MARK: - Main layout

    private func mainTabView(connectionViewModel: GlassesConnectionViewModel) -> some View {
        Group {
            if selectedTab == 0, let captureCoordinator {
                MainMapView(
                    connectionViewModel: connectionViewModel,
                    recordingSessionManager: recordingSessionManager,
                    captureCoordinator: captureCoordinator
                )
            } else {
                DataView(
                    recordingSessionManager: recordingSessionManager,
                    captureCoordinator: captureCoordinator
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .environment(categoryStore)
        .sheet(isPresented: phoneCameraSheetBinding) {
            if let captureCoordinator {
                ImagePicker(
                    triggerCapture: Binding(
                        get: { captureCoordinator.triggerPhoneCapture },
                        set: { captureCoordinator.triggerPhoneCapture = $0 }
                    )
                ) { image in
                    captureCoordinator.handlePhoneCapturedImage(image)
                }
                .ignoresSafeArea()
            }
        }
    }

    private var phoneCameraSheetBinding: Binding<Bool> {
        Binding(
            get: { captureCoordinator?.showPhoneCamera ?? false },
            set: { newValue in captureCoordinator?.showPhoneCamera = newValue }
        )
    }

    // MARK: - Bottom bar (record strip + nav tabs)

    private var bottomBar: some View {
        VStack(spacing: 0) {
            // ── Record strip ────────────────────────────────────────────────
            Divider()
            HStack(spacing: 32) {
                Spacer()
                VStack(spacing: 4) {
                    Button { toggleRecording() } label: {
                        ZStack {
                            Circle()
                                .fill(isRecording ? Color.red : Color(.systemBackground))
                                .frame(width: 23, height: 23)
                                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                                .overlay(
                                    Circle()
                                        .stroke(isRecording ? Color.clear : Color(.separator), lineWidth: 0.5)
                                )

                            if isRecording {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.white)
                                    .frame(width: 8, height: 8)
                            } else {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 11, height: 11)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Text(isRecording ? "Tap or say \"End session\"" : "Tap or say \"Start session\"")
                        .font(.system(size: 9, weight: isRecording ? .semibold : .regular))
                        .foregroundStyle(isRecording ? Color.red : Color.secondary)
                }

                if isRecording, let captureCoordinator {
                    VStack(spacing: 4) {
                        Button { captureCoordinator.beginPhoneCameraCapture() } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(.systemBackground))
                                    .frame(width: 23, height: 23)
                                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                                    .overlay(
                                        Circle()
                                            .stroke(Color(.separator), lineWidth: 0.5)
                                    )

                                Image(systemName: "camera.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.primary)
                            }
                        }
                        .buttonStyle(.plain)

                        Text("phone camera")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer()
            }
            .frame(height: 48)

            // ── Nav tabs ────────────────────────────────────────────────────
            Divider()
            HStack(spacing: 0) {
                navBarButton(index: 0, icon: "map.fill",    label: "Map")
                navBarButton(index: 1, icon: "list.bullet", label: "Data")
            }
            .frame(height: 49)
        }
        .background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
    }

    private func navBarButton(index: Int, icon: String, label: String) -> some View {
        Button { selectedTab = index } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundStyle(selectedTab == index ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recording toggle

    private func toggleRecording() {
        if isRecording {
            endRecordingFlow()
        } else {
            startRecordingFlow()
        }
    }
}

#Preview {
    ContentView()
}
