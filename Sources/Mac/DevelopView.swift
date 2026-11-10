import SwiftUI
import UniformTypeIdentifiers

/// Editing a saved photo: canvas with before/after, the adjustment panel and the filmstrip.
/// Only photos already on the Mac can be edited, so nothing is pulled over the camera's Wi-Fi.
struct DevelopView: View {
    @EnvironmentObject var library: LibraryModel
    @StateObject private var session = DevelopSession()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The empty states don't stretch on their own; without this the whole library
                // shrinks to their height and floats in the middle of the window.
                main.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) { BackToGrid() }
                if library.panels, !library.immersive, let photo = library.current, let url = library.localURL(photo),
                   photo.kind != .video {
                    Divider()
                    DevelopPanel(photo: photo, source: url, session: session)
                }
            }
            if !library.immersive {
                Divider()
                if let photo = library.current { DevelopFooter(photo: photo, session: session) }
                if library.filmstrip { Filmstrip() }
            }
        }
        .overlay(alignment: .bottom) { if library.immersive { ImmersiveStrip() } }
        .task(id: library.current.flatMap { library.localURL($0) }) {
            guard let photo = library.current, let url = library.localURL(photo), photo.kind != .video else {
                session.clear()
                return
            }
            await session.load(url)
            renderCurrent()
        }
        .onChange(of: library.current.map { library.adjustments($0) }) { _, _ in renderCurrent() }
        .onChange(of: session.cropping) { _, _ in renderCurrent() }
    }

    /// While cropping, the whole frame is shown so the box can be moved anywhere.
    private func renderCurrent() {
        guard let photo = library.current else { return }
        let adj = library.adjustments(photo)
        session.render(session.cropping ? adj.uncropped : adj)
    }

    @ViewBuilder private var main: some View {
        if let photo = library.current {
            if photo.kind == .video {
                ContentUnavailableView("동영상은 편집할 수 없어요", systemImage: "video",
                                       description: Text("확대 보기(E)에서 재생할 수 있어요."))
            } else if library.localURL(photo) == nil {
                notSaved(photo)
            } else {
                canvas
            }
        } else {
            ContentUnavailableView("사진을 고르세요", systemImage: "photo")
        }
    }

    private func notSaved(_ photo: Photo) -> some View {
        ContentUnavailableView {
            Label("Mac에 저장한 사진만 편집할 수 있어요", systemImage: "square.and.arrow.down")
        } description: {
            Text("저장하면 원본(JPG·DNG)으로 바로 편집합니다. 편집은 원본 파일을 바꾸지 않고, ‘다른 이름으로 저장’으로 내보냅니다.")
        } actions: {
            if library.isTransferring {
                ProgressView("저장 중…")
            } else {
                Button("이 사진 저장하고 편집") { library.requestSave([photo]) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private var canvas: some View {
        if session.cropping, let photo = library.current {
            CropEditor(image: session.rendered, rect: Binding(
                get: { library.adjustments(photo).cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1) },
                set: { r in
                    var a = library.adjustments(photo)
                    a.cropRect = r
                    library.setAdjustments(a, for: photo)
                }
            ), aspect: session.uncroppedSize.flatMap {
                session.cropAspect.ratio(original: $0.width / $0.height, portrait: session.cropPortrait)
            }, onBegin: {
                session.undoStack.append(library.adjustments(photo))
                session.redoStack = []
            })
        } else {
            compareCanvas
        }
    }

    @ViewBuilder private var compareCanvas: some View {
        let after = library.showOriginal ? session.original : session.rendered
        switch library.compare {
        case .off:
            PhotoCanvas(image: after, zoom: $library.zoom) { library.step($0) }
                .overlay(alignment: .topLeading) { if library.showOriginal { tag("원본") } }
        case .sideBySide:
            HStack(spacing: 2) {
                PhotoCanvas(image: session.original, zoom: $library.zoom) { library.step($0) }
                    .overlay(alignment: .topLeading) { tag("원본") }
                PhotoCanvas(image: session.rendered, zoom: $library.zoom) { library.step($0) }
                    .overlay(alignment: .topLeading) { tag("편집") }
            }
        case .split:
            SplitCompare(session: session)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(10)
    }
}

/// Original on the left of a draggable divider, edit on the right.
private struct SplitCompare: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var session: DevelopSession
    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            PhotoCanvas(image: session.rendered, zoom: $library.zoom, before: session.original, split: split) { library.step($0) }
                .overlay(alignment: .leading) {
                    ZStack {
                        Rectangle().fill(.white).frame(width: 2)
                        Circle().fill(.white).frame(width: 22, height: 22)
                            .overlay(Image(systemName: "arrow.left.and.right").font(.caption2.bold()).foregroundStyle(.black))
                    }
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .offset(x: geo.size.width * split - 12)
                    .gesture(DragGesture(coordinateSpace: .named("split")).onChanged { v in
                        split = min(max(v.location.x / max(geo.size.width, 1), 0.02), 0.98)
                    })
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                }
                .overlay(alignment: .topLeading) {
                    Text("원본").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(10)
                }
                .coordinateSpace(name: "split")
                .overlay(alignment: .topTrailing) {
                    Text("편집").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(10)
                }
        }
    }
}

