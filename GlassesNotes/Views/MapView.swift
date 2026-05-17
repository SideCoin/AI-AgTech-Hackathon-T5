import SwiftUI
import MapKit
import UIKit

// MARK: - Observation Annotation

final class ObservationAnnotation: NSObject, MKAnnotation, Identifiable {
    let id: UUID
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?
    let observation: CaptureObservation
    let photoURL: URL?

    init(observation: CaptureObservation, photoURL: URL?) {
        self.id = observation.id
        self.coordinate = CLLocationCoordinate2D(
            latitude: observation.latitude,
            longitude: observation.longitude
        )
        self.title = observation.note.isEmpty ? "Observation" : String(observation.note.prefix(60))
        self.subtitle = observation.timestamp.formatted(date: .abbreviated, time: .shortened)
        self.observation = observation
        self.photoURL = photoURL
        super.init()
    }
}

// MARK: - ESRI World Imagery Tile Overlay

private final class ESRITileOverlay: MKTileOverlay {
    init() {
        super.init(
            urlTemplate: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
        )
        canReplaceMapContent = true
    }
}

// MARK: - Map View Model

@Observable
@MainActor
final class MapViewModel {
    private(set) var pins: [ObservationAnnotation] = []

    func addPin(lat: Double, lon: Double, note: String, category: String? = nil, photo: UIImage? = nil) {
        let obs = CaptureObservation(
            id: UUID(),
            note: note,
            latitude: lat,
            longitude: lon,
            timestamp: Date(),
            category: category
        )
        var photoURL: URL? = nil
        if let photo, let data = photo.jpegData(compressionQuality: 0.8) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(obs.id.uuidString).jpg")
            try? data.write(to: url)
            photoURL = url
        }
        pins.append(ObservationAnnotation(observation: obs, photoURL: photoURL))
    }

    func loadFromSession(_ observations: [(observation: CaptureObservation, photoURL: URL)]) {
        pins = observations.map { ObservationAnnotation(observation: $0.observation, photoURL: $0.photoURL) }
    }

    func loadAllSessions() {
        let store = ObservationStore()
        guard let manifests = try? store.listSessionManifests() else { return }
        var all: [ObservationAnnotation] = []
        for manifest in manifests {
            if let items = try? store.load(sessionID: manifest.id) {
                all += items.map { ObservationAnnotation(observation: $0.observation, photoURL: $0.photoURL) }
            }
        }
        pins = all
    }
}

// MARK: - Map Controller (bridges SwiftUI buttons to MKMapView)

@MainActor
final class MapController {
    weak var mapView: MKMapView?

    func zoomIn() {
        guard let map = mapView else { return }
        var region = map.region
        region.span.latitudeDelta = max(region.span.latitudeDelta / 2, 0.0002)
        region.span.longitudeDelta = max(region.span.longitudeDelta / 2, 0.0002)
        map.setRegion(region, animated: true)
    }

    func zoomOut() {
        guard let map = mapView else { return }
        var region = map.region
        region.span.latitudeDelta = min(region.span.latitudeDelta * 2, 170)
        region.span.longitudeDelta = min(region.span.longitudeDelta * 2, 170)
        map.setRegion(region, animated: true)
    }

    func recenterOnUser() {
        guard let map = mapView else { return }
        let coord = map.userLocation.coordinate
        guard CLLocationCoordinate2DIsValid(coord),
              coord.latitude != 0 || coord.longitude != 0 else { return }
        let region = MKCoordinateRegion(
            center: coord,
            latitudinalMeters: 500,
            longitudinalMeters: 500
        )
        map.setRegion(region, animated: true)
    }
}

// MARK: - ESRI Map UIViewRepresentable

