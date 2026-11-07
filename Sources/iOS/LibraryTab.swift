import SwiftUI

/// The card's photos by day. Tap to view; 선택 to pick several and save them to the Photos app.
struct LibraryTab: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var connection: ConnectionModel
    @State private var selecting = false
    @State private var viewing: Photo?
    @AppStorage("iosThumbSize") private var thumbSize = 100.0

    private var online: Bool { connection.isConnected }

    var body: some View {
        NavigationStack {
            Group {
                if library.photos.isEmpty {
                    if online && library.isLoading {
                        ProgressView("사진 목록 읽는 중…")
                    } else {
                        ContentUnavailableView("사진 없음", systemImage: "photo.on.rectangle",
                                               description: Text(online ? "카메라에 사진이 없습니다." : "카메라에 한 번 연결하면 카메라 없이도 목록을 볼 수 있습니다."))
                    }
                } else {
                    grid
                }
            }
            .navigationTitle("라이브러리")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .top) { if !online && !library.photos.isEmpty { offlineBanner } }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .refreshable { if online { await library.reload() } }
            .fullScreenCover(item: $viewing) { photo in
                PhotoPager(start: photo, photos: library.visible)
            }
            .alert("저장 실패", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(library.error ?? "")
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 2)], spacing: 2,
                      pinnedViews: [.sectionHeaders]) {
                ForEach(library.sections) { section in
                    Section {
                        ForEach(section.photos) { photo in
                            Thumb(photo: photo, selecting: selecting)
                                .onTapGesture {
                                    if selecting { library.toggle(photo) } else { viewing = photo }
                                }
                        }
                    } header: {
                        if !section.title.isEmpty {
                            HStack {
                                Text(section.title).font(.subheadline.bold())
                                Text("\(section.photos.count)장").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if selecting {
                                    Button("이 날짜 선택") { library.selection.formUnion(section.photos.map(\.id)) }
                                        .font(.caption)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.bar)
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("보기", selection: $library.filter) {
                    ForEach(LibraryModel.Filter.allCases) { f in
                        Text("\(f.rawValue) (\(library.count(f)))").tag(f)
                    }
                }
                Picker("정렬", selection: $library.sort) {
                    ForEach(LibraryModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("날짜별로 묶기", isOn: $library.groupByDate)
                Picker("크기", selection: $thumbSize) {
                    Text("작게").tag(76.0)
                    Text("보통").tag(100.0)
                    Text("크게").tag(150.0)
                }
            } label: {
                Label(library.filter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(selecting ? "완료" : "선택") {
                selecting.toggle()
                if !selecting { library.clearSelection() }
            }
            .disabled(library.photos.isEmpty)
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if !library.transfers.isEmpty {
            TransferBar()
        } else if selecting {
            HStack {
                Menu("선택") {
                    Button("전체 선택") { library.selectAll() }
                    Button("미저장만 선택") { library.selectUnsaved() }
                    Button("선택 해제") { library.clearSelection() }
                }
                Spacer()
                Button {
                    library.save(library.visible.filter { library.selection.contains($0.id) })
                    selecting = false
                } label: {
                    Text(library.selection.isEmpty ? "사진 앱에 저장" : "사진 앱에 저장 (\(library.selection.count))")
                }
                .buttonStyle(.borderedProminent)
                .disabled(library.selection.isEmpty || !online)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var offlineBanner: some View {
        let when = library.listSavedAt.map { $0.formatted(date: .abbreviated, time: .shortened) }
        return Label("카메라 연결 안 됨" + (when.map { " · \($0)에 본 목록" } ?? ""), systemImage: "camera.badge.ellipsis")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.bar)
    }
}

/// A square tile; the camera's own small thumbnail, kept on disk.
struct Thumb: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    var selecting = false
    @State private var image: PlatformImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(platformImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if photo.kind == .raw { badge("RAW") }
                    if photo.kind == .video { Image(systemName: "video.fill").font(.caption2) }
                    if library.saved.contains(photo.name) { Image(systemName: "checkmark.circle.fill").font(.caption2) }
                }
                .foregroundStyle(.white).shadow(radius: 2)
                .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: library.selection.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(library.selection.contains(photo.id) ? Color.accentColor : .white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .task(id: "\(photo.id)#\(library.orientation(photo))") {
                image = await ImageCache.shared.image(for: CameraAPI.photoURL(photo, size: .thumb),
                                                      orientation: library.orientation(photo))
            }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Swipe through the photos; the camera's larger preview, or the saved file.
struct PhotoPager: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    let start: Photo
    let photos: [Photo]
    @State private var current: Photo.ID?

    var body: some View {
        NavigationStack {
            TabView(selection: $current) {
                ForEach(photos) { photo in
                    PhotoPage(photo: photo).tag(Optional(photo.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(.black)
            .navigationTitle(photos.first { $0.id == current }?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    if let photo = photos.first(where: { $0.id == current }) {
                        if library.saved.contains(photo.name) {
                            Text("저장됨 ✓").foregroundStyle(.secondary)
                        } else {
                            Button("사진 앱에 저장") { library.save([photo]) }
                                .disabled(!connection.isConnected || library.isTransferring)
                        }
                    }
                }
            }
        }
        .onAppear { current = start.id }
    }
}

struct PhotoPage: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(platformImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
            if photo.kind == .video {
                Label("동영상은 저장한 뒤 사진 앱에서 재생하세요", systemImage: "video")
                    .font(.footnote).padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom).padding()
            }
        }
        .task(id: photo.id) {
            let orientation = library.orientation(photo)
            image = await ImageCache.shared.image(for: CameraAPI.photoURL(photo, size: .thumb), orientation: orientation)
            if let local = library.localURL(photo), photo.kind != .video,
               let data = try? Data(contentsOf: local), let full = PlatformImage(data: data) {
                image = full
            } else if let preview = await ImageCache.shared.image(for: CameraAPI.photoURL(photo, size: .view), orientation: orientation) {
                image = preview
            }
        }
    }
}

/// Saving progress above the tab bar.
struct TransferBar: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        let done = library.transfers.filter { if case .done = $0.status { return true } else { return false } }.count
        let failed = library.transfers.filter { if case .failed = $0.status { return true } else { return false } }.count
        HStack {
            if library.isTransferring {
                ProgressView(value: Double(done), total: Double(max(library.transfers.count, 1)))
                Text("\(done)/\(library.transfers.count)").font(.caption.monospacedDigit())
                Button("취소") { library.cancelTransfers() }
            } else {
                Label(failed == 0 ? "\(done)장을 사진 앱에 저장했습니다" : "\(done)장 저장, \(failed)장 실패",
                      systemImage: failed == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout)
                Spacer()
                Button("닫기") { library.dismissTransfers() }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}
