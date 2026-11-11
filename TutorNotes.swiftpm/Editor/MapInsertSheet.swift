import SwiftUI

/// Insert → Map: the student picks a region and what the map shows (blank outline, political,
/// climate zones or a real dataset); data is downloaded before the map is placed.
struct MapInsertSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    enum Layer: String, CaseIterable, Identifiable {
        case outline, political, climate, data
        var id: String { rawValue }
        var title: String {
            switch self {
            case .outline: return "Blank"
            case .political: return "Political"
            case .climate: return "Climate"
            case .data: return "Data"
            }
        }
        var style: MapStyle {
            switch self {
            case .outline: return .outline
            case .political: return .political
            case .climate: return .climate
            case .data: return .data
            }
        }
    }

    @State private var regionID = "world"
    @State private var zoomPlace = ""
    @State private var layer: Layer = .political
    @State private var datasetID = "life_expectancy"
    @State private var labels = true
    @State private var graticule = false
    @State private var latitudeLines = false
    @State private var climateGroups = false
    @State private var title = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    private var selectedDataset: GeoDataset? { GeoCatalog.datasets.first { $0.id == datasetID } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Region", selection: $regionID) {
                        ForEach(MapRegionPreset.all, id: \.id) { p in Text(p.name).tag(p.id) }
                    }
                    TextField("Or zoom to a country or state, e.g. Indonesia, NSW", text: $zoomPlace)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("Region")
                }
                Section {
                    Picker("Layer", selection: $layer) {
                        ForEach(Layer.allCases) { l in Text(l.title).tag(l) }
                    }
                    .pickerStyle(.segmented)
                    if layer == .data {
                        Picker("Dataset", selection: $datasetID) {
                            ForEach(GeoCatalog.topics, id: \.self) { topic in
                                Section(topic) {
                                    ForEach(GeoCatalog.datasets.filter { $0.topic == topic }, id: \.id) { d in
                                        Text(d.title).tag(d.id)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                    if layer == .climate {
                        Toggle("Main groups only (A–E)", isOn: $climateGroups)
                    }
                    Toggle("Country and state names", isOn: $labels)
                    Toggle("Latitude and longitude lines", isOn: $graticule)
                    Toggle("Equator, tropics and polar circles", isOn: $latitudeLines)
                } header: {
                    Text("Show")
                } footer: {
                    Text(footerText)
                }
                Section("Title") {
                    TextField("Optional", text: $title)
                }
                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .disabled(busy)
            .navigationTitle("Insert Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Insert") { insert() }
                    }
                }
            }
            .onChange(of: layer) { _, newValue in
                labels = newValue == .political
                graticule = newValue == .outline
            }
        }
    }

    private var footerText: String {
        switch layer {
        case .outline: return "A blank outline map with no names, ready for you to label."
        case .political: return "Countries in soft colours with their names. Outlines from Natural Earth."
        case .climate: return "Köppen–Geiger climate zones, 1991–2020 (Beck et al. 2023)."
        case .data:
            guard let d = selectedDataset else { return "" }
            return "\(d.title) (\(d.unit)), downloaded from \(d.provider.displayName) when you tap Insert. The latest year with good coverage is used."
        }
    }

    private func insert() {
        errorText = nil
        guard let world = GeoAssets.world else {
            errorText = "Map outlines aren't available in this build of the app."
            return
        }
        busy = true
        let zoom = zoomPlace.trimmingCharacters(in: .whitespaces)
        let preset = regionID
        let chosenLayer = layer
        let dataset = selectedDataset
        task = Task {
            do {
                let region = try GeoMapBuilder.region(zoom.isEmpty ? preset : zoom, bbox: nil, world: world)
                var m = MapContent()
                m.region = region.name
                m.bbox = region.bbox
                if region.bbox == nil { m.centralLon = region.centralLon }
                m.layer = chosenLayer.style.rawValue
                m.labels = labels
                m.graticule = graticule
                m.latitudeLines = latitudeLines
                m.climateDetail = climateGroups ? "groups" : nil
                let typedTitle = title.trimmingCharacters(in: .whitespaces)
                switch chosenLayer {
                case .data:
                    guard let dataset else { throw GeoServiceError(message: "Choose a dataset.") }
                    let built = try await GeoMapBuilder.choropleth(dataset, year: nil, world: world)
                    m.choropleth = built.0
                    m.source = built.caption
                    m.title = typedTitle.isEmpty ? "\(built.0.indicator), \(built.0.yearLabel)" : typedTitle
                case .climate:
                    m.source = "Source: Beck et al. (2023), Köppen–Geiger climate classification 1991–2020 (CC BY 4.0)"
                    m.title = typedTitle.isEmpty ? "Climate zones: \(region.name)" : typedTitle
                case .outline, .political:
                    m.source = "Source: Natural Earth (public domain)"
                    m.title = typedTitle.isEmpty ? region.name : typedTitle
                }
                try Task.checkCancellation()
                let pageWidth = model.document.pageSize.width
                let size = MapRenderer.preferredSize(m, width: min(560, pageWidth - 60), maxHeight: 760)
                model.insertStudentElement(.map(m), size: size, actionName: "Insert Map")
                busy = false
                dismiss()
            } catch is CancellationError {
                busy = false
            } catch {
                errorText = (error as? GeoServiceError)?.message ?? error.localizedDescription
                busy = false
            }
        }
    }
}