struct ESRIMapView: UIViewRepresentable {
    let annotations: [ObservationAnnotation]
    let categoryColors: [String: UIColor]
    @Binding var selectedAnnotation: ObservationAnnotation?
    var controller: MapController? = nil
    var isRecording: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.backgroundColor = UIColor(white: 0.12, alpha: 1)
        map.addOverlay(ESRITileOverlay(), level: .aboveLabels)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "pin")

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 38.5449, longitude: -121.7405),
            latitudinalMeters: 2000,
            longitudinalMeters: 2000
        )
        map.setRegion(region, animated: false)
        controller?.mapView = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        controller?.mapView = map
        let existingIDs = Set(map.annotations.compactMap { ($0 as? ObservationAnnotation)?.id })
        let newIDs = Set(annotations.map(\.id))

        let toRemove = map.annotations.filter {
            guard let ann = $0 as? ObservationAnnotation else { return false }
            return !newIDs.contains(ann.id)
        }
        let toAdd = annotations.filter { !existingIDs.contains($0.id) }

        map.removeAnnotations(toRemove)
        map.addAnnotations(toAdd)

        // Refresh colors for existing annotations
        for ann in map.annotations.compactMap({ $0 as? ObservationAnnotation }) {
            if let view = map.view(for: ann) as? MKMarkerAnnotationView {
                if let catId = ann.observation.category, let color = categoryColors[catId] {
                    view.markerTintColor = color
                } else {
                    view.markerTintColor = .systemGreen
                }
            }
        }

        // Refresh user location dot to match recording state
        if let userView = map.view(for: map.userLocation) {
            context.coordinator.applyUserLocationStyle(to: userView, isRecording: isRecording)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ESRIMapView
        private var didCenterOnUser = false

        init(_ parent: ESRIMapView) { self.parent = parent }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !didCenterOnUser else { return }
            let coord = userLocation.coordinate
            guard CLLocationCoordinate2DIsValid(coord),
                  coord.latitude != 0 || coord.longitude != 0 else { return }
            didCenterOnUser = true
            let region = MKCoordinateRegion(
                center: coord,
                latitudinalMeters: 500,
                longitudinalMeters: 500
            )
            mapView.setRegion(region, animated: false)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let userLocation = annotation as? MKUserLocation {
                let identifier = "userLocation"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: userLocation, reuseIdentifier: identifier)
                view.annotation = userLocation
                view.canShowCallout = false
                applyUserLocationStyle(to: view, isRecording: parent.isRecording)
                return view
            }

            guard let obs = annotation as? ObservationAnnotation else { return nil }

            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin", for: obs) as! MKMarkerAnnotationView
            view.annotation = obs

            if let catId = obs.observation.category, let color = parent.categoryColors[catId] {
                view.markerTintColor = color
            } else {
                view.markerTintColor = .systemGreen
            }
            view.glyphImage = UIImage(systemName: "mappin")
            view.canShowCallout = true

            if let photoURL = obs.photoURL, let image = UIImage(contentsOfFile: photoURL.path) {
                let iv = UIImageView(image: image)
                iv.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 6
                view.leftCalloutAccessoryView = iv
            } else {
                view.leftCalloutAccessoryView = nil
            }
            view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
            return view
        }

        func mapView(
            _ mapView: MKMapView,
            annotationView view: MKAnnotationView,
            calloutAccessoryControlTapped control: UIControl
        ) {
            parent.selectedAnnotation = view.annotation as? ObservationAnnotation
        }

        func applyUserLocationStyle(to view: MKAnnotationView, isRecording: Bool) {
            view.subviews.forEach { $0.removeFromSuperview() }

            let color: UIColor = isRecording ? .systemRed : .systemBlue
            let size: CGFloat = 22
            view.frame = CGRect(x: 0, y: 0, width: size, height: size)
            view.centerOffset = .zero

            let halo = UIView(frame: view.bounds)
            halo.backgroundColor = color.withAlphaComponent(0.25)
            halo.layer.cornerRadius = size / 2
            halo.isUserInteractionEnabled = false
            view.addSubview(halo)

            let dotSize: CGFloat = 14
            let dot = UIView(frame: CGRect(
                x: (size - dotSize) / 2,
                y: (size - dotSize) / 2,
                width: dotSize,
                height: dotSize
            ))
            dot.backgroundColor = color
            dot.layer.cornerRadius = dotSize / 2
            dot.layer.borderColor = UIColor.white.cgColor
            dot.layer.borderWidth = 2
            dot.isUserInteractionEnabled = false
            view.addSubview(dot)
        }
    }
}

// MARK: - Left-edge tab shape (flat left, rounded right)

private struct LeftEdgeTabShape: Shape {
    var cornerRadius: CGFloat = 8
    func path(in rect: CGRect) -> Path {
        let r = cornerRadius
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width - r, y: 0))
        p.addArc(center: CGPoint(x: rect.width - r, y: r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.width, y: rect.height - r))
        p.addArc(center: CGPoint(x: rect.width - r, y: rect.height - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        p.closeSubpath()
        return p
    }
}

// MARK: - Category Filter Drawer

