import SwiftUI

/// Lightroom-style library: grid (G), loupe with filmstrip (E) and develop (D).
/// Tab hides the side panels, ⇧Tab everything but the photo, F goes full screen.
struct LibraryView: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var connection: ConnectionModel
    @AppStorage("thumbSize") private var thumbSize = 150.0
    @AppStorage("modifierScrollResizesGrid") private var modifierScrollResizes = true
    @State private var showShortcuts = false

    var body: some View {
        VStack(spacing: 0) {
            if !library.immersive {
                toolbar
                Divider()
                if !online { offlineBanner; Divider() }
            }
            switch library.mode {
            case .grid: GridView()
            case .loupe: LoupeView()
            case .develop: DevelopView()
            }
            if !library.transfers.isEmpty, !library.immersive {
                Divider()
                TransferPanel()
            }
        }
        .background(KeyMonitor(onKey: handleKey, onScroll: handleScroll))
        .task { if library.photos.isEmpty, online { await library.reload() } }
        // Left full screen another way (green button, ⌃⌘F): bring the panels back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            library.immersive = false
        }
        .confirmationDialog("사진을 어디에 저장할까요?", isPresented: Binding(
            get: { library.pendingSave != nil }, set: { if !$0 { library.pendingSave = nil } }
        )) {
            Button("‘\(LibraryModel.defaultDestination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))’ 폴더 만들어 저장") {
                library.destination = LibraryModel.defaultDestination
                library.save(library.pendingSave ?? [])
            }
            Button("다른 폴더 선택…") {
                if chooseFolder() { library.save(library.pendingSave ?? []) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("처음 저장할 때 한 번만 물어요. 나중에 왼쪽 ‘설정’에서 바꿀 수 있어요.")
        }
    }

    /// Filter by what 촬영 통계 reads from each photo (image control, exposure mode, …).
    /// Lists only values found on this card; empty until the stats have been read once.
    @ViewBuilder private func shotFilterMenu(compact: Bool) -> some View {
        let records = library.photos.compactMap { library.stats.records[$0.id] }
        Menu {
            if library.shotFilter != nil {
                Button("촬영 정보 필터 해제") { library.shotFilter = nil }
                Divider()
            }
            ForEach(ShotFilter.Field.allCases) { field in
                let counts = records.compactMap { $0.key(field) }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                if !counts.isEmpty {
                    Menu(field.rawValue) {
                        ForEach(counts.keys.sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }, id: \.self) { key in
                            Button("\(field.label(key)) (\(counts[key]!))") {
                                library.shotFilter = ShotFilter(field: field, value: key)
                            }
                        }
                    }
                }
            }
            if records.isEmpty {
                Text("‘촬영 통계’를 한 번 열면 촬영 정보로 거를 수 있어요.")
            }
        } label: {
            let text = "필터: " + (library.shotFilter?.label ?? "전체")
            if compact {
                Image(systemName: library.shotFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .help(text)
            } else {
                Label(text, systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        .fixedSize()
        .help("노출 모드·이미지 컨트롤·비율·크롭·HDF로 거르기")
        if library.shotFilter != nil {
            Button { library.shotFilter = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("촬영 정보 필터 해제")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { library.mode }, set: { switchMode($0) })) {
                Image(systemName: "square.grid.3x3").help("그리드 (G)").tag(LibraryModel.Mode.grid)
                Image(systemName: "photo").help("확대 보기 (E)").tag(LibraryModel.Mode.loupe)
                Image(systemName: "slider.horizontal.3").help("편집 (D)").tag(LibraryModel.Mode.develop)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            // A way of viewing, so it sits with the view modes; 선택 저장 stays rightmost.
            Button { toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("전체화면 (F)")

            Button {
                Task { await library.reload() }
            } label: { Image(systemName: "arrow.clockwise") }
            .help("새로고침")
            .disabled(!online)

            // When the window is narrow these shorten (no counts, icon-only menus) so the
            // buttons on the right keep their full labels.
            ViewThatFits(in: .horizontal) {
                browseControls(compact: false)
                browseControls(compact: true)
            }

            Spacer()

            let progress = library.infoProgress
            if progress.done < progress.total, online {
                Text("날짜 읽는 중 \(progress.done)/\(progress.total)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            Group {
                Menu("선택") {
                    Button("전체 선택") { library.selectAll() }.keyboardShortcut("a", modifiers: .command)
                    Button("미저장만 선택") { library.selectUnsaved() }
                    Button("선택 해제") { library.clearSelection() }.keyboardShortcut("d", modifiers: .command)
                }

                Button {
                    _ = chooseFolder()
                } label: {
                    Label(library.destination.lastPathComponent, systemImage: "folder")
                }
                .help("저장 폴더: \(library.destination.path)")

                Button {
                    library.saveSelected()
                } label: {
                    Text(library.selection.isEmpty ? "선택 저장" : "선택 저장 (\(library.selection.count))")
                }
                .buttonStyle(.borderedProminent)
                .disabled(library.selection.isEmpty || library.isTransferring || !online)
                .help(online ? "" : "카메라에 연결하면 저장할 수 있어요")
            }
            .fixedSize()
            .layoutPriority(1)

            Button { showShortcuts.toggle() } label: { Image(systemName: "keyboard") }
                .help("단축키")
                .popover(isPresented: $showShortcuts) { ShortcutHelp() }
        }
        .padding(10)
    }

    @ViewBuilder private func browseControls(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Picker("", selection: $library.filter) {
                ForEach(LibraryModel.Filter.allCases) { f in
                    Text(compact ? f.rawValue : "\(f.rawValue) (\(library.count(f)))").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Menu {
                Picker("정렬", selection: $library.sort) {
                    ForEach(LibraryModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("별점", selection: $library.minRating) {
                    Text("별점 상관없음").tag(0)
                    ForEach(1...5, id: \.self) { n in Text(String(repeating: "★", count: n) + " 이상").tag(n) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("날짜별로 묶기", isOn: $library.groupByDate)
            } label: {
                let text = "정렬: " + library.sort.rawValue + (library.minRating > 0 ? " · ★\(library.minRating)+" : "")
                if compact { Image(systemName: "arrow.up.arrow.down").help(text) } else { Label(text, systemImage: "arrow.up.arrow.down") }
            }
            .fixedSize()
            .help("정렬 순서, 별점으로 거르기, 날짜별로 묶기")

            shotFilterMenu(compact: compact)
        }
    }

    private var online: Bool { connection.isConnected }

    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.badge.ellipsis").foregroundStyle(.secondary)
            Text(offlineText).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    private var offlineText: String {
        let when = library.listSavedAt.map {
            $0.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).month().day().hour().minute())
        }
        return "카메라 연결 안 됨 · " + (when.map { "\($0)에 본 목록이에요. " } ?? "")
            + "미리 저장해 둔 사진만 크게 보고 편집할 수 있고, 저장은 연결한 뒤에 할 수 있어요."
    }

    private func switchMode(_ mode: LibraryModel.Mode) {
        if mode != .grid, library.current == nil { library.current = library.visible.first }
        library.zoom.reset()
        library.mode = mode
    }

    private func toggleFullScreen() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let entering = !window.styleMask.contains(.fullScreen)
        window.toggleFullScreen(nil)
        library.immersive = entering
        if entering, library.mode == .grid { switchMode(.loupe) }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        // ⌘R / ⌥⌘R, as in Photos.
        if e.charactersIgnoringModifiers?.lowercased() == "r", mods == .command || mods == [.command, .option] {
            library.rotate(targets, by: mods.contains(.option) ? -1 : 1)
            return true
        }
        guard mods.isEmpty else { return false }
        let shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 53: // esc
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                library.immersive = false
            } else if library.immersive {
                library.immersive = false
            } else if library.mode != .grid {
                library.mode = .grid
            } else {
                return false
            }
            return true
        case 48: // tab
            if shift { library.immersive.toggle() } else { library.panels.toggle() }
            return true
        case 123: library.step(-1); return true
        case 124: library.step(1); return true
        case 36, 76: // return
            guard library.mode == .grid, library.current != nil else { return false }
            switchMode(.loupe)
            return true
        case 49: // space
            if let c = library.current { library.toggle(c) }
            return true
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "g": switchMode(.grid)
        case "e": switchMode(.loupe)
        case "d": switchMode(.develop)
        case "f": toggleFullScreen()
        case "b": library.filmstrip.toggle()
        case "p": if let c = library.current { library.toggle(c) }
        case "z":
            if library.zoom.isZoomed { library.zoom.reset() } else { library.zoom.mode = .actual }
        case "\\": library.showOriginal.toggle()
        case "y": library.compare = library.compare == .sideBySide ? .off : .sideBySide
        case "0", "1", "2", "3", "4", "5":
            let n = Int(e.charactersIgnoringModifiers ?? "0") ?? 0
            library.setRating(n, for: targets)
        case "=", "+":
            if library.mode == .grid { thumbSize = min(320, thumbSize + 20) } else { library.zoom.set(library.zoom.scale * 1.25) }
        case "-":
            if library.mode == .grid { thumbSize = max(90, thumbSize - 20) } else { library.zoom.set(library.zoom.scale / 1.25) }
        default: return false
        }
        return true
    }

    /// What a rating or rotation key acts on: the selection in the grid, else the current photo.
    private var targets: [Photo] {
        library.mode == .grid && library.selection.count > 1
            ? library.visible.filter { library.selection.contains($0.id) }
            : library.current.map { [$0] } ?? []
    }

    /// ⌘/⌥ + scroll over the grid resizes the thumbnails.
    private func handleScroll(_ e: NSEvent) -> Bool {
        guard library.mode == .grid, modifierScrollResizes,
              e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) else { return false }
        let delta = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 10
        thumbSize = min(320, max(90, thumbSize + delta))
        return true
    }

    /// Returns true when a folder was picked.
    private func chooseFolder() -> Bool {
        guard let url = FolderPicker.choose(from: library.destination) else { return false }
        library.destination = url
        return true
    }
}

struct ShortcutHelp: View {
    private let rows: [(String, String)] = [
        ("G / E / D", "그리드 / 확대 보기 / 편집"),
        ("Return · 더블클릭", "확대 보기로 열기"),
        ("← →", "이전 / 다음 사진"),
        ("Space · P", "선택 켜기/끄기"),
        ("클릭 · ⌘클릭 · ⇧클릭", "한 장 / 추가 / 범위 선택"),
        ("0 – 5", "별점"),
        ("Z", "맞춤 ↔ 100%"),
        ("+ / −", "썸네일 크기 · 확대"),
        ("⌘/⌥ + 스크롤", "확대/축소 (그리드: 썸네일 크기)"),
        ("B", "필름스트립 보이기/숨기기"),
        ("Tab", "옆 패널 숨기기"),
        ("⇧Tab", "가득찬 화면 (사진만)"),
        ("F", "전체화면"),
        ("Esc", "나가기 / 그리드로"),
        ("\\", "편집: 원본 보기"),
        ("Y", "편집: 원본과 나란히 비교"),
        ("⌘Z / ⇧⌘Z", "편집: 실행 취소 / 다시 실행"),
        ("⇧⌘C / ⇧⌘V", "편집: 설정 복사 / 붙여넣기"),
        ("⇧⌘E", "편집: 다른 이름으로 저장"),
        ("R / Return", "편집: 자르기 시작 / 완료"),
        ("⌘R / ⌥⌘R", "오른쪽 / 왼쪽으로 회전 (선택한 사진)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("단축키").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).font(.callout.monospaced())
                        Text(row.1).foregroundStyle(.secondary)
                    }
                }
            }
            Text("스크롤·드래그·클릭 동작은 설정 → 조작에서 바꿀 수 있어요.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

// MARK: - Grid

private struct CellFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct GridView: View {
    @EnvironmentObject var library: LibraryModel
    @AppStorage("thumbSize") private var thumbSize = 150.0
    @AppStorage("gridDrag") private var gridDrag = GridDragAction.select

    @State private var frames: [String: CGRect] = [:]
    @State private var band: CGRect?
    @State private var bandBase: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
    }

    @ViewBuilder private var content: some View {
        if let error = library.error {
            ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if library.isLoading && library.photos.isEmpty {
            ProgressView("카메라에서 사진 목록을 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if library.visible.isEmpty {
            ContentUnavailableView("사진 없음", systemImage: "photo.on.rectangle")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 8)], spacing: 8,
                              pinnedViews: library.groupByDate ? [.sectionHeaders] : []) {
                        ForEach(library.sections) { section in
                            Section {
                                ForEach(section.photos) { photo in
                                    PhotoCell(photo: photo)
                                        .id(photo.id)
                                        .background(GeometryReader { g in
                                            Color.clear.preference(key: CellFrameKey.self, value: [photo.id: g.frame(in: .named("grid"))])
                                        })
                                        .onTapGesture(count: 2) { library.open(photo, in: .loupe) }
                                        .onTapGesture {
                                            let mods = NSEvent.modifierFlags
                                            library.click(photo, command: mods.contains(.command), shift: mods.contains(.shift))
                                        }
                                }
                            } header: {
                                if library.groupByDate { sectionHeader(section) }
                            }
                        }
                    }
                    .padding(12)
                    .coordinateSpace(name: "grid")
                    .onPreferenceChange(CellFrameKey.self) { frames = $0 }
                    .simultaneousGesture(bandGesture, including: gridDrag == .select ? .all : .subviews)
                    .overlay(alignment: .topLeading) {
                        if let band {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.15))
                                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                                .frame(width: band.width, height: band.height)
                                .offset(x: band.minX, y: band.minY)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .onAppear { if let c = library.current { proxy.scrollTo(c.id, anchor: .center) } }
                .onChange(of: library.current) { _, c in
                    if let c, let f = frames[c.id], f.isEmpty == false { return }
                    if let c { withAnimation { proxy.scrollTo(c.id) } }
                }
            }
        }
    }

    private var bandGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("grid"))
            .onChanged { v in
                if band == nil {
                    bandBase = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) ? library.selection : []
                }
                let rect = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                  width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                band = rect
                let hit = frames.filter { $0.value.intersects(rect) }.map(\.key)
                library.selection = bandBase.union(hit)
            }
            .onEnded { _ in band = nil }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(library.visible.count)장" + (library.selection.isEmpty ? "" : " 중 \(library.selection.count)장 선택"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $thumbSize, in: 90...320).frame(width: 140).controlSize(.small)
            Image(systemName: "photo").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func sectionHeader(_ section: LibraryModel.DaySection) -> some View {
        let allSelected = section.photos.allSatisfy { library.selection.contains($0.id) }
        return HStack {
            Text(section.title).font(.headline)
            Text("\(section.photos.count)장").foregroundStyle(.secondary)
            Spacer()
            Button(allSelected ? "이 날짜 선택 해제" : "이 날짜 선택") { library.toggleSection(section.photos) }
                .buttonStyle(.link)
        }
        .padding(.vertical, 6).padding(.horizontal, 4)
        .background(.bar)
    }
}

