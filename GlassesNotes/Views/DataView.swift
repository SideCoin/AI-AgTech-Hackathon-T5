import SwiftUI

// MARK: - Data View Model

@Observable
@MainActor
final class DataViewModel {
    struct Entry: Identifiable {
        let id: String
        let manifest: SessionManifest
        let observations: [(observation: CaptureObservation, photoURL: URL)]

        var photoCount: Int { observations.count }
        var primaryNote: String {
            observations.first(where: { !$0.observation.note.isEmpty })?.observation.note ?? ""
        }
        var primaryLocation: String {
            guard let first = observations.first else { return "" }
            return String(format: "%.4f°, %.4f°", first.observation.latitude, first.observation.longitude)
        }
        var duration: TimeInterval {
            guard let end = manifest.endTime else { return 0 }
            return end.timeIntervalSince(manifest.startTime)
        }
        var durationString: String {
            let secs = Int(duration)
            if secs < 3600 {
                return String(format: "%d:%02d", secs / 60, secs % 60)
            }
            return String(format: "%d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
        }
        var categoryIds: Set<String> {
            Set(observations.map { $0.observation.categoryOrUncategorized })
        }
    }

    var entries: [Entry] = []
    var isLoading = false
    var errorMessage: String?

    var totalPinCount: Int { entries.reduce(0) { $0 + $1.photoCount } }
    var totalDurationString: String {
        let total = entries.reduce(0.0) { $0 + $1.duration }
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        return "\(h)h \(String(format: "%02d", m))m"
    }

    func load() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let store = ObservationStore()
                let manifests = try store.listSessionManifests()
                var loaded: [Entry] = []
                for manifest in manifests {
                    let obs = (try? store.load(sessionID: manifest.id)) ?? []
                    loaded.append(Entry(id: manifest.id, manifest: manifest, observations: obs))
                }
                entries = loaded
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func deleteSession(id: String) {
        try? ObservationStore().deleteSession(id: id)
        entries.removeAll { $0.id == id }
    }
}

// MARK: - Data View

struct DataView: View {
    var recordingSessionManager: RecordingSessionManager
    var captureCoordinator: CaptureCoordinator? = nil

    @Environment(CategoryStore.self) private var categoryStore
    @Environment(CategorizationCoordinator.self) private var categorizationCoordinator
    @State private var viewModel = DataViewModel()
    @State private var selectedCategoryFilter: String? = nil
    @State private var sortNewest = true

    private var filteredEntries: [DataViewModel.Entry] {
        var result = viewModel.entries
        if let catId = selectedCategoryFilter {
            result = result.filter { $0.categoryIds.contains(catId) }
        }
        return sortNewest ? result : result.reversed()
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isLoading {
                    ForEach(0..<5, id: \.self) { _ in skeletonRow }
                } else if filteredEntries.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredEntries) { entry in
                        NavigationLink(value: entry.id) {
                            entryRow(entry)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                    .onDelete(perform: deleteEntries)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Entries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Newest first") { sortNewest = true }
                        Button("Oldest first") { sortNewest = false }
                    } label: {
                        Label("sort: \(sortNewest ? "new" : "old") ▾", systemImage: "")
                            .labelStyle(.titleOnly)
                            .font(.system(size: 13))
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if recordingSessionManager.isRecording {
                        SessionLiveBanner(
                            recordingSessionManager: recordingSessionManager,
                            captureCoordinator: captureCoordinator
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    }
                    headerSection
                }
                .background(.background)
            }
            .refreshable { viewModel.load() }
            .navigationDestination(for: String.self) { sessionID in
                if let entry = viewModel.entries.first(where: { $0.id == sessionID }) {
                    SessionDetailView(entry: entry) {
                        viewModel.load()
                        categorizationCoordinator.notifyDataChanged()
                    }
                }
            }
        }
        .onAppear { viewModel.load() }
    }

    private func deleteEntries(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredEntries[$0].id }
        for id in toDelete {
            viewModel.deleteSession(id: id)
        }
        categorizationCoordinator.notifyDataChanged()
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Stats subtitle
            HStack(spacing: 6) {
                Text("\(viewModel.totalPinCount) pins")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(viewModel.totalDurationString) of sessions")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // Filter row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(title: "all", isSelected: selectedCategoryFilter == nil) {
                        selectedCategoryFilter = nil
                    }
                    ForEach(categoryStore.categories) { cat in
                        filterChip(
                            title: cat.name,
                            color: Color(hex: cat.colorHex),
                            isSelected: selectedCategoryFilter == cat.id
                        ) {
                            selectedCategoryFilter = selectedCategoryFilter == cat.id ? nil : cat.id
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Divider()
        }
    }