private struct CategoryDrawerView: View {
    @Environment(CategoryStore.self) private var categoryStore

    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Categories")
                    .font(.title2.bold())
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Select all / none
            HStack(spacing: 8) {
                Button("all") { categoryStore.selectAll() }
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .underline()
                Text("·")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("none") { categoryStore.selectNone() }
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .underline()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Category list
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(categoryStore.categories) { category in
                        let enabled = categoryStore.isEnabled(category.id)
                        Button {
                            categoryStore.toggle(category.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: enabled ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(enabled ? Color(hex: category.colorHex) : .secondary)
                                    .font(.system(size: 16))

                                Circle()
                                    .fill(Color(hex: category.colorHex))
                                    .frame(width: 10, height: 10)

                                Text(category.name)
                                    .font(.system(size: 15))
                                    .foregroundStyle(enabled ? .primary : .secondary)

                                Spacer()

                                Text("\(category.count)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(enabled ? Color(hex: category.colorHex).opacity(0.08) : Color.clear)
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 16)
                    }

                    // Add new category row
                    HStack(spacing: 12) {
                        Image(systemName: "square")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 16))
                        Image(systemName: "plus")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("new category")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            Divider()

            // Footer
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("showing")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("\(categoryStore.visiblePinCount)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("of \(categoryStore.totalPinCount) pins")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Text("\(categoryStore.enabledCount) categories on")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(.background)
    }
}

// MARK: - Observation Detail Sheet

struct ObservationDetailView: View {
    let annotation: ObservationAnnotation

    var body: some View {
        NavigationStack {
            List {
                if let photoURL = annotation.photoURL,
                   let image = UIImage(contentsOfFile: photoURL.path) {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(8)
                            .listRowInsets(EdgeInsets())
                    }
                }
                Section("Note") {
                    Text(annotation.observation.note.isEmpty ? "(no note)" : annotation.observation.note)
                        .foregroundStyle(annotation.observation.note.isEmpty ? .secondary : .primary)
                }
                Section("Location") {
                    LabeledContent("Latitude")  { Text(String(format: "%.5f°", annotation.observation.latitude)) }
                    LabeledContent("Longitude") { Text(String(format: "%.5f°", annotation.observation.longitude)) }
                }
                Section("Captured") {
                    Text(annotation.observation.timestamp.formatted(date: .complete, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                if let category = annotation.observation.category {
                    Section("Category") { Text(category) }
                }
            }
            .navigationTitle("Observation")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Session Live Banner (shared)

struct SessionLiveBanner: View {
    var recordingSessionManager: RecordingSessionManager
    var captureCoordinator: CaptureCoordinator? = nil

    @State private var currentTime = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var elapsedString: String {
        guard let start = recordingSessionManager.startTime else { return "00:00:00" }
        let secs = Int(currentTime.timeIntervalSince(start))
        return String(format: "%02d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .overlay(
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 4)
                        .scaleEffect(1.6)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("session live · glasses")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(elapsedString) · \(recordingSessionManager.observationCount) photos")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }

            Spacer()

            if let captureCoordinator, captureCoordinator.isAudioActive {
                AudioWaveformView(level: CGFloat(captureCoordinator.audioLevel))
                    .frame(width: 36, height: 18)
                    .transition(.opacity)
            }

            Button {
                // overflow menu placeholder
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.white.opacity(0.7))
                    .font(.system(size: 13))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: captureCoordinator?.isAudioActive)
        .onReceive(ticker) { currentTime = $0 }
    }
}

// MARK: - Audio Waveform

struct AudioWaveformView: View {
    var level: CGFloat
    var barCount: Int = 5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let spacing: CGFloat = 2
                let totalSpacing = spacing * CGFloat(barCount - 1)
                let barWidth = max(1.5, (geo.size.width - totalSpacing) / CGFloat(barCount))
                let amplified = min(1.0, max(0.08, level * 1.4))
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { i in
                        let phase = sin(t * 7 + Double(i) * 1.1) * 0.5 + 0.5
                        let h = max(2, geo.size.height * amplified * (0.35 + 0.65 * CGFloat(phase)))
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: barWidth, height: h)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

// MARK: - Main Map View

struct MainMapView: View {
    var connectionViewModel: GlassesConnectionViewModel
    var recordingSessionManager: RecordingSessionManager
    var captureCoordinator: CaptureCoordinator

    @Environment(CategoryStore.self) private var categoryStore
    @State private var mapViewModel = MapViewModel()
    @State private var selectedAnnotation: ObservationAnnotation?
    @State private var drawerOpen = false
    @State private var showQuickNoteEntry = false
    @State private var quickNoteText = ""
    @State private var mapController = MapController()

    private var isRecording: Bool { recordingSessionManager.isRecording }

    private var filteredAnnotations: [ObservationAnnotation] {
        mapViewModel.pins.filter { ann in
            guard let catId = ann.observation.category else { return true }
            return categoryStore.isEnabled(catId)
        }
    }

    private var categoryColors: [String: UIColor] {
        Dictionary(uniqueKeysWithValues: categoryStore.categories.map { cat in
            (cat.id, UIColor(Color(hex: cat.colorHex)))
        })
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // ── 1. Map ──────────────────────────────────────────────────────
            ESRIMapView(
                annotations: filteredAnnotations,
                categoryColors: categoryColors,
                selectedAnnotation: $selectedAnnotation,
                controller: mapController,
                isRecording: isRecording
            )
            .ignoresSafeArea()

            // ── 2. Scrim when drawer open ───────────────────────────────────
            if drawerOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { closeDrawer() }
            }

            // ── 3. Category drawer (slides from left) ───────────────────────
            GeometryReader { geo in
                let drawerWidth = geo.size.width * 0.62
                HStack(spacing: 0) {
                    CategoryDrawerView(onClose: closeDrawer)
                        .frame(width: drawerWidth)
                        .shadow(color: .black.opacity(0.15), radius: 8, x: 4, y: 0)
                    Spacer()
                }
                .offset(x: drawerOpen ? 0 : -drawerWidth)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: drawerOpen)
                .ignoresSafeArea()

                // ── 4. Edge handle (always visible, ~30% from top) ──────────
                if !drawerOpen {
                    Button { openDrawer() } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Text("FILTERS")
                                .font(.system(size: 8, weight: .medium))
                                .rotationEffect(.degrees(-90))
                                .fixedSize()
                        }
                        .foregroundStyle(.primary)
                        .frame(width: 22, height: 90)
                        .background(.background)
                        .clipShape(LeftEdgeTabShape())
                        .shadow(color: .black.opacity(0.12), radius: 3, x: 2, y: 0)
                    }
                    .position(x: 11, y: geo.size.height * 0.30 + 45)
                }
            }
            .ignoresSafeArea()

            // ── 5. Top chrome (recording banner) ────────────────────────────
            if isRecording {
                VStack(alignment: .leading, spacing: 8) {
                    SessionLiveBanner(
                        recordingSessionManager: recordingSessionManager,
                        captureCoordinator: captureCoordinator
                    )
                    activeCategoryChips
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // ── 6. Zoom + my-location controls (top-right) ──────────────────
            VStack(spacing: 6) {
                mapControlButton(systemImage: "plus") { mapController.zoomIn() }
                mapControlButton(systemImage: "minus") { mapController.zoomOut() }
                Divider().frame(width: 34)
                mapControlButton(systemImage: "location") { mapController.recenterOnUser() }
            }
            .padding(.top, 60)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, alignment: .trailing)

            // ── 7. Bottom chrome ─────────────────────────────────────────────
            if isRecording {
                VStack(spacing: 0) {
                    Spacer()
                    HStack {
                        Spacer()
                        quickNoteFAB
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }

        }
        .sheet(item: $selectedAnnotation) { annotation in
            ObservationDetailView(annotation: annotation)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showQuickNoteEntry) {
            quickNoteSheet
        }
        .onAppear {
            mapViewModel.loadAllSessions()
        }
        .onChange(of: recordingSessionManager.state) { _, newState in
            if newState == .ended { mapViewModel.loadAllSessions() }
        }
    }

    // MARK: - Sub-views

    private var activeCategoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categoryStore.enabledCategories) { category in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: category.colorHex))
                            .frame(width: 7, height: 7)
                        Text(category.name)
                            .font(.system(size: 11))
                        Button {
                            categoryStore.toggle(category.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func mapControlButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var quickNoteFAB: some View {
        Button {
            showQuickNoteEntry = true
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
    }

    private var quickNoteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add a note to this session")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $quickNoteText)
                    .frame(minHeight: 100)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                Spacer()
            }
            .padding()
            .navigationTitle("Quick Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        quickNoteText = ""
                        showQuickNoteEntry = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Notes would be saved to the current session
                        quickNoteText = ""
                        showQuickNoteEntry = false
                    }
                    .disabled(quickNoteText.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func openDrawer() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            drawerOpen = true
        }
    }

    private func closeDrawer() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            drawerOpen = false
        }
    }

}

// MARK: - Legacy container kept for compatibility

struct MapContainerView: View {
    @State private var viewModel = MapViewModel()
    @State private var selectedAnnotation: ObservationAnnotation?
    let sessionID: String

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ESRIMapView(
                    annotations: viewModel.pins,
                    categoryColors: [:],
                    selectedAnnotation: $selectedAnnotation
                )
                .ignoresSafeArea()

                if !viewModel.pins.isEmpty {
                    Text("\(viewModel.pins.count) observation\(viewModel.pins.count == 1 ? "" : "s")")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                        .padding(.bottom, 24)
                }
            }
            .sheet(item: $selectedAnnotation) { annotation in
                ObservationDetailView(annotation: annotation)
                    .presentationDetents([.medium, .large])
            }
            .navigationTitle("Field Map")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { loadObservations() }
        .onChange(of: sessionID) { loadObservations() }
    }

    private func loadObservations() {
        guard !sessionID.isEmpty else { return }
        let loaded = (try? ObservationStore().load(sessionID: sessionID)) ?? []
        viewModel.loadFromSession(loaded)
    }
}
