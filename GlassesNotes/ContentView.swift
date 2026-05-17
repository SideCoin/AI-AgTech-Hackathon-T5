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
    @State private var categorizationCoordinator: CategorizationCoordinator?
    @State private var selectedTab = 0

    private var isRecording: Bool { recordingSessionManager.isRecording }

    var body: some View {
        Group {
            if let connectionViewModel, let categorizationCoordinator {
                mainTabView(
                    connectionViewModel: connectionViewModel,
                    categorizationCoordinator: categorizationCoordinator
                )
            } else {
                ProgressView("Initializing...")
                    .onAppear { setup() }
            }
        }
    }

    // MARK: - Setup

    private func setup() {
        // TEMP: one-shot OpenAI key install — run once on device, then DELETE this line
        // and re-run. Key persists in the Keychain afterwards.
        try? Secrets.set(.openAI, value: "sk-REPLACE_ME")

        connectionViewModel = GlassesConnectionViewModel(wearables: Wearables.shared)
        streamManager = GlassesStreamManager(wearables: Wearables.shared)
        captureCoordinator = CaptureCoordinator(sessionManager: recordingSessionManager)

        let coordinator = CategorizationCoordinator(categoryStore: categoryStore)
        categorizationCoordinator = coordinator
        recordingSessionManager.categorizationCoordinator = coordinator
        captureCoordinator?.categorizationCoordinator = coordinator

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

    private func mainTabView(
        connectionViewModel: GlassesConnectionViewModel,
        categorizationCoordinator: CategorizationCoordinator
    ) -> some View {
        // Keep both tabs mounted so MainMapView's MKMapView, mapViewModel, and
        // user-location centering state survive tab switches. The previous
        // if/else recreated MainMapView, which made pins flash in and then
        // disappear when the fresh map re-snapped to the user's location.
        ZStack {
            if let captureCoordinator {
                MainMapView(
                    connectionViewModel: connectionViewModel,
                    recordingSessionManager: recordingSessionManager,
                    captureCoordinator: captureCoordinator
                )
                .opacity(selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(selectedTab == 0)
            }
            DataView(
                recordingSessionManager: recordingSessionManager,
                captureCoordinator: captureCoordinator
            )
            .opacity(selectedTab == 1 ? 1 : 0)
            .allowsHitTesting(selectedTab == 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .environment(categoryStore)
        .environment(categorizationCoordinator)
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

                        Text("Tap or say \"Take a photo\"")
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
