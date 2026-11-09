import SwiftUI

/// 사진 → 이미지 컨트롤, like GR WORLD's 화상 컨트롤 tab: one row per image control on the
/// card with its newest shot and count; favourites first. Tapping a row shows those photos.
struct ImageControlList: View {
    @EnvironmentObject var library: LibraryModel
    /// Observed so rows appear as photos are read.
    @ObservedObject var stats: ShotStats
    let open: (Int) -> Void
    /// Favourite image controls by maker-note code, "262,268".
    @AppStorage("favoriteTones") private var favoritesText = ""
    @State private var favoritesOnly = false

    private var favorites: Set<Int> { Set(favoritesText.split(separator: ",").compactMap { Int($0) }) }

    var body: some View {
        let groups = library.toneGroups
        let shown = groups
            .filter { !favoritesOnly || favorites.contains($0.code) }
            .sorted { favorites.contains($0.code) && !favorites.contains($1.code) }
        ScrollView {
            VStack(spacing: 10) {
                if groups.isEmpty {
                    empty
                } else {
                    HStack {
                        Text("\(groups.count)가지 이미지 컨트롤").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Toggle(isOn: $favoritesOnly) { Label("즐겨찾기만", systemImage: "heart") }
                            .toggleStyle(.button).buttonBorderShape(.capsule).controlSize(.small)
                            .disabled(favorites.isEmpty)
                    }
                    ForEach(shown) { group in row(group) }
                }
                if stats.scanning {
                    Label("사진 \(stats.pending)장의 촬영 정보를 읽고 있어요", systemImage: "hourglass")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            .padding(16)
        }
        .onAppear { library.refreshStats() }
    }

    private func row(_ group: LibraryModel.ToneGroup) -> some View {
        let favorite = favorites.contains(group.code)
        return HStack(spacing: 14) {
            Thumb(photo: group.latest)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).font(.headline)
                Text("\(group.count)장").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { toggle(group.code) } label: {
                Image(systemName: favorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(favorite ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorite ? "즐겨찾기 해제" : "즐겨찾기")
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { open(group.code) }
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.filters").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(library.photos.isEmpty
                 ? "카메라를 연결하면 사진을 이미지 컨트롤별로 모아 볼 수 있어요."
                 : stats.scanning ? "촬영 정보를 읽고 있어요…" : "카메라에 연결하면 촬영 정보를 읽어 와요.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 100).padding(.horizontal, 24)
    }

    private func toggle(_ code: Int) {
        var set = favorites
        if set.contains(code) { set.remove(code) } else { set.insert(code) }
        favoritesText = set.sorted().map(String.init).joined(separator: ",")
    }
}

/// Camera → photos → phone, drawn with thin symbols, for the empty library.
struct ConnectIllustration: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "camera")
            Image(systemName: "arrow.right").font(.title3)
            Image(systemName: "photo.on.rectangle")
            Image(systemName: "arrow.right").font(.title3)
            Image(systemName: "iphone")
        }
        .font(.system(size: 40, weight: .ultraLight))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}
