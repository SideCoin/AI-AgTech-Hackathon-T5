//
//  ContentView.swift
//  GlassesNotes
//
//  Created by Shizun Yang on 5/15/26.
//

import MWDATCore
import SwiftUI

struct ContentView: View {
    @State private var connectionViewModel: GlassesConnectionViewModel?
    @State private var streamManager: GlassesStreamManager?
    @State private var recordingSessionManager = RecordingSessionManager()
    @State private var captureCoordinator: CaptureCoordinator?
    @State private var showSessionView = false

    var body: some View {
        Group {
            if let connectionViewModel = connectionViewModel {
                if connectionViewModel.registrationState == .registered {
                    homeView
                } else {
                    registrationView(connectionViewModel)
                }
            } else {
                ProgressView("Initializing...")
                    .onAppear {
                        connectionViewModel = GlassesConnectionViewModel(wearables: Wearables.shared)
                        streamManager = GlassesStreamManager(wearables: Wearables.shared)
                        captureCoordinator = CaptureCoordinator(sessionManager: recordingSessionManager)

                        if let streamManager = streamManager, let captureCoordinator = captureCoordinator {
                            streamManager.onPhotoCaptured = { photoData in
                                captureCoordinator.handleCapturedPhoto(photoData)
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showSessionView) {
            if let streamManager = streamManager, let captureCoordinator = captureCoordinator {
                SessionView(
                    recordingSessionManager: recordingSessionManager,
                    captureCoordinator: captureCoordinator,
                    streamManager: streamManager
                )
            }
        }
    }

    // MARK: - Registration View

    private func registrationView(_ connectionViewModel: GlassesConnectionViewModel) -> some View {
        ZStack {
            Color.white.edgesIgnoringSafeArea(.all)

            VStack(spacing: 12) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "glasses")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)

                    VStack(spacing: 8) {
                        Text("Connect Your Glasses")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("Register with Meta AI to get started")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }

                Spacer()

                VStack(spacing: 20) {
                    Text("You'll be redirected to the Meta AI app to confirm your connection.")
                        .font(.system(size: 14))
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)

                    Button(action: {
                        connectionViewModel.connectGlasses()
                    }) {
                        Text(connectionViewModel.registrationState == .registering ? "Connecting..." : "Connect my glasses")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .disabled(connectionViewModel.registrationState == .registering)
                }
            }
            .padding(.all, 24)
        }
        .alert("Error", isPresented: .constant(connectionViewModel.showError)) {
            Button("OK") { connectionViewModel.dismissError() }
        } message: {
            Text(connectionViewModel.errorMessage)
        }
    }

    // MARK: - Home View

    private var homeView: some View {
        ZStack {
            Color(.systemBackground).edgesIgnoringSafeArea(.all)

            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Glasses Connected")
                                .font(.headline)

                            Text("Ready to start recording")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }

                Spacer()

                Button(action: {
                    recordingSessionManager.startSession()
                    showSessionView = true
                }) {
                    HStack {
                        Image(systemName: "record.circle.fill")
                        Text("Start Recording Session")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }

                Spacer()
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
