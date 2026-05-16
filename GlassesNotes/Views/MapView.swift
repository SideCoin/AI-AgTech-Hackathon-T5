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

    /// Add a pin to the map. Matches Python's add_pin(lat, lon, note, photo_path).
    func addPin(lat: Double, lon: Double, note: String, photo: UIImage? = nil) {
        let obs = CaptureObservation(
            id: UUID(),
            note: note,
            latitude: lat,
            longitude: lon,
            timestamp: Date(),
            category: nil
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
}

// MARK: - ESRI Map UIViewRepresentable

struct ESRIMapView: UIViewRepresentable {
    let annotations: [ObservationAnnotation]
    @Binding var selectedAnnotation: ObservationAnnotation?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.addOverlay(ESRITileOverlay(), level: .aboveLabels)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "pin")

        // Default center: Davis, CA farmland (matches Python test coordinates)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 38.5449, longitude: -121.7405),
            latitudinalMeters: 2000,
            longitudinalMeters: 2000
        )
        map.setRegion(region, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let existingIDs = Set(map.annotations.compactMap { ($0 as? ObservationAnnotation)?.id })
        let newIDs = Set(annotations.map(\.id))

        let toRemove = map.annotations.filter {
            guard let ann = $0 as? ObservationAnnotation else { return false }
            return !newIDs.contains(ann.id)
        }
        let toAdd = annotations.filter { !existingIDs.contains($0.id) }

        map.removeAnnotations(toRemove)
        map.addAnnotations(toAdd)

        if !toAdd.isEmpty {
            let all = map.annotations.compactMap { $0 as? ObservationAnnotation }
            map.showAnnotations(all, animated: true)
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ESRIMapView

        init(_ parent: ESRIMapView) { self.parent = parent }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let obs = annotation as? ObservationAnnotation else { return nil }

            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin", for: obs) as! MKMarkerAnnotationView
            view.annotation = obs
            view.markerTintColor = .systemRed
            view.glyphImage = UIImage(systemName: "leaf.fill")
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
                    LabeledContent("Latitude") {
                        Text(String(format: "%.5f°", annotation.observation.latitude))
                    }
                    LabeledContent("Longitude") {
                        Text(String(format: "%.5f°", annotation.observation.longitude))
                    }
                }

                Section("Captured") {
                    Text(annotation.observation.timestamp.formatted(date: .complete, time: .shortened))
                        .foregroundStyle(.secondary)
                }

                if let category = annotation.observation.category {
                    Section("Category") {
                        Text(category)
                    }
                }
            }
            .navigationTitle("Observation")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Map Container View

/// Full-screen ESRI satellite map with observation pins.
/// Call `viewModel.addPin(lat:lon:note:photo:)` to place pins programmatically.
struct MapContainerView: View {
    @State private var viewModel = MapViewModel()
    @State private var selectedAnnotation: ObservationAnnotation?

    let sessionID: String

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ESRIMapView(annotations: viewModel.pins, selectedAnnotation: $selectedAnnotation)
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