enum FolderPicker {
    @MainActor static func choose(from start: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "이 폴더에 저장"
        panel.directoryURL = FileManager.default.fileExists(atPath: start.path) ? start : start.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Camera image, optionally with edits applied (thumbnails of edited photos).
struct RemoteImage: View {
    let url: URL
    var contentMode: ContentMode = .fill
    var orientation = 1
    var adjustments: Adjustments? = nil
    /// Shown instead of a spinner when the camera has no image (movies on some models).
    var placeholder = "photo"
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary)
                if failed {
                    Image(systemName: placeholder).font(.title2).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: "\(url.absoluteString)#\(orientation)#\(adjustments?.hashValue ?? 0)") {
            guard let base = await ImageCache.shared.image(for: url, orientation: orientation) else {
                failed = true
                return
            }
            guard let adjustments, !adjustments.isDefault, let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                image = base
                return
            }
            let rendered = await Task.detached(priority: .utility) {
                DevelopEngine.cgImage(DevelopEngine.apply(adjustments, to: CIImage(cgImage: cg)))
            }.value
            image = rendered.map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) } ?? base
        }
    }
}

/// Reads its state from the library itself: inside the sectioned lazy grid, values passed
/// in from the parent were not refreshed (selection, saved badge and orientation went stale).
struct PhotoCell: View {
    @EnvironmentObject var library: LibraryModel
    @AppStorage("thumbSize") private var thumbSize = 150.0
    let photo: Photo

