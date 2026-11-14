import SwiftUI
import UniformTypeIdentifiers

/// 내 갤러리: my photos in one of two views, picked at the top and kept on the server
/// (profiles.wall_style): 갤러리, framed photos hung on a long wall that I arrange by hand, or
/// 그리드, three square columns like an Instagram profile.
struct MomentWallView: View {
    @ObservedObject var account: MomentAccount
    var onUpload: () -> Void
    @State private var editing = false
    @State private var draft: [UUID: WallItem] = [:]
    @State private var draftDirection: MomentProfile.WallDirection = .vertical
    @State private var selected: UUID?
    @State private var drag: (id: UUID, translation: CGSize)?
    @State private var pinch: (id: UUID, scale: CGFloat)?
    @State private var opened: MomentPhoto?
    @State private var width: CGFloat = 0
    @State private var fullScreen = false
    /// 그리드 순서 편집: the photos in the order being arranged, nil when not editing.
    @State private var gridDraft: [UUID]?

    private var style: MomentProfile.WallStyle { account.me?.wallStyle ?? .grid }
    private var direction: MomentProfile.WallDirection {
        editing ? draftDirection : account.me?.wallDirection ?? .vertical
    }
    private var photos: [MomentPhoto] { account.myPhotos }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if editing { editBar } else if gridDraft != nil { gridEditBar } else { viewBar }
            }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            if style == .grid {
                MomentProfileGrid(store: account.store, photos: account.myPhotos, items: account.wallItems,
                                  canUpload: gridDraft == nil && account.quota?.wallFull != true,
                                  onUpload: onUpload, reorder: $gridDraft) { opened = $0 }
            } else if photos.isEmpty {
                Text("아직 올린 사진이 없어요. 사진을 업로드하면 여기 벽에 액자로 걸려요.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                gallery
            }
        }
        .frame(maxWidth: .infinity)
        // While frames are being moved, sideways drags on the wall belong to them.
        .momentNoRoomSwipe(editing || gridDraft != nil)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .momentPhotoOpen(item: $opened, alone: style == .free) { photo in
            MomentPhotoDetail(account: account, photoID: photo.id)
        } paged: { photo in
            pager(photo)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $fullScreen) { fullScreenWall }
        #else
        .sheet(isPresented: $fullScreen) {
            fullScreenWall
                .frame(minWidth: 1000, idealWidth: 1280, minHeight: 700, idealHeight: 820)
        }
        #endif
    }

    private var fullScreenWall: some View {
        MomentWallFullScreen(store: account.store, photos: account.myPhotos, items: account.wallItems,
                             direction: account.me?.wallDirection ?? .vertical,
                             title: [account.me?.displayName, account.me?.handle].compactMap { $0 }.joined(separator: "  ")) { photo in
            MomentPhotoDetail(account: account, photoID: photo.id)
        }
    }

    /// The photo full screen; from 그리드, with my other photos above and below it in grid order.
    private func pager(_ photo: MomentPhoto) -> some View {
        MomentGalleryPager(title: "내 사진",
                           ids: MomentGalleryOrder.ids(account.myPhotos, items: account.wallItems,
                                                       style: style, direction: account.me?.wallDirection ?? .vertical),
                           start: photo.id) { id, isCurrent in
            MomentPhotoDetail(account: account, photoID: id, paged: true, isCurrent: isCurrent)
        } actions: { id in
            MomentMyPhotoActions(account: account, photoID: id)
        }
    }

    // MARK: Bars

    private var viewBar: some View {
        HStack(spacing: 12) {
            Picker("보기", selection: Binding(get: { style }, set: { new in
                Task { await account.saveWall(style: new, direction: direction, items: []) }
            })) {
                Label("갤러리", systemImage: "photo.artframe").tag(MomentProfile.WallStyle.free)
                Label("그리드", systemImage: "square.grid.3x3").tag(MomentProfile.WallStyle.grid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            Spacer()
            if style == .free, !photos.isEmpty {
                Button { fullScreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("전체화면으로 보기")
                .help("전체화면으로 보기")
                Button("편집") { startEditing() }
                    .buttonStyle(.bordered)
            } else if style == .grid, photos.count > 1 {
                Button("순서 편집") {
                    withAnimation(.snappy) {
                        gridDraft = MomentProfileGrid.ordered(photos, items: account.wallItems).map(\.id)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var gridEditBar: some View {
        HStack(spacing: 10) {
            Text("사진을 길게 눌러 원하는 자리로 끌어요.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("취소") { withAnimation(.snappy) { gridDraft = nil } }
            Button("완료") { finishGridEditing() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Saves the arranged order as each photo's grid_order (0 first), keeping its place on the wall.
    private func finishGridEditing() {
        guard let order = gridDraft else { return }
        let items = order.enumerated().map { index, id in
            var item = account.wallItems[id] ?? WallItem(photoID: id)
            item.gridOrder = index
            return item
        }
        Task {
            if await account.saveWall(style: .grid, direction: account.me?.wallDirection ?? .vertical, items: items) {
                withAnimation(.snappy) { gridDraft = nil }
            }
        }
    }

    private var editBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("방향", selection: Binding(get: { draftDirection }, set: { new in
                    guard new != draftDirection else { return }
                    draftDirection = new
                    // Turned walls need new places: lay them out again for this direction.
                    draft = Dictionary(uniqueKeysWithValues: geometry.arranged(photos).map { ($0.photoID, $0) })
                    selected = nil
                })) {
                    Label("세로로 길게", systemImage: "arrow.up.and.down").tag(MomentProfile.WallDirection.vertical)
                    Label("가로로 길게", systemImage: "arrow.left.and.right").tag(MomentProfile.WallDirection.horizontal)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer(minLength: 0)
                Button("취소") { stopEditing() }
                Button("완료") { finishEditing() }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 12) {
                if let id = selected, draft[id] != nil {
                    Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { draft[id]?.width ?? 0.4 }, set: { new in
                        guard var item = draft[id], let photo = photo(id) else { return }
                        item.width = new
                        draft[id] = geometry.fitted(item, photo)
                    }), in: 0.15...0.9)
                    .frame(maxWidth: 240)
                    Image(systemName: "photo").font(.body).foregroundStyle(.secondary)
                } else {
                    Text("사진을 끌어 옮기고, 두 손가락으로 크기를 바꿔요. 누르면 크기 막대가 나와요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    draft = Dictionary(uniqueKeysWithValues: geometry.arranged(photos).map { ($0.photoID, $0) })
                    selected = nil
                } label: {
                    Label("자동 배치", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderless)
                .font(.footnote)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Gallery

    private var geometry: WallGeometry {
        let unit: CGFloat
        if direction == .vertical {
            unit = max(min(width, 820), 200)
        } else {
            #if os(iOS)
            unit = UIDevice.current.userInterfaceIdiom == .phone ? 400 : 580
            #else
            unit = 580
            #endif
        }
        return WallGeometry(unit: unit, direction: direction)
    }

    private func photo(_ id: UUID) -> MomentPhoto? { photos.first { $0.id == id } }

    /// The frames as drawn right now: the draft while editing (with a drag or pinch in progress
    /// applied), otherwise the saved wall with any unhung photos laid out after it.
    private var shownItems: [WallItem] {
        let geo = geometry
        let base = editing ? Array(draft.values) : geo.resolved(photos, items: account.wallItems)
        return base.compactMap { item in
            guard let photo = photo(item.photoID) else { return nil }
            return live(item, photo, geo)
        }
        .sorted { $0.z < $1.z }
    }

    private func live(_ item: WallItem, _ photo: MomentPhoto, _ geo: WallGeometry) -> WallItem {
        var item = item
        if let drag, drag.id == item.photoID {
            let move = geo.units(drag.translation)
            item.x += move.across
            item.y += move.along
        }
        if let pinch, pinch.id == item.photoID {
            item.width *= Double(pinch.scale)
        }
        return geo.fitted(item, photo)
    }

    private var gallery: some View {
        let geo = geometry
        let items = shownItems
        let length = max(items.compactMap { item in
            photo(item.photoID).map { item.y + geo.along(geo.size($0, width: item.width)) }
        }.max() ?? 0, 0.6) + 0.08
        let canvas = ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.04))
                .contentShape(Rectangle())
                .onTapGesture { selected = nil }
            ForEach(items, id: \.photoID) { item in
                if let photo = photo(item.photoID) {
                    frame(photo, item, geo)
                }
            }
        }
        .frame(width: geo.direction == .vertical ? geo.unit : CGFloat(length) * geo.unit,
               height: geo.direction == .vertical ? CGFloat(length) * geo.unit : geo.unit,
               alignment: .topLeading)

        return Group {
            if geo.direction == .vertical {
                // An overlay never sizes its parent, so the wall cannot make the page wider than
                // the screen (its width is measured from the page; turning the phone back from
                // landscape would otherwise keep the old, wider size).
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: CGFloat(length) * geo.unit)
                    .overlay(alignment: .top) { canvas }
            } else {
                ScrollView(.horizontal, showsIndicators: false) { canvas }
                    .frame(height: geo.unit)
                    .scrollClipDisabled()
            }
        }
        .animation(.snappy(duration: 0.3), value: editing ? draftDirection : direction)
    }

    @ViewBuilder
    private func frame(_ photo: MomentPhoto, _ item: WallItem, _ geo: WallGeometry) -> some View {
        let size = geo.size(photo, width: item.width)
        let origin = geo.origin(item)
        let view = WallFrame(store: account.store, photo: photo, size: size,
                             selected: editing && selected == photo.id)
            .offset(x: origin.x, y: origin.y)
        if editing {
            view
                .highPriorityGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            select(photo.id)
                            drag = (photo.id, value.translation)
                        }
                        .onEnded { value in
                            drag = (photo.id, value.translation)
                            commit(photo, geo)
                            drag = nil
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            select(photo.id)
                            pinch = (photo.id, value.magnification)
                        }
                        .onEnded { value in
                            pinch = (photo.id, value.magnification)
                            commit(photo, geo)
                            pinch = nil
                        }
                )
        } else {
            view.onTapGesture { opened = photo }
        }
    }

    /// Selects a frame and brings it to the front.
    private func select(_ id: UUID) {
        if selected != id { selected = id }
        let top = draft.values.map(\.z).max() ?? 0
        if let z = draft[id]?.z, z < top || draft.values.filter({ $0.z == top }).count > 1 {
            draft[id]?.z = top + 1
        }
    }

    private func commit(_ photo: MomentPhoto, _ geo: WallGeometry) {
        guard let item = draft[photo.id] else { return }
        draft[photo.id] = live(item, photo, geo)
    }

    private func startEditing() {
        draftDirection = account.me?.wallDirection ?? .vertical
        let geo = WallGeometry(unit: geometry.unit, direction: draftDirection)
        draft = Dictionary(uniqueKeysWithValues: geo.resolved(photos, items: account.wallItems).map { ($0.photoID, $0) })
        selected = nil
        withAnimation(.snappy) { editing = true }
    }

    private func stopEditing() {
        withAnimation(.snappy) { editing = false }
        draft = [:]
        selected = nil
    }

    private func finishEditing() {
        let items = Array(draft.values)
        let direction = draftDirection
        Task {
            if await account.saveWall(style: .free, direction: direction, items: items) {
                stopEditing()
            }
        }
    }
}

/// Where frames hang on a gallery wall, in points, for a wall whose short side is `unit`
/// points. Positions are stored in units of that side (WallItem), across (x) and along (y).
struct WallGeometry {
    let unit: CGFloat
    let direction: MomentProfile.WallDirection

    /// The white mat around the photo, as a share of the frame's width.
    static let mat: CGFloat = 0.045
    /// Caption line under a frame, gap included.
    static let caption: CGFloat = 22

    /// Frame (mat included) plus caption, for `photo` hung `width` units wide.
    func size(_ photo: MomentPhoto, width: Double) -> CGSize {
        let outer = CGFloat(width) * unit
        let mat = outer * Self.mat
        let ratio = CGFloat(photo.height) / CGFloat(max(photo.width, 1))
        let height = (outer - 2 * mat) * ratio + 2 * mat + (photo.caption == nil ? 0 : Self.caption)
        return CGSize(width: outer, height: height)
    }

    func across(_ size: CGSize) -> Double {
        Double((direction == .vertical ? size.width : size.height) / unit)
    }

    func along(_ size: CGSize) -> Double {
        Double((direction == .vertical ? size.height : size.width) / unit)
    }

    func origin(_ item: WallItem) -> CGPoint {
        direction == .vertical
            ? CGPoint(x: item.x * unit, y: item.y * unit)
            : CGPoint(x: item.y * unit, y: item.x * unit)
    }

    /// A drag on screen as a move across and along the wall, in units.
    func units(_ translation: CGSize) -> (across: Double, along: Double) {
        direction == .vertical
            ? (Double(translation.width / unit), Double(translation.height / unit))
            : (Double(translation.height / unit), Double(translation.width / unit))
    }

    /// Keeps a frame on the wall: not too small, shrunk if it cannot fit across, slid inside.
    func fitted(_ item: WallItem, _ photo: MomentPhoto) -> WallItem {
        var item = item
        item.width = min(max(item.width, 0.12), 0.95)
        var span = across(size(photo, width: item.width))
        if span > 0.96 {
            item.width *= 0.96 / span
            span = across(size(photo, width: item.width))
        }
        item.x = min(max(item.x, 0), max(1 - span, 0))
        item.y = max(item.y, 0)
        return item
    }

    /// Hangs `photos` in two staggered lanes, each next photo in the lane that ends first.
    func arranged(_ photos: [MomentPhoto], from start: Double = 0.05, z: Int = 0) -> [WallItem] {
        let lanes = [0.05, 0.52]
        let laneSpan = 0.43
        var ends = [start, start + (direction == .vertical ? 0.14 : 0.2)]
        var items: [WallItem] = []
        for (index, photo) in photos.enumerated() {
            let lane = ends[0] <= ends[1] ? 0 : 1
            var width = laneSpan
            if direction == .horizontal {
                // Across is the frame's height here: pick the width whose height fills the lane.
                let caption = Double((photo.caption == nil ? 0 : Self.caption) / unit)
                let perWidth = across(size(photo, width: 1)) - caption
                width = min(0.9, max(0.15, (laneSpan - caption) / max(perWidth, 0.1)))
            }
            let item = fitted(WallItem(photoID: photo.id, x: lanes[lane], y: ends[lane],
                                       width: width, z: z + index), photo)
            ends[lane] = item.y + along(size(photo, width: item.width)) + 0.06
            items.append(item)
        }
        return items
    }

    /// The wall as it should look: frames hung by hand where they are, then the photos nobody
    /// has hung yet (new uploads) laid out after them.
    func resolved(_ photos: [MomentPhoto], items: [UUID: WallItem]) -> [WallItem] {
        var placed: [WallItem] = []
        var waiting: [MomentPhoto] = []
        for photo in photos {
            if let item = items[photo.id], !Self.isUnhung(item) {
                placed.append(fitted(item, photo))
            } else {
                waiting.append(photo)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        let end = placed.compactMap { item in
            byID[item.photoID].map { item.y + along(size($0, width: item.width)) }
        }.max()
        let top = (placed.map(\.z).max() ?? 0) + 1
        return placed + arranged(waiting, from: end.map { $0 + 0.08 } ?? 0.05, z: top)
    }

    /// True for the spot the server gives a new upload (three across, rows 0.3 apart, 0.3
    /// wide): a photo that has not been hung by hand yet.
    static func isUnhung(_ item: WallItem) -> Bool {
        let column = item.x / 0.34
        let row = item.y / 0.3
        return abs(item.width - 0.3) < 0.0005 && item.rotation == 0
            && abs(column - column.rounded()) < 0.002 && abs(row - row.rounded()) < 0.002
    }
}

/// One framed photo: white mat, hairline edge, soft shadow, and its caption underneath.
struct WallFrame: View {
    let store: MomentStore
    let photo: MomentPhoto
    let size: CGSize
    let selected: Bool

    var body: some View {
        let mat = size.width * WallGeometry.mat
        let imageWidth = size.width - 2 * mat
        let imageHeight = imageWidth * CGFloat(photo.height) / CGFloat(max(photo.width, 1))
        VStack(alignment: .leading, spacing: 0) {
            // The 600 px thumbnail is enough up to ~220 pt; larger frames load the full view.
            MomentRemoteImage(url: size.width > 220 ? store.displayURL(photo) : store.thumbURL(photo),
                              preview: size.width > 220 ? store.thumbURL(photo) : nil,
                              contentMode: .fill, showsProgress: false)
            .frame(width: imageWidth, height: imageHeight)
            .clipped()
            .padding(mat)
            .background(Color.white)
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
            if let caption = photo.caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: size.width, height: WallGeometry.caption, alignment: .bottomLeading)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .overlay {
            if selected {
                Rectangle()
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(-6)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(photo.caption ?? "사진")
        .accessibilityAddTraits(.isButton)
    }
}

/// 그리드: three square columns, newest first, like an Instagram profile; the last cell hangs a
/// new photo while the wall has room.
struct MomentProfileGrid: View {
    let store: MomentStore
    let photos: [MomentPhoto]
    let items: [UUID: WallItem]
    /// Shows the "+" cell (my own gallery with room left).
    var canUpload = false
    var onUpload: () -> Void = {}
    /// While arranging (my own gallery), the order being made: tiles drag instead of opening.
    var reorder: Binding<[UUID]?> = .constant(nil)
    var onOpen: (MomentPhoto) -> Void
    @State private var dragging: UUID?

    private var ordered: [MomentPhoto] {
        guard let order = reorder.wrappedValue else { return Self.ordered(photos, items: items) }
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        return order.compactMap { byID[$0] }
    }

    static func ordered(_ photos: [MomentPhoto], items: [UUID: WallItem]) -> [MomentPhoto] {
        photos.sorted { a, b in
            let oa = items[a.id]?.gridOrder ?? 0
            let ob = items[b.id]?.gridOrder ?? 0
            return oa != ob ? oa < ob : a.createdAt > b.createdAt
        }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
            ForEach(ordered) { photo in
                if reorder.wrappedValue != nil {
                    tile(photo)
                        .opacity(dragging == photo.id ? 0.4 : 1)
                        .overlay { Rectangle().strokeBorder(.white.opacity(0.6), lineWidth: 1) }
                        .onDrag {
                            dragging = photo.id
                            return NSItemProvider(object: photo.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: GridReorderDrop(target: photo.id, order: reorder,
                                                                       dragging: $dragging))
                } else {
                    Button { onOpen(photo) } label: { tile(photo) }
                        .buttonStyle(.plain)
                }
            }
            if canUpload {
                Button(action: onUpload) {
                    Rectangle()
                        .fill(.quaternary.opacity(0.5))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "plus").font(.title2.weight(.light)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("사진 업로드")
            }
        }
        // A drag let go between tiles still ends.
        .onDrop(of: [.text], isTargeted: nil) { _ in dragging = nil; return true }
        .onChange(of: reorder.wrappedValue == nil) { _, done in if done { dragging = nil } }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
    }

    private func tile(_ photo: MomentPhoto) -> some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: store.thumbURL(photo)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if photo.status == .hidden {
                    badge("eye.slash")
                } else if photo.isShared {
                    badge("sparkles")
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(photo.caption ?? "사진")
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .padding(6)
    }
}

/// Moves the dragged tile into the spot it is over, as it goes; the drop only ends the drag.
private struct GridReorderDrop: DropDelegate {
    let target: UUID
    let order: Binding<[UUID]?>
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target, var list = order.wrappedValue,
              let from = list.firstIndex(of: dragging), let to = list.firstIndex(of: target) else { return }
        list.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(.snappy) { order.wrappedValue = list }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// The top of 내 갤러리, Instagram-style: picture, names and counts, then the introduction,
/// the camera in use and the links, and the two buttons.
struct MomentProfileHeader: View {
    @ObservedObject var account: MomentAccount
    var onUpload: () -> Void
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let me = account.me {
                MomentProfileSummary(store: account.store, profile: me)
            }
            HStack(spacing: 8) {
                Button { editing = true } label: {
                    Text("프로필 편집").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: onUpload) {
                    Label("사진 업로드", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(account.quota?.wallFull == true)
            }
            // Only I see this line: how full my wall is and what I can still share.
            usage
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $editing) { MomentProfileEditView(account: account) }
    }

    /// "벽 7/15 · 공유 중 3 · 이번 달 공유 5번 남음", or why nothing more can be hung.
    private var usage: Text {
        let wall = "벽 \(account.myPhotos.count)/\(account.me?.wallLimit ?? 15)"
        let shared = "공유 중 \(account.myPhotos.filter(\.isShared).count)"
        guard let q = account.quota else { return Text("\(wall) · \(shared)") }
        if q.wallFull {
            return Text("\(wall) · \(shared) · 벽이 가득 찼어요. 사진을 내리면 새로 걸 수 있어요.")
        }
        return Text("\(wall) · \(shared) · 이번 달 공유 \(q.sharesLeft)번 남음")
    }
}

/// 갤러리 in full screen: the wall alone in a dark room, nothing else on screen. On iPhone the
/// phone may turn while it is open; the wall lays itself out again for the new size (a long
/// horizontal wall fills a phone held sideways).
struct MomentWallFullScreen<Detail: View>: View {
    let store: MomentStore
    let photos: [MomentPhoto]
    let items: [UUID: WallItem]
    let direction: MomentProfile.WallDirection
    /// Names shown at the bottom.
    let title: String
    @ViewBuilder let detail: (MomentPhoto) -> Detail
    @Environment(\.dismiss) private var dismiss
    @State private var opened: MomentPhoto?
    @State private var chrome = true

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let geo = WallGeometry(
                unit: direction == .vertical ? min(max(size.width - 48, 200), 900, size.height * 1.4)
                                             : max(size.height - 56, 200),
                direction: direction)
            let items = geo.resolved(photos, items: items)
            let length = max(items.compactMap { item in
                photo(item.photoID).map { item.y + geo.along(geo.size($0, width: item.width)) }
            }.max() ?? 0, 0.6) + 0.08
            let canvas = ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(items, id: \.photoID) { item in
                    if let photo = photo(item.photoID) {
                        let origin = geo.origin(item)
                        WallFrame(store: store, photo: photo,
                                  size: geo.size(photo, width: item.width), selected: false)
                            .offset(x: origin.x, y: origin.y)
                            .onTapGesture { opened = photo }
                    }
                }
            }
            .frame(width: direction == .vertical ? geo.unit : CGFloat(length) * geo.unit,
                   height: direction == .vertical ? CGFloat(length) * geo.unit : geo.unit,
                   alignment: .topLeading)

            ScrollView(direction == .vertical ? .vertical : .horizontal, showsIndicators: false) {
                canvas
                    .padding(direction == .vertical ? .vertical : .horizontal, 40)
                    .frame(minWidth: size.width, minHeight: size.height)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } }
        }
        .background(Color(white: 0.1).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topLeading) {
            if chrome {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(16)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("닫기")
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if chrome, !title.isEmpty {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { Orientation.setFree(true) }
        .onDisappear { Orientation.setFree(false) }
        #endif
        // A photo from 갤러리 opens alone, the way 순간들 opens one.
        .sheet(item: $opened) { photo in detail(photo) }
    }

    private func photo(_ id: UUID) -> MomentPhoto? { photos.first { $0.id == id } }
}

/// Lays chips out left to right and wraps to the next line when the row is full.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
