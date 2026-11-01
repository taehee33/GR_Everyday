import AVKit
import SwiftUI

/// What the scroll wheel / trackpad scroll does over a photo. Chosen in 설정 → 조작.
enum ScrollAction: String, CaseIterable, Identifiable {
    case pan, zoom, navigate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pan: return "확대돼 있으면 이동, 아니면 사진 넘기기"
        case .zoom: return "확대/축소"
        case .navigate: return "이전/다음 사진"
        }
    }
}

/// What dragging a photo with the mouse does.
enum DragAction: String, CaseIterable, Identifiable {
    case panSwipe, pan, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .panSwipe: return "확대돼 있으면 이동, 아니면 좌우로 넘기기"
        case .pan: return "확대돼 있을 때 이동만"
        case .none: return "사용 안 함"
        }
    }
}

/// What clicking a photo does.
enum ClickAction: String, CaseIterable, Identifiable {
    case single, double, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .single: return "클릭: 맞춤 ↔ 100%"
        case .double: return "더블클릭: 맞춤 ↔ 100%"
        case .none: return "사용 안 함"
        }
    }
}

/// What dragging across the grid does.
enum GridDragAction: String, CaseIterable, Identifiable {
    case select, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: return "드래그한 영역의 사진 선택"
        case .none: return "사용 안 함"
        }
    }
}

/// Zoom of the loupe / develop canvas. `scale` 1 is "fit"; fill and 100% are reported
/// by the canvas because they depend on its size.
struct ZoomState: Equatable {
    enum Mode: Equatable { case fit, fill, actual, custom }
    var mode: Mode = .fit
    var custom: CGFloat = 1
    var offset: CGSize = .zero
    var fillScale: CGFloat = 1
    var actualScale: CGFloat = 1

    static let maxScale: CGFloat = 16

    var scale: CGFloat {
        switch mode {
        case .fit: return 1
        case .fill: return fillScale
        case .actual: return actualScale
        case .custom: return custom
        }
    }

    var isZoomed: Bool { scale > 1.001 }
    /// Relative to the image's own pixels (100% = one image pixel per screen pixel).
    var percent: Int { Int((scale / max(actualScale, 0.0001) * 100).rounded()) }

    mutating func set(_ value: CGFloat) {
        custom = min(max(value, 1), max(Self.maxScale, actualScale))
        mode = .custom
        if custom <= 1.001 { mode = .fit; offset = .zero }
    }

    mutating func reset() { mode = .fit; offset = .zero }
}

/// Mouse / trackpad events over a photo, read from an AppKit view so scroll, drag and
/// pinch can be told apart and remapped.
struct PointerEvents: NSViewRepresentable {
    var onScroll: (NSEvent, CGPoint) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onDrag: (CGSize, Bool) -> Void
    var onClick: (Int, CGPoint) -> Void

    final class View: NSView {
        var parent: PointerEvents!
        private var start: CGPoint?
        private var dragging = false

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

        override func scrollWheel(with e: NSEvent) { parent.onScroll(e, point(e)) }
        override func magnify(with e: NSEvent) { parent.onMagnify(e.magnification, point(e)) }

        override func mouseDown(with e: NSEvent) {
            start = point(e)
            dragging = false
        }

        override func mouseDragged(with e: NSEvent) {
            guard let start else { return }
            let p = point(e)
            if !dragging, hypot(p.x - start.x, p.y - start.y) > 3 {
                dragging = true
                NSCursor.closedHand.push()
            }
            if dragging { parent.onDrag(CGSize(width: p.x - start.x, height: p.y - start.y), false) }
        }

        override func mouseUp(with e: NSEvent) {
            if dragging, let start {
                let p = point(e)
                NSCursor.pop()
                parent.onDrag(CGSize(width: p.x - start.x, height: p.y - start.y), true)
            } else {
                parent.onClick(e.clickCount, point(e))
            }
            start = nil
            dragging = false
        }
    }

    func makeNSView(context: Context) -> View {
        let v = View()
        v.parent = self
        return v
    }

    func updateNSView(_ v: View, context: Context) { v.parent = self }
}

/// A photo shown fit to the view, zoomed and panned according to `zoom` and the
/// pointer settings. `before`, with `split` (0…1), shows another image on the left part.
struct PhotoCanvas: View {
    let image: NSImage?
    @Binding var zoom: ZoomState
    var before: NSImage? = nil
    var split: CGFloat? = nil
    var onNavigate: (Int) -> Void = { _ in }

    @AppStorage("loupeScroll") private var scrollAction = ScrollAction.zoom
    @AppStorage("loupeDrag") private var dragAction = DragAction.pan
    @AppStorage("loupeClick") private var clickAction = ClickAction.double
    @AppStorage("invertNavigateScroll") private var invertNavigate = false

