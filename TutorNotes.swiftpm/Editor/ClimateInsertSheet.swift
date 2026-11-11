import SwiftUI

/// Insert → Climate Graph: the student searches for a place, picks it from the results, and a
/// climate graph of its 1991–2020 averages is downloaded and placed on the page.
struct ClimateInsertSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [ClimatePlace] = []
    @State private var searched = false
    @State private var searching = false
    /// Index of the result whose climate data is downloading.
    @State private var loadingIndex: Int?
    @State private var errorText: String?
    @State private var showMaxMin = true
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Town or city, e.g. Dubbo or Cairns, QLD", text: $query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { search() }
                        if searching {
                            ProgressView()
                        } else {
                            Button("Search") { search() }
                                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    Toggle("Show mean daily max and min", isOn: $showMaxMin)
                } footer: {
                    Text("Monthly rainfall and temperature averaged over 1991–2020, from ERA5 reanalysis via Open-Meteo.")
                }
                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
                if !results.isEmpty {
                    Section("Places") {
                        ForEach(Array(results.enumerated()), id: \.offset) { i, r in
                            Button {
                                insert(r, index: i)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.name).foregroundStyle(.primary)
                                        Text(details(r)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if loadingIndex == i { ProgressView() }
                                }
                            }
                            .disabled(loadingIndex != nil)
                        }
                    }
                } else if searched && !searching && errorText == nil {
                    Section {
                        Text("No places found. Check the spelling or add the state or country.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Insert Climate Graph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
        }
    }

    private func details(_ r: ClimatePlace) -> String {
        var parts: [String] = []
        if let a = r.admin1, !a.isEmpty { parts.append(a) }
        if let c = r.country, !c.isEmpty { parts.append(c) }
        parts.append(r.coordinateText)
        if let e = r.elevation { parts.append("\(Int(e.rounded())) m") }
        return parts.joined(separator: " · ")
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        errorText = nil
        searching = true
        task?.cancel()
        task = Task {
            do {
                results = try await GeoMapBuilder.searchPlaces(q, count: 12)
                searched = true
            } catch is CancellationError {
            } catch {
                errorText = (error as? GeoServiceError)?.message ?? error.localizedDescription
                results = []
            }
            searching = false
        }
    }

    private func insert(_ place: ClimatePlace, index: Int) {
        errorText = nil
        loadingIndex = index
        let maxMin = showMaxMin
        task = Task {
            do {
                let normals = try await GeoDataService.shared.climateNormals(place)
                try Task.checkCancellation()
                let chart = ClimateData.chart(normals, showMaxMin: maxMin)
                let width = min(520, model.document.pageSize.width - 60)
                model.insertStudentElement(.chart(chart), size: CGSize(width: width, height: 360), actionName: "Insert Climate Graph")
                loadingIndex = nil
                dismiss()
            } catch is CancellationError {
                loadingIndex = nil
            } catch {
                errorText = (error as? GeoServiceError)?.message ?? error.localizedDescription
                loadingIndex = nil
            }
        }
    }
}
