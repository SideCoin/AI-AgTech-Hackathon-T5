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
        var categoryId: String? { observations.first?.observation.category }
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
}

// MARK: - Data View

struct DataView: View {
    @Environment(CategoryStore.self) private var categoryStore
    @State private var viewModel = DataViewModel()
    @State private var selectedCategoryFilter: String? = nil
    @State private var sortNewest = true

    private var filteredEntries: [DataViewModel.Entry] {
        var result = viewModel.entries
        if let catId = selectedCategoryFilter {
            result = result.filter { $0.categoryId == catId }
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
                        entryRow(entry)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparator(.hidden)
                    }
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
                headerSection
                    .background(.background)
            }
            .refreshable { viewModel.load() }
        }
        .onAppear { viewModel.load() }
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
                // Header: category dot + name + duration
                HStack(spacing: 6) {
                    if let catId = entry.categoryId,
                       let cat = categoryStore.categories.first(where: { $0.id == catId }) {
                        Circle()
                            .fill(Color(hex: cat.colorHex))
                            .frame(width: 8, height: 8)
                        Text(cat.name)
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Image(systemName: "mappin")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("Uncategorized")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
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

                // Location + timestamp
                HStack(spacing: 10) {
                    if !entry.primaryLocation.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin")
                                .font(.system(size: 9))
                            Text(entry.primaryLocation)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                    }
                    Text(entry.manifest.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10, design: .monospaced))
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