    private var selected: Bool { library.selection.contains(photo.id) }
    private var saved: Bool { library.saved.contains(photo.name) }

    var body: some View {
        // The cell's size comes from the grid; the image only fills it, never sizes it.
        Color.black
            .frame(maxWidth: .infinity)
            .frame(height: thumbSize * 0.72)
            .overlay {
                // Portrait shots are shown whole and upright, letterboxed in the cell.
                RemoteImage(url: library.thumbURL(photo),
                            contentMode: library.isPortrait(photo) ? .fit : .fill,
                            orientation: library.orientation(photo),
                            adjustments: library.edits[photo.id],
                            placeholder: photo.kind == .video ? "video" : "photo")
            }
            .clipped()
        .overlay(alignment: .topTrailing) {
            Button { library.toggle(photo) } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .white)
                    .shadow(radius: 2)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("선택 켜기/끄기 (Space)")
        }
        .overlay {
            if photo.kind == .video { VideoMark(size: min(44, thumbSize * 0.3)) }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                if photo.kind == .video { Badge(text: "동영상", color: .red, icon: "video.fill") }
                if photo.kind == .raw { Badge(text: "RAW") }
                if saved { Badge(text: "저장됨", color: .green) }
                if library.edits[photo.id] != nil { Badge(text: "편집됨", color: .orange) }
                Spacer()
                if library.rating(photo) > 0 { Stars(value: library.rating(photo)) }
            }
            .padding(6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : library.current == photo ? .white.opacity(0.7) : .clear,
                              lineWidth: selected ? 3 : 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(photo.id)
        .contentShape(Rectangle())
        .contextMenu {
            if photo.kind != .video {
                // The whole selection when this photo is part of it, as in Finder.
                let photos = selected ? library.visible.filter { library.selection.contains($0.id) } : [photo]
                let what = photos.count > 1 ? "\(photos.count)장 " : ""
                Button("\(what)오른쪽으로 회전") { library.rotate(photos, by: 1) }
                Button("\(what)왼쪽으로 회전") { library.rotate(photos, by: -1) }
            }
        }
    }
}