/// Holds the working copy of one photo and renders edits off the main thread,
/// dropping intermediate slider positions when a render is still running.
@MainActor
final class DevelopSession: ObservableObject {
    @Published private(set) var original: NSImage?
    @Published private(set) var rendered: NSImage?
    @Published private(set) var histogram: Histogram?
    @Published var busy: String?
    @Published var cropping = false
    @Published var cropAspect = CropAspect.free
    @Published var cropPortrait = false
    /// Pixel size of the frame before cropping (rotation and straighten applied).
    @Published private(set) var uncroppedSize: CGSize?

    private var proxy: CIImage?
    private var rendering = false
    private var pending: Adjustments?
    private var loadedURL: URL?

    var undoStack: [Adjustments] = []
    var redoStack: [Adjustments] = []

    func clear() {
        proxy = nil
        original = nil
        rendered = nil
        histogram = nil
        loadedURL = nil
        cropping = false
        uncroppedSize = nil
    }

    func load(_ url: URL) async {
        guard url != loadedURL else { return }
        clear()
        loadedURL = url
        undoStack = []
        redoStack = []
        // Working copy: long edge 2400 px, rendered once so every slider step starts from pixels.
        let result = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let image = DevelopEngine.load(url, maxEdge: 2400) else { return nil }
            return DevelopEngine.cgImage(image)
        }.value
        guard loadedURL == url, let result else { return }
        proxy = CIImage(cgImage: result)
        original = NSImage(cgImage: result, size: CGSize(width: result.width, height: result.height))
    }

    func render(_ adj: Adjustments) {
        guard let proxy else { return }
        if rendering { pending = adj; return }
        rendering = true
        Task {
            let out = await Task.detached(priority: .userInitiated) { () -> (CGImage, Histogram?)? in
                guard let cg = DevelopEngine.cgImage(DevelopEngine.apply(adj, to: proxy)) else { return nil }
                return (cg, Histogram(cg))
            }.value
            if let (cg, histogram) = out, self.proxy === proxy {
                rendered = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
                if adj.crop == nil { uncroppedSize = CGSize(width: cg.width, height: cg.height) }
                self.histogram = histogram
            }
            rendering = false
            if let next = pending {
                pending = nil
                render(next)
            }
        }
    }
}

