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
                main
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
            session.render(library.adjustments(photo))
        }
        .onChange(of: library.current.map { library.adjustments($0) }) { _, adj in
            if let adj { session.render(adj) }
        }
    }

    @ViewBuilder private var main: some View {
        if let photo = library.current {
            if photo.kind == .video {
                ContentUnavailableView("동영상은 편집할 수 없습니다", systemImage: "video",
                                       description: Text("확대 보기(E)에서 재생할 수 있습니다."))
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
            Label("Mac에 저장한 사진만 편집할 수 있습니다", systemImage: "square.and.arrow.down")
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

private struct DevelopPanel: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    let source: URL
    @ObservedObject var session: DevelopSession

    @AppStorage("exportFormat") private var formatRaw = ExportFormat.jpeg.rawValue
    @AppStorage("exportQuality") private var quality = 0.92
    @State private var message: String?
    @State private var hasCopy = copiedAdjustments != nil

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
                VStack(alignment: .leading, spacing: 14) {
                    HistogramView(histogram: session.histogram)
                    geometry
                }
                .padding(12)
            }
            Divider()
            actions
        }
        .frame(width: 290)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            content()
        }
    }

    private var geometry: some View {
        section("회전·반전·수평") {
            HStack {
                Button { change { $0.quarterTurns -= 1 } } label: { Image(systemName: "rotate.left") }.help("왼쪽으로 90°")
                Button { change { $0.quarterTurns += 1 } } label: { Image(systemName: "rotate.right") }.help("오른쪽으로 90°")
                Button { change { $0.flipped.toggle() } } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("좌우 반전")
                Spacer()
            }
            ParamSlider(param: .straighten, value: binding(.straighten), onBegin: snapshot)
        }
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
                .help("모든 조정을 지웁니다 (실행 취소 가능)")
                Spacer()
                Menu {
                    Button("설정 복사") {
                        copiedAdjustments = adj
                        hasCopy = true
                        message = "설정을 복사했습니다"
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
        message = "\(photos.count)장에 설정을 붙여넣었습니다"
    }

    private func saveAs() {
        let format = ExportFormat(rawValue: formatRaw) ?? .jpeg
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        panel.directoryURL = source.deletingLastPathComponent()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-edit." + format.fileExtension
        panel.message = "편집한 사진을 \(format.rawValue)로 저장합니다. 원본 파일은 그대로 남습니다."
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

/// Label (double-click resets), slider and an editable number.
private struct ParamSlider: View {
    let param: Param
    @Binding var value: Double
    var onBegin: () -> Void
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(param.label)
                .font(.caption)
                .foregroundStyle(value == 0 ? .secondary : .primary)
                .frame(width: 64, alignment: .leading)
                .onTapGesture(count: 2) { onBegin(); value = 0 }
                .help("더블클릭하면 0으로")
            Slider(value: Binding(get: { value }, set: { value = ($0 / param.step).rounded() * param.step }),
                   in: param.range, onEditingChanged: { if $0 { onBegin() } })
                .controlSize(.mini)
            TextField("", text: $text)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .frame(width: 46)
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { _, now in if !now { commit() } }
        }
        .onAppear { text = param.format(value) }
        .onChange(of: value) { _, v in if !editing { text = param.format(v) } }
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "+", with: "")
        if let v = Double(cleaned.trimmingCharacters(in: .whitespaces)) {
            onBegin()
            value = min(max(v, param.range.lowerBound), param.range.upperBound)
        }
        text = param.format(value)
    }
}