struct Stars: View {
    let value: Int
    var body: some View {
        Text(String(repeating: "★", count: value))
            .font(.caption2)
            .foregroundStyle(.yellow)
            .shadow(color: .black, radius: 1)
    }
}

/// Darkened frame with a big play button and film-strip edges, so movies stand out in the grid.
struct VideoMark: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack {
                sprockets
                Spacer()
                sprockets
            }
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: size * 0.04)
                .frame(width: size, height: size)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                .shadow(radius: 3)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    /// As many holes as fit the cell: a fixed count made the strip wider than small
    /// filmstrip cells and it spilled over the neighbouring photos.
    private var sprockets: some View {
        GeometryReader { geo in
            HStack(spacing: 5) {
                ForEach(0..<max(1, Int((geo.size.width + 5) / 10)), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.75)).frame(width: 5, height: 4)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: 9)
        .background(.black.opacity(0.7))
        .clipped()
    }
}

struct Badge: View {
    let text: String
    var color: Color = .black
    var icon: String? = nil

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let icon { Image(systemName: icon) }
        }
        .labelStyle(BadgeLabelStyle())
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.7), in: Capsule())
            .foregroundStyle(.white)
    }
}

private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Filmstrip

struct Filmstrip: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 4) {
                    ForEach(library.visible) { photo in
                        FilmCell(photo: photo)
                            .id(photo.id)
                            .onTapGesture {
                                let mods = NSEvent.modifierFlags
                                if mods.contains(.command) || mods.contains(.shift) {
                                    library.click(photo, command: mods.contains(.command), shift: mods.contains(.shift))
                                } else {
                                    library.current = photo
                                    library.zoom.reset()
                                    library.showOriginal = false
                                }
                            }
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 5)
            }
            .frame(height: 80)
            .background(Color(white: 0.1))
            .onAppear { proxy.scrollTo(library.current?.id, anchor: .center) }
            .onChange(of: library.current) { _, c in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(c?.id, anchor: .center) }
            }
        }
    }
}