private struct DevelopFooter: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    @ObservedObject var session: DevelopSession

    var body: some View {
        HStack(spacing: 10) {
            Button { library.step(-1) } label: { Image(systemName: "chevron.left") }
            Button { library.step(1) } label: { Image(systemName: "chevron.right") }
            ZoomControls()
            Divider().frame(height: 16)
            Picker("비교", selection: $library.compare) {
                Text("편집만").tag(LibraryModel.Compare.off)
                Text("나란히").tag(LibraryModel.Compare.sideBySide)
                Text("분할").tag(LibraryModel.Compare.split)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("원본과 비교 (Y: 나란히)")
            Toggle("원본 보기", isOn: $library.showOriginal)
                .toggleStyle(.button)
                .disabled(library.compare != .off)
                .help("\\ 키")
            Spacer()
            RatingControl(photo: photo)
            Toggle(isOn: $library.filmstrip) { Image(systemName: "film") }
                .toggleStyle(.button).help("필름스트립 (B)")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

/// Copied settings, shared across photos (⇧⌘C / ⇧⌘V).
@MainActor private var copiedAdjustments: Adjustments?

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "자유", original = "원본 비율", square = "1:1", fourThree = "4:3", threeTwo = "3:2", sixteenNine = "16:9"
    var id: String { rawValue }

    /// Width / height in pixels, or nil for free.
    func ratio(original: CGFloat, portrait: Bool) -> CGFloat? {
        let r: CGFloat
        switch self {
        case .free: return nil
        case .original: return original
        case .square: return 1
        case .fourThree: r = 4.0 / 3
        case .threeTwo: r = 3.0 / 2
        case .sixteenNine: r = 16.0 / 9
        }
        return portrait ? 1 / r : r
    }
}

private struct DevelopPanel: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    let source: URL
    @ObservedObject var session: DevelopSession

    @AppStorage("exportFormat") private var formatRaw = ExportFormat.jpeg.rawValue
    @AppStorage("exportQuality") private var quality = 0.92
    @State private var message: String?
    @State private var hasCopy = copiedAdjustments != nil
    @State private var metadata: PhotoMetadata?

    private var adj: Adjustments { library.adjustments(photo) }

    private func binding(_ param: Param) -> Binding<Double> {
        Binding(get: { library.adjustments(photo)[param] }, set: { value in
            var a = library.adjustments(photo)
            a[param] = value
            library.setAdjustments(a, for: photo)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HistogramView(histogram: session.histogram)
                    if let metadata { ShotChips(metadata: metadata) }
                    ForEach(Param.Group.allCases) { group in
                        PanelBox(title: group.rawValue, canReset: group.params.contains { adj[$0] != 0 }) {
                            change { a in group.params.forEach { a[$0] = 0 } }
                        } content: {
                            ForEach(group.params) { param in
                                ParamSlider(param: param, value: binding(param), onBegin: snapshot)
                            }
                        }
                    }
                    geometry
                    Text("보정은 Apple Core Image 기본 필터(macOS 사진 앱과 같은 엔진)로 처리해서, 카메라의 이미지 컨트롤이나 카메라 내부 처리와는 달라요. 슬라이더 이름에 마우스를 올리면 쓰는 필터가 보입니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
            }
            Divider()
            actions
        }
        .frame(width: 300)
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: source) {
            let url = source
            metadata = await Task.detached { PhotoMetadata.read(url) }.value
        }
    }

    private var geometry: some View {
        PanelBox(title: "자르기·회전",
                 canReset: adj.quarterTurns != 0 || adj.flipped || adj.crop != nil || adj[.straighten] != 0) {
            change { $0.quarterTurns = 0; $0.flipped = false; $0.crop = nil; $0[.straighten] = 0 }
        } content: {
            HStack(spacing: 6) {
                Button { change { $0.quarterTurns -= 1; $0.crop = nil } } label: {
                    Label("왼쪽", systemImage: "rotate.left")
                }
                .help("왼쪽으로 90° (자르기는 초기화)")
                Button { change { $0.quarterTurns += 1; $0.crop = nil } } label: {
                    Label("오른쪽", systemImage: "rotate.right")
                }
                .help("오른쪽으로 90° (자르기는 초기화)")
                Button { change { $0.flipped.toggle(); $0.crop = nil } } label: {
                    Label("반전", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("좌우 반전 (자르기는 초기화)")
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)

            HStack(spacing: 6) {
                Button {
                    if !session.cropping { snapshot() }
                    session.cropping.toggle()
                } label: {
                    Label(session.cropping ? "자르기 완료" : "자르기", systemImage: "crop")
                }
                .buttonStyle(.borderedProminent)
                .tint(session.cropping ? .accentColor : .gray)
                .keyboardShortcut(session.cropping ? .return : "r", modifiers: [])
                .help("R: 자르기 시작, Return: 완료")
                Picker("", selection: $session.cropAspect) {
                    ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Toggle("세로", isOn: $session.cropPortrait)
                    .toggleStyle(.checkbox)
                    .disabled(session.cropAspect == .free || session.cropAspect == .square)
            }
            .controlSize(.small)
            .onChange(of: session.cropAspect) { _, _ in applyAspect() }
            .onChange(of: session.cropPortrait) { _, _ in applyAspect() }

            ParamSlider(param: .straighten, value: binding(.straighten), onBegin: snapshot)
        }
    }

    /// Fits the largest box of the chosen ratio inside the current crop, centered.
    private func applyAspect() {
        guard let image = session.uncroppedSize,
              let ratio = session.cropAspect.ratio(original: image.width / image.height, portrait: session.cropPortrait) else { return }
        let current = adj.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let normalized = ratio * image.height / image.width
        var w = current.width, h = w / normalized
        if h > current.height { h = current.height; w = h * normalized }
        change { $0.cropRect = CGRect(x: current.midX - w / 2, y: current.midY - h / 2, width: w, height: h) }
        if !session.cropping { session.cropping = true }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .help("실행 취소 (⌘Z)")
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("다시 실행 (⇧⌘Z)")
                Button("원본으로") {
                    snapshot()
                    library.setAdjustments(Adjustments(), for: photo)
                }
                .disabled(adj.isDefault)
                .help("모든 편집을 지워요 (실행 취소 가능)")
                Spacer()
                Menu {
                    Button("설정 복사") {
                        copiedAdjustments = adj
                        hasCopy = true
                        message = "설정을 복사했어요"
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    Button("붙여넣기") { paste([photo]) }
                        .keyboardShortcut("v", modifiers: [.command, .shift])
                        .disabled(!hasCopy)
                    Button("선택한 사진 \(library.selection.count)장에 붙여넣기") {
                        paste(library.visible.filter { library.selection.contains($0.id) })
                    }
                    .disabled(!hasCopy || library.selection.isEmpty)
                } label: { Image(systemName: "doc.on.doc") }
                .fixedSize()
                .help("설정 복사 / 붙여넣기")
            }
            HStack {
                Picker("", selection: $formatRaw) {
                    ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                if ExportFormat(rawValue: formatRaw)?.isLossy ?? true {
                    Text("품질").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $quality, in: 0.5...1).controlSize(.small)
                    Text("\(Int(quality * 100))").font(.caption.monospacedDigit()).frame(width: 26)
                } else {
                    Spacer()
                }
            }
            Button {
                saveAs()
            } label: {
                if session.busy != nil { ProgressView().controlSize(.small) } else { Text("다른 이름으로 저장…").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(session.busy != nil)
            Label("편집은 이 Mac에만 저장돼요. 카메라의 사진과 저장 폴더의 원본은 바뀌지 않고, ‘다른 이름으로 저장’하면 새 파일로 만들어져요.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private func snapshot() {
        session.undoStack.append(adj)
        if session.undoStack.count > 100 { session.undoStack.removeFirst() }
        session.redoStack = []
    }

    private func change(_ edit: (inout Adjustments) -> Void) {
        snapshot()
        var a = adj
        edit(&a)
        library.setAdjustments(a, for: photo)
    }

    private func undo() {
        guard let last = session.undoStack.popLast() else { return }
        session.redoStack.append(adj)
        library.setAdjustments(last, for: photo)
    }

    private func redo() {
        guard let next = session.redoStack.popLast() else { return }
        session.undoStack.append(adj)
        library.setAdjustments(next, for: photo)
    }

    private func paste(_ photos: [Photo]) {
        guard let copied = copiedAdjustments else { return }
        if photos.contains(photo) { snapshot() }
        for p in photos { library.setAdjustments(copied, for: p) }
        message = "\(photos.count)장에 설정을 붙여넣었어요"
    }

    private func saveAs() {
        let format = ExportFormat(rawValue: formatRaw) ?? .jpeg
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-edit." + format.fileExtension
        panel.message = "편집한 사진을 \(format.rawValue)로 저장해요. 원본 파일은 그대로 남아요."
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let adj = self.adj, source = self.source, quality = self.quality
        session.busy = "저장 중"
        message = "저장 중…"
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try DevelopEngine.export(source: source, adj: adj, to: target, format: format, quality: quality)
                    return nil
                } catch { return error.localizedDescription }
            }.value
            session.busy = nil
            message = error.map { "저장 실패: \($0)" } ?? "저장함: \(target.lastPathComponent)"
            library.refreshSaved()
            if error == nil { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        }
    }
}

/// A titled group in the edit panel with its own reset.
private struct PanelBox<Content: View>: View {
    let title: String
    var canReset: Bool
    var reset: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                if canReset {
                    Button("초기화", action: reset).buttonStyle(.link).font(.caption)
                }
            }
            content
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Label (double-click resets), slider and an editable number.
private struct ParamSlider: View {
    let param: Param
    @Binding var value: Double
    var onBegin: () -> Void
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(param.label)
                .font(.callout)
                .foregroundStyle(value == 0 ? .secondary : .primary)
                .frame(width: 70, alignment: .leading)
                .onTapGesture(count: 2) { onBegin(); value = 0 }
                .help("\(param.filter) · 더블클릭하면 0으로")
            Slider(value: Binding(get: { value }, set: { value = ($0 / param.step).rounded() * param.step }),
                   in: param.range, onEditingChanged: { if $0 { onBegin() } })
                .controlSize(.small)
            TextField("", text: $text)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .frame(width: 58)
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { _, now in if !now { commit() } }
        }
        .onAppear { text = param.format(value) }
        .onChange(of: value) { _, v in if !editing { text = param.format(v) } }
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "EV", with: "")
        if let v = Double(cleaned.trimmingCharacters(in: .whitespaces)) {
            onBegin()
            value = min(max(v, param.range.lowerBound), param.range.upperBound)
        }
        text = param.format(value)
    }
}

/// Crop box over the whole (uncropped) frame: drag inside to move, corners to resize.
private struct CropEditor: View {
    let image: NSImage?
    @Binding var rect: CGRect
    let aspect: CGFloat?
    var onBegin: () -> Void
    @State private var start: CGRect?

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        GeometryReader { geo in
            let fit = fitRect(in: geo.size)
            let box = CGRect(x: fit.minX + rect.minX * fit.width, y: fit.minY + rect.minY * fit.height,
                             width: rect.width * fit.width, height: rect.height * fit.height)
            ZStack(alignment: .topLeading) {
                Color.black
                if let image {
                    Image(nsImage: image).resizable()
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                }
                Path { p in p.addRect(fit); p.addRect(box) }
                    .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                Path { p in
                    for i in 1...2 {
                        let x = box.minX + box.width * CGFloat(i) / 3, y = box.minY + box.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                        p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .contentShape(Rectangle())
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .gesture(DragGesture().onChanged { v in move(v.translation, fit: fit) }.onEnded { _ in start = nil })
                    .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                ForEach(Corner.allCases, id: \.self) { corner in
                    let p = point(corner, of: box)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(radius: 1)
                        .position(p)
                        .gesture(DragGesture().onChanged { v in resize(corner, v.translation, fit: fit) }.onEnded { _ in start = nil })
                }
            }
        }
    }

    private func fitRect(in size: CGSize) -> CGRect {
        guard let rep = image?.representations.first, rep.pixelsWide > 0 else { return .zero }
        let pw = CGFloat(rep.pixelsWide), ph = CGFloat(rep.pixelsHigh)
        let s = min((size.width - 40) / pw, (size.height - 40) / ph)
        let w = pw * s, h = ph * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func point(_ c: Corner, of r: CGRect) -> CGPoint {
        switch c {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func begin() -> CGRect {
        if let start { return start }
        onBegin()
        start = rect
        return rect
    }

    private func move(_ t: CGSize, fit: CGRect) {
        guard fit.width > 0 else { return }
        let s = begin()
        let x = min(max(s.minX + t.width / fit.width, 0), 1 - s.width)
        let y = min(max(s.minY + t.height / fit.height, 0), 1 - s.height)
        rect = CGRect(x: x, y: y, width: s.width, height: s.height)
    }

    private func resize(_ c: Corner, _ t: CGSize, fit: CGRect) {
        guard fit.width > 0 else { return }
        let s = begin()
        let left = c == .topLeft || c == .bottomLeft, top = c == .topLeft || c == .topRight
        // The opposite corner stays put.
        let fx = left ? s.maxX : s.minX, fy = top ? s.maxY : s.minY
        let mx = min(max((left ? s.minX : s.maxX) + t.width / fit.width, 0), 1)
        let my = min(max((top ? s.minY : s.maxY) + t.height / fit.height, 0), 1)
        var w = max(abs(fx - mx), 0.05), h = max(abs(fy - my), 0.05)
        if let aspect {
            let n = aspect * fit.height / fit.width
            h = w / n
            let maxH = top ? fy : 1 - fy, maxW = left ? fx : 1 - fx
            if h > maxH { h = maxH; w = h * n }
            if w > maxW { w = maxW; h = w / n }
        }
        rect = CGRect(x: left ? fx - w : fx, y: top ? fy - h : fy, width: w, height: h)
    }
}