    private func filterChip(title: String, color: Color? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Entry row

    private func entryRow(_ entry: DataViewModel.Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Photo stack
            photoStack(count: entry.photoCount, photoURL: entry.observations.first?.photoURL)

            VStack(alignment: .leading, spacing: 4) {
                // Header: session title (date/time) + duration
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(entry.manifest.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(entry.durationString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // Note
                Text(entry.primaryNote.isEmpty ? "— no notes —" : entry.primaryNote)
                    .font(.system(size: 12))
                    .foregroundStyle(entry.primaryNote.isEmpty ? .secondary : .primary)
                    .lineLimit(2)

                // Location
                if !entry.primaryLocation.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin")
                            .font(.system(size: 9))
                        Text(entry.primaryLocation)
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 64)
        }
    }

    private func photoStack(count: Int, photoURL: URL?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(-3))

            if let url = photoURL, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .rotationEffect(.degrees(1.5))
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "camera")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 14))
                    )
                    .rotationEffect(.degrees(1.5))
            }

            if count > 1 {
                Text("×\(count)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .offset(x: 14, y: 14)
            }
        }
        .frame(width: 52, height: 52)
    }

    // MARK: - Empty & skeleton states

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No entries yet")
                .font(.headline)
            Text("Start a session from the Map tab to create your first pin.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowSeparator(.hidden)
    }

    private var skeletonRow: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(Color(.secondarySystemBackground)).frame(height: 12).frame(maxWidth: 140)
                RoundedRectangle(cornerRadius: 4).fill(Color(.secondarySystemBackground)).frame(height: 10).frame(maxWidth: 200)
                RoundedRectangle(cornerRadius: 4).fill(Color(.secondarySystemBackground)).frame(height: 9).frame(maxWidth: 160)
            }
            .redacted(reason: .placeholder)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Session Detail Sheet

private struct PhotoIdentifier: Identifiable {
    let id: URL
    var url: URL { id }
}

struct SessionDetailView: View {
    let entry: DataViewModel.Entry
    var onChange: (() -> Void)? = nil

    @Environment(CategoryStore.self) private var categoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var observations: [(observation: CaptureObservation, photoURL: URL)] = []
    @State private var enlargedPhoto: PhotoIdentifier?

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(entry.manifest.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(entry.durationString)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Spacer()
                    Text("\(observations.count) photo\(observations.count == 1 ? "" : "s")")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Photos") {
                if observations.isEmpty {
                    Text("No photos in this session")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ForEach(observations, id: \.observation.id) { item in
                        Button {
                            enlargedPhoto = PhotoIdentifier(id: item.photoURL)
                        } label: {
                            photoRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deletePhotos)
                }
            }
        }
        .navigationTitle(entry.manifest.startTime.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .fullScreenCover(item: $enlargedPhoto) { photo in
            FullScreenPhotoView(url: photo.url)
        }
    }

    private func photoRow(_ item: (observation: CaptureObservation, photoURL: URL)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let img = UIImage(contentsOfFile: item.photoURL.path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "camera")
                            .foregroundStyle(.secondary)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                // Category chip
                let catId = item.observation.categoryOrUncategorized
                if let cat = categoryStore.categories.first(where: { $0.id == catId }) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: cat.colorHex))
                            .frame(width: 7, height: 7)
                        Text(cat.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(item.observation.note.isEmpty ? "(no note)" : item.observation.note)
                    .font(.system(size: 13))
                    .foregroundStyle(item.observation.note.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Image(systemName: "mappin")
                        .font(.system(size: 9))
                    Text(String(format: "%.4f°, %.4f°", item.observation.latitude, item.observation.longitude))
                        .font(.system(size: 10, design: .monospaced))
                    Spacer()
                    Text(item.observation.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func reload() {
        observations = (try? ObservationStore().load(sessionID: entry.id)) ?? []
    }

    private func deletePhotos(at offsets: IndexSet) {
        let store = ObservationStore()
        let ids = offsets.map { observations[$0].observation.id }
        for id in ids {
            try? store.deleteObservation(id: id, from: entry.id)
        }
        observations.removeAll { ids.contains($0.observation.id) }

        if observations.isEmpty {
            try? store.deleteSession(id: entry.id)
            onChange?()
            dismiss()
        } else {
            onChange?()
        }
    }
}

// MARK: - Full Screen Photo Viewer

struct FullScreenPhotoView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1.0, min(lastScale * value, 5.0))
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale < 1.0 {
                                    withAnimation(.spring()) {
                                        scale = 1.0
                                        lastScale = 1.0
                                    }
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            scale = scale > 1.0 ? 1.0 : 2.5
                            lastScale = scale
                        }
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Photo unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.85), .black.opacity(0.4))
                            .padding()
                    }
                }
                Spacer()
            }
        }
        .statusBarHidden()
    }
}