private struct FilmCell: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo

    var body: some View {
        let isCurrent = library.current == photo
        RemoteImage(url: library.thumbURL(photo),
                    contentMode: library.isPortrait(photo) ? .fit : .fill,
                    orientation: library.orientation(photo),
                    adjustments: library.edits[photo.id],
                    placeholder: photo.kind == .video ? "video" : "photo")
            .frame(width: 96, height: 68)
            .background(Color.black)
            .clipped()
            .overlay { if photo.kind == .video { VideoMark(size: 24) } }
            .opacity(isCurrent ? 1 : 0.75)
            .overlay(alignment: .topTrailing) {
                if library.selection.contains(photo.id) {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.accentColor)
                        .background(Circle().fill(.white)).padding(3)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 2) {
                    if library.rating(photo) > 0 { Stars(value: library.rating(photo)) }
                }
                .padding(3)
            }
            .overlay { Rectangle().strokeBorder(isCurrent ? Color.white : .clear, lineWidth: 2) }
            .help(photo.name)
    }
}

// MARK: - Loupe

struct LoupeView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var image: NSImage?
    @State private var histogram: Histogram?
    @State private var cameraOriginal = false
    @State private var revealStrip = false

    var body: some View {
        if let photo = library.current {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    viewer(photo)
                        .overlay(alignment: .topLeading) { BackToGrid() }
                    if library.panels, !library.immersive {
                        Divider()
                        InfoPanel(photo: photo, histogram: histogram, image: image)
                    }
                }
                if !library.immersive {
                    Divider()
                    LoupeFooter(photo: photo, cameraOriginal: $cameraOriginal)
                    if library.filmstrip { Filmstrip() }
                }
            }
            .overlay(alignment: .bottom) { if library.immersive { ImmersiveStrip() } }
            .task(id: "\(photo.id)#\(cameraOriginal)#\(library.localURL(photo)?.path ?? "")#\(library.edits[photo.id]?.hashValue ?? 0)") {
                await load(photo)
            }
        } else {
            ContentUnavailableView("사진을 고르세요", systemImage: "photo")
        }
    }

    @ViewBuilder private func viewer(_ photo: Photo) -> some View {
        if photo.kind == .video {
            VideoViewer(photo: photo, localURL: library.localURL(photo))
        } else {
            PhotoCanvas(image: image, zoom: $library.zoom) { library.step($0) }
        }
    }

    /// Camera thumbnail first, then the saved file (with edits) or the camera's 1920 px preview.
    private func load(_ photo: Photo) async {
        guard photo.kind != .video else { image = nil; histogram = nil; return }
        let orientation = library.orientation(photo)
        // Camera previews get the library's rotation; the saved file goes through DevelopEngine.
        let adj = library.adjustments(photo)
        func turned(_ image: NSImage?) async -> NSImage? {
            guard let image, !adj.isDefault, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
            let out = await Task.detached(priority: .userInitiated) {
                DevelopEngine.cgImage(DevelopEngine.apply(adj, to: CIImage(cgImage: cg)))
            }.value
            return out.map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) } ?? image
        }
        if image == nil || !cameraOriginal {
            image = await turned(await ImageCache.shared.image(for: library.thumbURL(photo), orientation: orientation))
        }
        histogram = nil
        var best: NSImage?
        if let local = library.localURL(photo) {
            best = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let src = DevelopEngine.load(local, maxEdge: 4000),
                      let cg = DevelopEngine.cgImage(DevelopEngine.apply(adj, to: src)) else { return nil }
                return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
            }.value
        }
        if best == nil {
            best = await turned(await ImageCache.shared.image(for: CameraAPI.photoURL(photo, size: cameraOriginal ? nil : .xs), orientation: orientation))
        }
        if Task.isCancelled { return }
        if let best { image = best }
        if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            histogram = await Task.detached(priority: .utility) { Histogram(cg) }.value
        }
        // Warm the cache for the next photo in the strip.
        let list = library.visible
        if let i = list.firstIndex(of: photo), list.indices.contains(i + 1), list[i + 1].kind != .video {
            _ = await ImageCache.shared.image(for: CameraAPI.photoURL(list[i + 1], size: .xs),
                                              orientation: library.orientation(list[i + 1]))
        }
    }
}

