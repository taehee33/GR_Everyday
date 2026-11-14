import SwiftUI
import MapKit
import CoreLocation

/// 탐색's 지역 filter. Two ways to pick:
/// - 목록: a 시·도 (or a country), then optionally a 시·군·구 (or a city) under it; on iPhone and
///   iPad also 내 주변 (about 3 km around where I am).
/// - 지도: where the photos are, as thumbnails on about 1 km cells (never an exact spot); the
///   map as it is when 이 범위 사진 보기 is pressed becomes the filter.
struct MomentExploreRegionSheet: View {
    @ObservedObject var feed: MomentFeed
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .list
    @State private var position: MapCameraPosition = .automatic
    @State private var visible: MKCoordinateRegion?
    @State private var locating = false
    @State private var problem: String?
    /// 국내 starts folded, 해외 open (unless what is picked now is in Korea).
    @State private var domesticOpen = false
    @State private var abroadOpen = true

    enum Mode: String, CaseIterable, Identifiable {
        case list = "목록", map = "지도"
        var id: String { rawValue }
    }

    /// Every 시·도, in the usual order.
    static let koreanRegions = ["서울", "부산", "대구", "인천", "광주", "대전", "울산", "세종",
                                "경기", "강원", "충북", "충남", "전북", "전남", "경북", "경남", "제주"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("보기", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16).padding(.vertical, 10)
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 6)
                }
                switch mode {
                case .list: list
                case .map: map
                }
            }
            .navigationTitle("지역")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
        .task { await feed.loadMap() }
        .onAppear {
            if let region = feed.query.region, Self.koreanRegions.contains(region) { domesticOpen = true }
            if let area = feed.query.area {
                mode = .map
                position = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: (area.minLat + area.maxLat) / 2, longitude: (area.minLon + area.maxLon) / 2),
                    span: MKCoordinateSpan(latitudeDelta: area.maxLat - area.minLat, longitudeDelta: area.maxLon - area.minLon)))
            }
        }
    }

    // MARK: List

    private var list: some View {
        let query = feed.query
        let counts = Dictionary(feed.facets.regions.map { ($0.value, $0.count) }, uniquingKeysWith: +)
        let shared = feed.facets.regions.map(\.value).filter { !Self.koreanRegions.contains($0) }
        let abroad = MomentRegion.abroadPresets.keys.sorted() + shared.filter { MomentRegion.abroadPresets[$0] == nil }
        return List {
            Section {
                row("전체", count: nil, on: query.region == nil && query.area == nil) { pick(region: nil, district: nil) }
                if let area = query.area {
                    row(area.label, count: nil, on: true) {}
                }
                #if os(iOS)
                Button { Task { await nearMe() } } label: {
                    HStack {
                        Label("내 주변 3km", systemImage: "location")
                        Spacer()
                        if locating { ProgressView() }
                    }
                }
                .disabled(locating)
                #endif
            }
            Section {
                DisclosureGroup(isExpanded: $domesticOpen) {
                    ForEach(Self.koreanRegions, id: \.self) { regionRow($0, count: counts[$0] ?? 0) }
                } label: {
                    groupLabel("국내")
                }
            }
            Section {
                DisclosureGroup(isExpanded: $abroadOpen) {
                    ForEach(abroad, id: \.self) { regionRow($0, count: counts[$0] ?? 0) }
                } label: {
                    groupLabel("해외")
                }
            }
        }
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title).font(.headline)
    }

    /// A 시·도 (or country): picks it, or opens to what is under it (시·군·구 with photos; for a
    /// country also its preset places, such as 도쿄 and 오사카 under 일본).
    @ViewBuilder private func regionRow(_ region: String, count: Int) -> some View {
        let query = feed.query
        let districts = MomentExploreView.options(MomentRegion.abroadPresets[region] ?? [],
                                                  feed.facets.districts.filter { $0.region == region })
        if districts.isEmpty {
            row(region, count: count, on: query.region == region && query.district == nil) { pick(region: region, district: nil) }
        } else {
            DisclosureGroup {
                row("\(region) 전체", count: count, on: query.region == region && query.district == nil) {
                    pick(region: region, district: nil)
                }
                ForEach(districts, id: \.value) { facet in
                    row(facet.value, count: facet.count, on: query.region == region && query.district == facet.value) {
                        pick(region: region, district: facet.value)
                    }
                }
            } label: {
                HStack {
                    Text(region)
                    Spacer()
                    if query.region == region { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
        }
    }

    private func row(_ title: String, count: Int?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(.tint) }
                if let count, count > 0 { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(region: String?, district: String?) {
        var query = feed.query
        query.region = region
        query.district = district
        query.area = nil
        feed.query = query
        dismiss()
    }

    // MARK: Map

    private var map: some View {
        let inside = visible.map { r in feed.mapCells.filter { Self.contains(r, $0) }.reduce(0) { $0 + $1.count } }
        return ZStack(alignment: .bottom) {
            Map(position: $position) {
                ForEach(Self.clusters(feed.mapCells, in: visible)) { cell in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: cell.lat, longitude: cell.lon)) {
                        MomentMapThumb(url: feed.store.thumbURL(cell.photo), count: cell.count)
                    }
                }
                #if os(iOS)
                UserAnnotation()
                #endif
            }
            .onMapCameraChange(frequency: .onEnd) { visible = $0.region }
            .overlay(alignment: .topTrailing) {
                #if os(iOS)
                Button { Task { await centerOnMe() } } label: {
                    Image(systemName: locating ? "location.fill" : "location")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .accessibilityLabel("내 위치로")
                #endif
            }
            Button {
                if let visible { applyArea(visible, label: "지도에서 고른 곳") }
            } label: {
                Text(inside.map { $0 > 0 ? "이 범위 사진 보기 · \($0)장" : "이 범위에는 사진이 없어요" } ?? "이 범위 사진 보기")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(MomentLikePlace.moment.tint, in: Capsule())
                    .foregroundStyle(Color(white: 0.08))
            }
            .buttonStyle(.plain)
            .disabled(visible == nil || inside == 0)
            .opacity(visible == nil || inside == 0 ? 0.6 : 1)
            .padding(16)
        }
    }

    /// Points close together on screen as one thumbnail (the busiest point's photo) with the
    /// total, so they never sit on top of each other when zoomed out.
    static func clusters(_ cells: [MomentMapCell], in region: MKCoordinateRegion?) -> [MomentMapCell] {
        guard let region else { return cells }
        let size = max(region.span.latitudeDelta / 9, 0.005)
        let groups = Dictionary(grouping: cells) { cell in
            "\(Int((cell.lat / size).rounded(.down))),\(Int((cell.lon / size).rounded(.down)))"
        }
        return groups.values.map { group in
            let top = group.max { $0.count < $1.count }!
            let total = group.reduce(0) { $0 + $1.count }
            let lat = group.reduce(0) { $0 + $1.lat * Double($1.count) } / Double(total)
            let lon = group.reduce(0) { $0 + $1.lon * Double($1.count) } / Double(total)
            return MomentMapCell(lat: lat, lon: lon, count: total, photo: top.photo)
        }
    }

    private static func contains(_ region: MKCoordinateRegion, _ cell: MomentMapCell) -> Bool {
        abs(cell.lat - region.center.latitude) <= region.span.latitudeDelta / 2
            && abs(cell.lon - region.center.longitude) <= region.span.longitudeDelta / 2
    }

    private func applyArea(_ region: MKCoordinateRegion, label: String) {
        var query = feed.query
        query.area = .init(minLat: region.center.latitude - region.span.latitudeDelta / 2,
                           maxLat: region.center.latitude + region.span.latitudeDelta / 2,
                           minLon: region.center.longitude - region.span.longitudeDelta / 2,
                           maxLon: region.center.longitude + region.span.longitudeDelta / 2,
                           label: label)
        query.region = nil
        query.district = nil
        feed.query = query
        dismiss()
    }

    // MARK: Near me (iPhone, iPad)

    #if os(iOS)
    /// About 3 km around where I am.
    private func nearMe() async {
        guard let here = await locate() else { return }
        let lat = 0.027
        let lon = lat / max(cos(here.latitude * .pi / 180), 0.1)
        applyArea(MKCoordinateRegion(center: here, span: MKCoordinateSpan(latitudeDelta: lat * 2, longitudeDelta: lon * 2)),
                  label: "내 주변 3km")
    }

    private func centerOnMe() async {
        guard let here = await locate() else { return }
        withAnimation { position = .region(MKCoordinateRegion(center: here, latitudinalMeters: 6000, longitudinalMeters: 6000)) }
    }

    private func locate() async -> CLLocationCoordinate2D? {
        locating = true
        problem = nil
        defer { locating = false }
        do {
            return try await MomentOneShotLocation().current()
        } catch {
            problem = "지금 위치를 알 수 없어요. 설정 › 개인정보 보호 › 위치 서비스에서 GR Everyday를 허용해 주세요."
            return nil
        }
    }
    #endif
}

/// A photo's thumbnail on the map, with how many photos are around it.
private struct MomentMapThumb: View {
    let url: URL
    let count: Int

    var body: some View {
        MomentRemoteImage(url: url, contentMode: .fill)
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color(white: 0.08))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(MomentLikePlace.moment.tint, in: Capsule())
                        .offset(x: 6, y: -6)
                }
            }
    }
}

#if os(iOS)
/// Asks for when-in-use permission if needed, then reads the location once.
@MainActor
private final class MomentOneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocationCoordinate2D, Error>?

    struct Denied: Error {}

    func current() async throws -> CLLocationCoordinate2D {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        return try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: finish(.failure(Denied()))
            default: manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Error>) {
        waiting?.resume(with: result)
        waiting = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted: finish(.failure(Denied()))
            default: if waiting != nil { manager.requestLocation() }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let here = locations.last?.coordinate else { return }
        Task { @MainActor in finish(.success(here)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in finish(.failure(error)) }
    }
}
#endif