    @State private var dragStartOffset: CGSize?
    @State private var swipe: CGFloat = 0
    @State private var scrollAccumulator: CGFloat = 0
    @State private var lastNavigate = Date.distantPast

    var body: some View {
        GeometryReader { geo in
            let pixels = image.map(pixelSize) ?? CGSize(width: 3, height: 2)
            let fit = fitSize(pixels, in: geo.size)
            let scale = zoom.scale
            ZStack {
                Color.black
                if let image {
                    picture(image, size: CGSize(width: fit.width * scale, height: fit.height * scale))
                        .offset(x: zoom.offset.width + swipe, y: zoom.offset.height)
                    if let before, let split {
                        picture(before, size: fitSize(pixelSize(before), in: geo.size).applying(.init(scaleX: scale, y: scale)))
                            .offset(x: zoom.offset.width, y: zoom.offset.height)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geo.size.width * split)
                            }
                    }
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay {
                PointerEvents(
                    onScroll: { e, p in scroll(e, at: p, size: geo.size, fit: fit) },
                    onMagnify: { m, p in zoom(to: zoom.scale * (1 + m), at: p, size: geo.size, fit: fit) },
                    onDrag: { t, ended in drag(t, ended: ended, size: geo.size, fit: fit) },
                    onClick: { count, p in click(count, at: p, size: geo.size, fit: fit) }
                )
            }
            .onAppear { updateMetrics(pixels, size: geo.size) }
            .onChange(of: geo.size) { _, size in updateMetrics(pixels, size: size) }
            .onChange(of: pixels) { _, px in updateMetrics(px, size: geo.size) }
            .onChange(of: zoom.mode) { _, _ in zoom.offset = clamp(zoom.offset, size: geo.size, fit: fit, scale: zoom.scale) }
        }
    }