/// Filmstrip that slides in when the pointer reaches the bottom in full screen.
struct ImmersiveStrip: View {
    @State private var reveal = false

    var body: some View {
        VStack(spacing: 0) {
            if reveal { Filmstrip().transition(.move(edge: .bottom)) } else { Color.clear.frame(height: 28) }
        }
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { reveal = hovering } }
    }
}

struct LoupeFooter: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    @Binding var cameraOriginal: Bool

    private var index: Int { library.visible.firstIndex(of: photo) ?? 0 }

    var body: some View {
        HStack(spacing: 10) {
            Button { library.step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
            Button { library.step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(index >= library.visible.count - 1)
            Text("\(index + 1) / \(library.visible.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            if photo.kind != .video {
                ZoomControls()
                Button { library.rotate([photo], by: -1) } label: { Image(systemName: "rotate.left") }
                    .help("왼쪽으로 회전 (⌥⌘R)")
                Button { library.rotate([photo], by: 1) } label: { Image(systemName: "rotate.right") }
                    .help("오른쪽으로 회전 (⌘R)")
            }
            if photo.kind != .video, library.localURL(photo) == nil {
                Toggle("카메라 원본", isOn: $cameraOriginal)
                    .toggleStyle(.checkbox)
                    .help("카메라에서 원본 파일을 받아 표시해요 (느릴 수 있음). 저장된 사진은 항상 Mac의 원본으로 표시돼요.")
            }

            Spacer()

            RatingControl(photo: photo)
            Button(library.selection.contains(photo.id) ? "선택됨 ✓" : "선택") { library.toggle(photo) }
                .help("Space / P")
            if photo.kind != .video {
                Button("편집") { library.mode = .develop }.help("D")
            }
            Toggle(isOn: $library.filmstrip) { Image(systemName: "film") }
                .toggleStyle(.button).help("필름스트립 (B)")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct ZoomControls: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { library.zoom.mode == .custom ? nil : library.zoom.mode },
                set: { if let m = $0 { library.zoom.mode = m; if m == .fit { library.zoom.offset = .zero } } }
            )) {
                Text("맞춤").tag(ZoomState.Mode?.some(.fit))
                Text("채우기").tag(ZoomState.Mode?.some(.fill))
                Text("100%").tag(ZoomState.Mode?.some(.actual))
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Slider(value: Binding(get: { library.zoom.scale }, set: { library.zoom.set($0) }),
                   in: 1...max(ZoomState.maxScale, library.zoom.actualScale))
                .frame(width: 110)
                .controlSize(.small)
            Text("\(library.zoom.percent)%").font(.caption.monospacedDigit()).frame(width: 42, alignment: .leading)
        }
    }
}

