import SwiftUI

/// The card's photos by day. Tap to view; 선택 to pick several and save them to the Photos app.
struct LibraryTab: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var connection: ConnectionModel
    @State private var selecting = false
    @State private var viewing: Photo?
    @State private var showFilter = false
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
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if !online && !library.photos.isEmpty { offlineBanner }
                    if library.refine.isActive { filterBanner }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .refreshable { if online { await library.reload() } }
            .sheet(isPresented: $showFilter) { FilterSheet() }
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
                        if !section.title.isEmpty { header(section) }
                    }
                }
            }
        }
    }

    /// Day title and count; the circle selects the whole day (and starts selecting).
    private func header(_ section: LibraryModel.DaySection) -> some View {
        let ids = Set(section.photos.map(\.id))
        let all = ids.isSubset(of: library.selection)
        let some = !all && !ids.isDisjoint(with: library.selection)
        return HStack {
            Text(section.title).font(.subheadline.bold())
            Text("\(section.photos.count)장").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                selecting = true
                library.toggleSection(section.photos)
            } label: {
                Image(systemName: all ? "checkmark.circle.fill" : some ? "minus.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(all || some ? Color.accentColor : .secondary)
            }
            .accessibilityLabel(all ? "이 날짜 선택 해제" : "이 날짜 모두 선택")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showFilter = true } label: {
                Label("필터", systemImage: library.refine.isActive
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .disabled(library.photos.isEmpty)
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
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
                Label("보기", systemImage: "arrow.up.arrow.down.circle")
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
            HStack(spacing: 12) {
                Button {
                    library.clearSelection()
                    selecting = false
                } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 32, height: 32)
                }
                .accessibilityLabel("선택 끝내기")
                Menu {
                    Button("전체 선택") { library.selectAll() }
                    Button("미저장만 선택") { library.selectUnsaved() }
                    Button("선택 해제") { library.clearSelection() }
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(library.selection.count)장 선택").font(.subheadline.bold())
                        if let size = selectedSize { Text(size).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .foregroundStyle(.primary)
                Spacer()
                Button {
                    library.save(library.visible.filter { library.selection.contains($0.id) })
                    selecting = false
                } label: {
                    Label("사진 앱에 저장", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(library.selection.isEmpty || !online)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// Total size of the selected files, from the camera's per-photo info.
    private var selectedSize: String? {
        let sizes = library.selection.compactMap { library.infos[$0]?.extras["size"].flatMap(Int64.init) }
        guard !sizes.isEmpty else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)
    }

    /// What the filter keeps, how many, and a way out.
    private var filterBanner: some View {
        let r = library.refine
        var parts: [String] = []
        if let kind = r.kind { parts.append(kind == .video ? "동영상" : kind.rawValue) }
        if r.saved != .all { parts.append(r.saved.rawValue) }
        let day = { (d: Date) in d.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) }
        if r.from != nil || r.to != nil { parts.append("\(r.from.map(day) ?? "")~\(r.to.map(day) ?? "")") }
        return HStack {
            Button { showFilter = true } label: {
                Label(parts.joined(separator: " · ") + " · \(library.visible.count)장", systemImage: "line.3.horizontal.decrease.circle.fill")
                    .lineLimit(1)
            }
            Spacer()
            Button("해제") { library.refine = LibraryModel.Refine() }
        }
        .font(.footnote)
        .padding(.horizontal).padding(.vertical, 6)
        .background(.bar)
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
                image = await ImageCache.shared.image(for: library.thumbURL(photo),
                                                      orientation: library.orientation(photo))
            }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Swipe through the photos like the Photos app: the photo fills the screen behind
/// see-through bars, a tap hides everything but the photo, and dragging down returns to
/// the library. The camera's larger preview, or the saved file.
struct PhotoPager: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    let start: Photo
    let photos: [Photo]
    @State private var current: Photo.ID?
    @State private var chrome = true
    /// The current photo is zoomed in: its pans are for moving around, not closing.
    @State private var zoomed = false
    /// How far the photo has been dragged down; past the threshold it closes.
    @State private var drag: CGSize = .zero
    /// The (i) sheet: EXIF and shooting settings of the photo shown.
    @State private var showInfo = false

    private var currentPhoto: Photo? { photos.first { $0.id == current } }
    /// 0 at rest, 1 when dragged far enough to close.
    private var pull: CGFloat { min(max(drag.height, 0) / 300, 1) }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - pull).ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(photos) { photo in
                    PhotoPage(photo: photo, zoomed: $zoomed) {
                        withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() }
                    }
                    .tag(Optional(photo.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .scaleEffect(1 - pull * 0.3)
            .offset(x: drag.width * pull, y: max(drag.height, 0))
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // Only a mostly downward drag; sideways is for the next photo.
                        guard !zoomed, value.translation.height > abs(value.translation.width) || drag != .zero else { return }
                        drag = value.translation
                    }
                    .onEnded { value in
                        if drag.height > 120 || value.predictedEndTranslation.height > 400 {
                            dismiss()
                        } else {
                            withAnimation(.spring(duration: 0.3)) { drag = .zero }
                        }
                    }
            )
            if chrome && drag == .zero {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .presentationBackground(.clear)
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .onAppear { current = start.id }
        .sheet(isPresented: $showInfo) {
            if let photo = currentPhoto { PhotoInfoSheet(photo: photo) }
        }
    }

    /// What the photo shown is, when it isn't the camera's live copy.
    private var caption: String? {
        guard let photo = currentPhoto else { return nil }
        if library.localURL(photo) != nil, photo.kind != .video { return "\(Device.name)에 저장된 원본" }
        if !connection.isConnected { return "카메라 연결 안 됨 · 지난 연결 때 받아 둔 작은 미리보기" }
        return nil
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.headline).frame(width: 36, height: 36)
            }
            Spacer()
            VStack(spacing: 1) {
                Text(currentPhoto?.name ?? "").font(.headline)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.headline).frame(width: 36, height: 36)
            }
            .disabled(currentPhoto == nil)
        }
        .foregroundStyle(.white)
        .padding(.horizontal).padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.8), in: Rectangle())
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var bottomBar: some View {
        if let photo = currentPhoto {
            HStack {
                if library.saved.contains(photo.name) {
                    Label("사진 앱에 저장됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button { library.save([photo]) } label: {
                        Label("사진 앱에 저장", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!connection.isConnected || library.isTransferring)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial.opacity(0.8), in: Rectangle())
            .environment(\.colorScheme, .dark)
        }
    }
}

struct PhotoPage: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    @Binding var zoomed: Bool
    let onTap: () -> Void
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                // Fit to the whole screen, under the bars: full height in landscape.
                ZoomablePhoto(image: image, zoomed: $zoomed, onTap: onTap)
                    .ignoresSafeArea()
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
            image = await ImageCache.shared.image(for: library.thumbURL(photo), orientation: orientation)
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

/// Pinch and double-tap zoom with UIScrollView, as in the Photos app. A single tap (one
/// that isn't the start of a double tap) goes to `onTap`.
struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomed: Bool
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PhotoScrollView {
        let scroll = PhotoScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.imageView.image = image
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        scroll.addGestureRecognizer(double)
        scroll.addGestureRecognizer(single)
        return scroll
    }

    func updateUIView(_ scroll: PhotoScrollView, context: Context) {
        context.coordinator.parent = self
        if scroll.imageView.image !== image {
            scroll.imageView.image = image
            scroll.setZoomScale(1, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomablePhoto
        init(_ parent: ZoomablePhoto) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? PhotoScrollView)?.imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.01
            if zoomed != parent.zoomed { DispatchQueue.main.async { self.parent.zoomed = zoomed } }
        }

        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = tap.location(in: (scroll as? PhotoScrollView)?.imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }

        @objc func singleTap() { parent.onTap() }
    }
}

/// The scroll view holding one photo, fitted to the screen while not zoomed.
final class PhotoScrollView: UIScrollView {
    let imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= 1.001, imageView.frame.size != bounds.size {
            imageView.frame = bounds
            contentSize = bounds.size
        }
    }
}