    private func picture(_ image: NSImage, size: CGSize) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(zoom.percent >= 200 ? .none : .high)
            .frame(width: size.width, height: size.height)
    }

    private func pixelSize(_ image: NSImage) -> CGSize {
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    private func fitSize(_ pixels: CGSize, in size: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let s = min(size.width / pixels.width, size.height / pixels.height)
        return CGSize(width: pixels.width * s, height: pixels.height * s)
    }

    private func updateMetrics(_ pixels: CGSize, size: CGSize) {
        let fit = fitSize(pixels, in: size)
        guard fit.width > 0 else { return }
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        zoom.fillScale = max(size.width / fit.width, size.height / fit.height)
        zoom.actualScale = max(pixels.width / backing / fit.width, 0.01)
        zoom.offset = clamp(zoom.offset, size: size, fit: fit, scale: zoom.scale)
    }

    private func clamp(_ offset: CGSize, size: CGSize, fit: CGSize, scale: CGFloat) -> CGSize {
        let maxX = max(0, (fit.width * scale - size.width) / 2)
        let maxY = max(0, (fit.height * scale - size.height) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    /// Zoom keeping the image point under `p` in place.
    private func zoom(to value: CGFloat, at p: CGPoint, size: CGSize, fit: CGSize) {
        let old = zoom.scale
        zoom.set(value)
        let new = zoom.scale
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let qx = (p.x - c.x - zoom.offset.width) / old, qy = (p.y - c.y - zoom.offset.height) / old
        zoom.offset = clamp(CGSize(width: p.x - c.x - qx * new, height: p.y - c.y - qy * new), size: size, fit: fit, scale: new)
    }

    private func scroll(_ e: NSEvent, at p: CGPoint, size: CGSize, fit: CGSize) {
        let precise = e.hasPreciseScrollingDeltas
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        let modifierZoom = e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option)
        let action: ScrollAction = modifierZoom ? .zoom : scrollAction
        switch action {
        case .zoom:
            zoom(to: zoom.scale * exp(dy * (precise ? 0.01 : 0.1)), at: p, size: size, fit: fit)
        case .pan where zoom.isZoomed:
            let k: CGFloat = precise ? 1 : 12
            zoom.offset = clamp(CGSize(width: zoom.offset.width + dx * k, height: zoom.offset.height + dy * k),
                                size: size, fit: fit, scale: zoom.scale)
        case .pan, .navigate:
            // One photo per wheel notch, or per swipe on a trackpad (momentum ignored).
            guard e.momentumPhase.isEmpty else { return }
            let delta = abs(dx) > abs(dy) ? dx : dy
            if !precise {
                guard delta != 0, Date().timeIntervalSince(lastNavigate) > 0.12 else { return }
                navigate(delta < 0 ? 1 : -1)
                return
            }
            if e.phase == .began { scrollAccumulator = 0 }
            scrollAccumulator += delta
            if abs(scrollAccumulator) > 50 {
                navigate(scrollAccumulator < 0 ? 1 : -1)
                scrollAccumulator = 0
            }
        }
    }

    private func navigate(_ step: Int) {
        lastNavigate = Date()
        onNavigate(invertNavigate ? -step : step)
    }

    private func drag(_ t: CGSize, ended: Bool, size: CGSize, fit: CGSize) {
        guard dragAction != .none else { return }
        if zoom.isZoomed {
            let start = dragStartOffset ?? zoom.offset
            dragStartOffset = ended ? nil : start
            zoom.offset = clamp(CGSize(width: start.width + t.width, height: start.height + t.height),
                                size: size, fit: fit, scale: zoom.scale)
        } else if dragAction == .panSwipe {
            if ended {
                if abs(t.width) > 60 { navigate(t.width < 0 ? 1 : -1) }
                withAnimation(.easeOut(duration: 0.15)) { swipe = 0 }
            } else {
                swipe = t.width
            }
        }
    }

    private func click(_ count: Int, at p: CGPoint, size: CGSize, fit: CGSize) {
        let wanted = clickAction == .single ? 1 : clickAction == .double ? 2 : 0
        guard count == wanted else { return }
        if zoom.isZoomed {
            withAnimation(.easeOut(duration: 0.15)) { zoom.reset() }
        } else {
            let target = max(zoom.actualScale, 2)
            withAnimation(.easeOut(duration: 0.15)) { zoom(to: target, at: p, size: size, fit: fit) }
        }
    }
}

struct HistogramView: View {
    let histogram: Histogram?

    var body: some View {
        Canvas { ctx, size in
            guard let h = histogram else { return }
            func path(_ bins: [Double]) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in bins.enumerated() {
                    p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(bins.count - 1), y: size.height * (1 - v)))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            ctx.blendMode = .plusLighter
            ctx.fill(path(h.red), with: .color(.red.opacity(0.55)))
            ctx.fill(path(h.green), with: .color(.green.opacity(0.55)))
            ctx.fill(path(h.blue), with: .color(.blue.opacity(0.6)))
            ctx.blendMode = .normal
            ctx.stroke(path(h.luma), with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
        .frame(height: 80)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
        .overlay {
            if histogram == nil { ProgressView().controlSize(.small) }
        }
    }
}

/// Plays a movie: the saved copy when there is one, otherwise streamed from the camera,
/// and downloaded first when the camera can't stream it.
struct VideoViewer: View {
    let photo: Photo
    let localURL: URL?

    @State private var player: AVPlayer?
    @State private var progress: Double?
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayerView(player: player)
            } else if let error {
                ContentUnavailableView("재생할 수 없음", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let progress {
                VStack(spacing: 8) {
                    Text("카메라에서 바로 재생할 수 없어 내려받는 중…").foregroundStyle(.secondary)
                    ProgressView(value: progress).frame(width: 260)
                    Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("영상 여는 중…")
            }
        }
        .task(id: photo.id) { await open() }
        .onDisappear { player?.pause() }
    }

    static var cacheFolder: URL { ImageCache.folder.appendingPathComponent("videos", isDirectory: true) }

    private func open() async {
        player?.pause()
        player = nil
        progress = nil
        error = nil
        let cached = Self.cacheFolder.appendingPathComponent(photo.dir + "-" + photo.name)
        if let local = localURL ?? (FileManager.default.fileExists(atPath: cached.path) ? cached : nil) {
            start(AVPlayer(url: local))
            return
        }
        let streaming = AVPlayer(url: CameraAPI.photoURL(photo))
        for _ in 0..<32 {
            if Task.isCancelled { return }
            if streaming.currentItem?.status == .readyToPlay { start(streaming); return }
            if streaming.currentItem?.status == .failed { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        streaming.replaceCurrentItem(with: nil)
        progress = 0
        do {
            let (file, response) = try await Downloader.fetch(CameraAPI.photoURL(photo)) { fraction in
                Task { @MainActor in progress = fraction }
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw CameraAPI.APIError(message: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            try FileManager.default.createDirectory(at: Self.cacheFolder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.moveItem(at: file, to: cached)
            if Task.isCancelled { return }
            start(AVPlayer(url: cached))
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func start(_ p: AVPlayer) {
        progress = nil
        player = p
        p.play()
    }
}

private struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// Keyboard and ⌘-scroll handling for the library while it is on screen. Text fields keep
/// their keys; the handler returns true when it used the event.
struct KeyMonitor: NSViewRepresentable {
    var onKey: (NSEvent) -> Bool
    var onScroll: (NSEvent) -> Bool = { _ in false }

    final class View: NSView {
        var parent: KeyMonitor!
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] e in
                guard let self, let window = self.window, e.window === window, window.attachedSheet == nil else { return e }
                if e.type == .scrollWheel { return self.parent.onScroll(e) ? nil : e }
                if window.firstResponder is NSText { return e }
                return self.parent.onKey(e) ? nil : e
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> View {
        let v = View()
        v.parent = self
        return v
    }

    func updateNSView(_ v: View, context: Context) { v.parent = self }
}