struct RatingControl: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { n in
                Button {
                    library.setRating(library.rating(photo) == n ? 0 : n, for: [photo])
                } label: {
                    Image(systemName: n <= library.rating(photo) ? "star.fill" : "star")
                        .foregroundStyle(n <= library.rating(photo) ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .help("별점 (0–5 키)")
    }
}

struct InfoPanel: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    let histogram: Histogram?
    let image: NSImage?
    @State private var metadata: PhotoMetadata?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if photo.kind != .video { HistogramView(histogram: histogram) }
                if let metadata { ShotChips(metadata: metadata) }
                Text(photo.name).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    ForEach(rows, id: \.0) { row in
                        GridRow {
                            Text(row.0).foregroundStyle(.secondary)
                            Text(row.1).textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                }
                if loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("카메라에서 촬영 정보 읽는 중…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let url = library.localURL(photo) {
                    Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .controlSize(.small)
                }
            }
            .padding(12)
        }
        .frame(width: 250)
        .task(id: "\(photo.id)#\(library.localURL(photo)?.path ?? "")") { await load() }
    }

    private var rows: [(String, String)] {
        var out: [(String, String)] = [("폴더", photo.dir)]
        if let date = library.infos[photo.id]?.date {
            out.append(("촬영", date.formatted(date: .abbreviated, time: .standard)))
        }
        if let camera = metadata?.camera { out.append(("카메라", camera)) }
        for item in MakerNote.toneSettings(metadata?.shot?.toneParams ?? library.shotRecord(photo)?.toneParams) {
            out.append((item.name, item.value))
        }
        let size = [metadata?.pixelSize, metadata?.fileSize].compactMap { $0 }
        if !size.isEmpty { out.append(("크기", size.joined(separator: "\n"))) }
        out.append(("저장", library.localURL(photo).map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "미저장"))
        return out
    }

    /// Saved file first; otherwise the head of the original from the camera.
    private func load() async {
        loading = false
        if let url = library.localURL(photo) {
            metadata = await Task.detached { PhotoMetadata.read(url) }.value
            return
        }
        if let cached = MetadataCache.entries[photo.id] {
            metadata = cached
            return
        }
        metadata = nil
        guard photo.kind != .video else { return }
        loading = true
        defer { loading = false }
        let fileSize = library.infos[photo.id]?.extras["size"].flatMap { Int64($0) }
        guard let head = try? await CameraAPI.head(photo), !Task.isCancelled else { return }
        let read = await Task.detached { PhotoMetadata.read(head: head, fileSize: fileSize) }.value
        if let read { MetadataCache.entries[photo.id] = read }
        metadata = read
    }
}

