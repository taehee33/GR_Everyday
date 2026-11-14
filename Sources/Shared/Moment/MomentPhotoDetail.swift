import CoreLocation
import SwiftUI

/// One of my photos, laid out like an Instagram post: whether it is on 순간들 above the photo;
/// heart, comments and camera under it; then the caption. Comments open in a sheet from below;
/// shot info and place are behind (i); sharing and deleting are in ⋯. Shot info is behind (i); sharing,
/// taking it off the feed and deleting are in the ⋯ menu.
struct MomentPhotoDetail: View {
    @ObservedObject var account: MomentAccount
    let photoID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnshare = false
    @State private var confirmDelete = false
    @State private var showInfo = false
    @State private var person: MomentPersonRef?
    @State private var viewing: MomentPhoto?
    @State private var viewHeight: CGFloat = 0
    @State private var showComments = false
    @StateObject private var comments: MomentComments

    init(account: MomentAccount, photoID: UUID) {
        self.account = account
        self.photoID = photoID
        _comments = StateObject(wrappedValue: MomentComments(store: account.store, photoID: photoID))
    }

    private var photo: MomentPhoto? { account.myPhotos.first { $0.id == photoID } }

    var body: some View {
        NavigationStack {
            Group {
                if let photo {
                    content(photo)
                } else {
                    Text("사진을 찾을 수 없어요.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("내 사진")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                if let photo {
                    ToolbarItemGroup(placement: .primaryAction) {
                        MomentInfoButton { showInfo = true }
                        moreMenu(photo)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    private func content(_ photo: MomentPhoto) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    statusLine(photo)
                    HStack(spacing: 10) {
                        MomentAvatarView(store: account.store, profile: account.me, size: 34)
                        Text(account.me?.handle ?? account.me?.displayName ?? "나").font(.subheadline.weight(.semibold))
                    }
                    MomentFullImage(store: account.store, photo: photo)
                        .momentOpensFullScreen { viewing = photo }
                }
                .momentDetailBand(viewHeight: viewHeight)

                HStack(spacing: 4) {
                    MomentHeartButton(liked: account.likedMine.contains(photo.id), count: photo.likeCount,
                                      enabled: account.me != nil && photo.status == .published) {
                        Task { await account.toggleLike(photo.id) }
                    }
                    MomentCommentButton(count: comments.list.count) { showComments = true }
                    Spacer(minLength: 8)
                    MomentShotTag(info: photo.info)
                }

                MomentCaptionBlock(handle: account.me?.handle ?? account.me?.displayName,
                                   caption: photo.caption, date: photo.sharedAt ?? photo.createdAt)

                if let message = account.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(16)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewHeight = $0 }
        .momentPhotoViewer($viewing, store: account.store)
        .task(id: photo.id) {
            await account.loadLike(photo.id)
            await comments.reload()
            await account.reloadPhotos()
        }
        .sheet(isPresented: $showComments) {
            MomentCommentsSheet(account: account, model: comments, photo: photo) { person = MomentPersonRef(id: $0) }
        }
        .sheet(item: $person) { ref in
            MomentPersonGallery(account: account, owner: ref.id)
        }
        .sheet(isPresented: $showInfo) {
            MomentInfoSheet(info: photo.info, sharedAt: photo.sharedAt)
        }
        .confirmationDialog("순간들 피드에서 내릴까요?", isPresented: $confirmUnshare, titleVisibility: .visible) {
            Button("피드에서 내리기", role: .destructive) { Task { await account.unshare(photo) } }
        } message: {
            Text("내 갤러리에는 그대로 남아요. 이번 달 공유 횟수는 돌아오지 않아요.")
        }
        .confirmationDialog("이 사진을 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                Task { if await account.delete(photo) { dismiss() } }
            }
        } message: {
            Text("내 갤러리와 피드에서 사라지고 되돌릴 수 없어요. 이번 달 공유 횟수는 돌아오지 않아요.")
        }
    }

    private func statusLine(_ photo: MomentPhoto) -> some View {
        HStack(spacing: 8) {
            if photo.status == .hidden {
                Label("신고가 쌓여 숨겨졌어요", systemImage: "eye.slash").foregroundStyle(.orange)
            } else if photo.isShared {
                Label("순간들에 공유됨", systemImage: "sparkles").foregroundStyle(.tint)
            } else {
                Label("내 갤러리에만 있어요", systemImage: "square.grid.2x2").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
    }

    private func moreMenu(_ photo: MomentPhoto) -> some View {
        Menu {
            if photo.status == .published {
                if photo.isShared {
                    Button { confirmUnshare = true } label: {
                        Label("피드에서 내리기", systemImage: "xmark.circle")
                    }
                } else {
                    let left = account.quota?.sharesLeft ?? 0
                    Button {
                        Task { await account.share(photo) }
                    } label: {
                        Label("순간들에 공유하기 · 이번 달 \(left)번 남음", systemImage: "sparkles")
                    }
                    .disabled(left == 0)
                }
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("삭제", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(account.busy)
        .accessibilityLabel("더 보기")
    }
}

/// The full view (3072 px), with the thumbnail blurred underneath until it arrives.
struct MomentFullImage: View {
    let store: MomentStore
    let photo: MomentPhoto

    var body: some View {
        AsyncImage(url: store.displayURL(photo)) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            AsyncImage(url: store.thumbURL(photo)) { image in
                image.resizable().scaledToFit().blur(radius: 2)
            } placeholder: {
                Rectangle().fill(.quaternary)
                    .aspectRatio(CGFloat(photo.width) / CGFloat(max(photo.height, 1)), contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

extension View {
    /// The top of a detail screen (the line above the photo and the photo): lowered toward the
    /// middle of the screen. It sits at the bottom of a band half the screen tall, so the
    /// buttons and caption follow right under the photo.
    func momentDetailBand(viewHeight: CGFloat) -> some View {
        frame(maxWidth: .infinity, minHeight: viewHeight > 0 ? viewHeight * 0.5 : nil, alignment: .bottomLeading)
    }

    /// A tap on the photo opens it full screen.
    func momentOpensFullScreen(_ onTap: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("전체 화면으로 봐요")
    }
}

/// "GR IV HDF · 스탠다드" (a film GR: "GR1v · Kodak Portra 400"), small and grey under the photo's right edge; the rest is behind (i).
struct MomentShotTag: View {
    let info: MomentShotInfo

    var body: some View {
        let parts = [info.camera, info.imageControl?.name ?? info.film].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The heart under a photo in a detail screen, with the count.
struct MomentHeartButton: View {
    let liked: Bool
    let count: Int
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(liked ? Color.red : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
                Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6).padding(.trailing, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(liked ? "좋아요 취소" : "좋아요")
        .accessibilityValue("\(count)개")
    }
}

/// Under the buttons: the username in bold, the caption on the next line, then
/// when it went up ("3시간 전", or the date after a week).
struct MomentCaptionBlock: View {
    let handle: String?
    let caption: String?
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption {
                if let handle {
                    Text(handle).fontWeight(.semibold)
                }
                Text(caption).textSelection(.enabled)
            }
            Group {
                if Date().timeIntervalSince(date) < 7 * 24 * 3600 {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text(date.formatted(date: .long, time: .omitted))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The speech bubble next to the heart; opens the comments.
struct MomentCommentButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.right").font(.title3)
                if count > 0 {
                    Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6).padding(.trailing, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("댓글 \(count)개")
    }
}

/// The (i) toolbar button that opens MomentInfoSheet.
struct MomentInfoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "info.circle") }
            .accessibilityLabel("촬영 정보")
    }
}

enum MomentPlace {
    /// Apple Maps at the shared (rounded) position, or a search for the place name when only a
    /// name was given. https works on iPhone, iPad and Mac and opens the Maps app.
    static func mapsURL(_ info: MomentShotInfo, name: String?) -> URL? {
        var items: [URLQueryItem] = []
        if let lat = info.lat, let lon = info.lon {
            items.append(URLQueryItem(name: "ll", value: "\(lat),\(lon)"))
            items.append(URLQueryItem(name: "z", value: "14"))
            items.append(URLQueryItem(name: "q", value: name ?? "촬영 위치"))
        } else if let place = info.place {
            items.append(URLQueryItem(name: "q", value: place))
        } else {
            return nil
        }
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = items
        return components.url
    }

    /// "서울특별시 용산구 한남동" for the rounded position; nil without coordinates or network.
    @MainActor static func area(_ info: MomentShotInfo) async -> String? {
        guard let lat = info.lat, let lon = info.lon else { return nil }
        let key = "\(lat),\(lon)"
        if let hit = cache[key] { return hit }
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon),
                                                                   preferredLocale: Locale(identifier: "ko_KR"))
        guard let mark = marks?.first else { return nil }
        let name = [mark.administrativeArea, mark.locality, mark.subLocality]
            .compactMap { $0 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " ")
        guard !name.isEmpty else { return nil }
        cache[key] = name
        return name
    }

    @MainActor private static var cache: [String: String] = [:]
}

/// The (i) sheet: everything the owner shared about the shot on one page, laid out like the
/// library's photo info: basic info, exposure one row each, then the image control with every
/// setting.
struct MomentInfoSheet: View {
    let info: MomentShotInfo
    var sharedAt: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var area: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                if info.isCameraDeclared {
                    Section {
                        ForEach(basic, id: \.0) { LabeledContent($0.0, value: $0.1) }
                    } header: {
                        Text("기본 정보")
                    } footer: {
                        Text("이 사진 파일에는 GR 촬영 정보(EXIF)가 없어서, 올린 사람이 카메라를 직접 골랐어요. 필름 GR 스캔본이나 GR DIGITAL 사진이 이렇게 올라와요.")
                    }
                } else {
                    section("기본 정보", basic)
                }
                section("노출", exposure)
                imageControl
                if let film = info.film {
                    Section("필름") { LabeledContent("필름", value: film) }
                }
                if let url = MomentPlace.mapsURL(info, name: info.place ?? area) {
                    Section("위치") {
                        Button { openURL(url) } label: {
                            LabeledContent {
                                Image(systemName: "map")
                            } label: {
                                Text(info.place ?? area ?? "지도에서 보기").foregroundStyle(.primary)
                            }
                        }
                    }
                }
                if basic.isEmpty, exposure.isEmpty, info.imageControl == nil, info.film == nil, info.lat == nil, info.place == nil {
                    Text("올린 사람이 촬영 정보를 공유하지 않았어요.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("촬영 정보")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .task {
            if info.place == nil { area = await MomentPlace.area(info) }
        }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows, id: \.0) { LabeledContent($0.0, value: $0.1) }
            }
        }
    }

    private var basic: [(String, String)] {
        var out: [(String, String)] = []
        if let camera = info.camera {
            out.append(("모델", camera))
            if info.isCameraDeclared { out.append(("카메라 정보", "직접 선택 · EXIF 아님")) }
        }
        if let date = info.takenAt { out.append(("촬영 일시", date.formatted(date: .long, time: .shortened))) }
        if let sharedAt { out.append(("공유한 날", sharedAt.formatted(date: .long, time: .omitted))) }
        return out
    }

    private var exposure: [(String, String)] {
        guard let e = info.exposure else { return [] }
        var out: [(String, String)] = []
        if let mode = e.mode { out.append(("노출 모드", mode)) }
        if let s = e.shutter { out.append(("셔터 속도", s)) }
        if let a = e.aperture { out.append(("조리개 값", String(format: "F%.1f", a))) }
        if let iso = e.iso { out.append(("ISO 감도", "ISO \(iso)")) }
        if let ev = e.ev { out.append(("노출 보정", ev == 0 ? "0.0" : String(format: "%+.1f", ev))) }
        if let f = e.focal35 { out.append(("초점 거리", "\(f)mm 상당")) }
        return out
    }

    @ViewBuilder private var imageControl: some View {
        if let c = info.imageControl {
            Section("이미지 컨트롤") {
                Text(c.name ?? "코드 \(c.code)").font(.headline)
                ForEach(Array(c.settings.enumerated()), id: \.offset) { _, s in
                    LabeledContent(s.name, value: s.value).padding(.leading, 12)
                }
                if let hdf = c.hdf { LabeledContent("HDF", value: hdf) }
            }
        }
    }
}
