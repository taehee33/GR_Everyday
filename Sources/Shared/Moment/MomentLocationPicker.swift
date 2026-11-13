import CoreLocation
import MapKit
import SwiftUI

/// Where a photo was taken, picked by hand on Apple Maps (no API key, nothing to pay). Search a
/// place or move the map so the pin sits on the spot. The picked position is shared as is;
/// see MomentShotInfo.shared.
struct MomentLocationPicker: View {
    /// Where the map starts (the current choice, the photo's GPS, or Seoul).
    var start: CLLocationCoordinate2D?
    var onPick: (CLLocationCoordinate2D, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var placeName: String?
    @State private var searching = false

    init(start: CLLocationCoordinate2D?, onPick: @escaping (CLLocationCoordinate2D, String?) -> Void) {
        self.start = start
        self.onPick = onPick
        let c = start ?? CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
        _center = State(initialValue: c)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: c, span: MKCoordinateSpan(latitudeDelta: start == nil ? 0.2 : 0.05,
                                              longitudeDelta: start == nil ? 0.2 : 0.05))))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                ZStack {
                    Map(position: $position)
                        .onMapCameraChange(frequency: .onEnd) { context in
                            center = context.region.center
                            Task { await describe(center) }
                        }
                    Image(systemName: "mappin")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.red)
                        .shadow(radius: 2)
                        .offset(y: -17)
                        .allowsHitTesting(false)
                    if !results.isEmpty { resultList }
                }
                footer
            }
            .navigationTitle("위치 고르기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("이 위치로") {
                        onPick(center, placeName)
                        dismiss()
                    }
                }
            }
            .task { await describe(center) }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("장소 검색 (예: 성수동, 남산타워)", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { Task { await search() } }
            if searching { ProgressView().controlSize(.small) }
            if !query.isEmpty {
                Button { query = ""; results = [] } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.bar)
    }

    private var resultList: some View {
        VStack {
            List(results, id: \.self) { item in
                Button {
                    let c = item.placemark.coordinate
                    position = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
                    center = c
                    placeName = item.name
                    results = []
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "이름 없는 장소")
                        if let address = item.placemark.title {
                            Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxHeight: 260)
            Spacer()
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text(placeName ?? "지도를 움직여 핀을 찍은 곳에 맞춰 주세요")
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text("고른 위치는 사진 정보(i)에서 다른 사람도 지도로 볼 수 있어요.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        results = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
    }

    /// "서울특별시 종로구" style name for the pin, for the footer and the upload form.
    private func describe(_ c: CLLocationCoordinate2D) async {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude),
                                                                   preferredLocale: Locale(identifier: "ko_KR"))
        guard let mark = marks?.first else { return }
        placeName = [mark.administrativeArea, mark.locality, mark.subLocality]
            .compactMap { $0 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " ")
    }
}