// MARK: - Transfers

struct TransferPanel: View {
    @EnvironmentObject var library: LibraryModel

    private var doneCount: Int {
        library.transfers.filter { if case .done = $0.status { return true } else { return false } }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(library.isTransferring ? "저장 중 \(doneCount)/\(library.transfers.count)" : "저장 완료 \(doneCount)/\(library.transfers.count)")
                    .font(.headline)
                Spacer()
                if library.isTransferring {
                    Button("중지") { library.cancelTransfers() }
                } else {
                    Button("Finder에서 보기") { NSWorkspace.shared.open(library.destination) }
                    Button("닫기") { library.dismissTransfers() }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(library.transfers) { t in
                        HStack {
                            Text(t.photo.name).font(.caption.monospaced()).frame(width: 140, alignment: .leading)
                            switch t.status {
                            case .waiting: Text("대기").font(.caption).foregroundStyle(.secondary)
                            case .running(let p): ProgressView(value: p).frame(width: 200)
                            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed(let msg): Text(msg).font(.caption).foregroundStyle(.red)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .padding(12)
    }
}

/// "‹ 사진 목록" floating on the photo in 확대 보기 and 편집, so the toolbar keeps its layout.
struct BackToGrid: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        Button {
            library.zoom.reset()
            library.mode = .grid
        } label: {
            Label("사진 목록", systemImage: "chevron.left")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("사진 목록으로 돌아가기 (Esc)")
        .padding(12)
    }
}
