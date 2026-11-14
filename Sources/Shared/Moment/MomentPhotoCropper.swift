import SwiftUI

/// Framing a photo before it is uploaded: turn it a quarter at a time or tilt it to any angle
/// on the dial, pick a shape (or 자유 to
/// drag the frame's corners and edges to any shape), then drag to move and pinch (or the
/// slider) to zoom. The photo always fills the frame, and the crop can't get so small that the
/// photo would drop under MomentImage.minimumEdge.
struct MomentPhotoCropper: View {
    /// The original as loaded (upright, unturned).
    let original: CGImage
    let start: MomentCropEdit
    let onDone: (MomentCropEdit) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var turns = 0
    /// Free tilt in degrees, clockwise (−45…45).
    @State private var angle: Double = 0
    @State private var tilting = false
    @State private var tool: Tool = .crop
    @State private var aspect: MomentCropAspect = .original
    /// For fixed shapes other than 원본 and 1:1: frame taller than wide.
    @State private var portrait = false
    /// Points per pixel of the turned photo; never less than what covers the frame.
    @State private var scaleStore: CGFloat = 0
    /// Centre of the photo from the centre of the area.
    @State private var offset: CGSize = .zero
    /// 자유: the frame's size, and how far its centre sits from the area's centre (only while a
    /// handle is being dragged; it is centred again on release).
    @State private var freeSize: CGSize?
    @State private var frameShift: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var handleStart: (rect: CGRect, scale: CGFloat)?
    @State private var area: CGSize = .zero
    @State private var ready = false
    @State private var preview: CGImage?
    @State private var turnedPreview: CGImage?

    private static let margin: CGFloat = 20
    private static let minSide: CGFloat = 44

    private var turnedSize: CGSize {
        let w = CGFloat(original.width), h = CGFloat(original.height)
        return turns % 2 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
    }

    private var box: CGSize {
        CGSize(width: max(area.width - 2 * Self.margin, 120), height: max(area.height - 2 * Self.margin, 120))
    }

    private func fit(_ ratio: CGFloat) -> CGSize {
        box.width / box.height > ratio
            ? CGSize(width: box.height * ratio, height: box.height)
            : CGSize(width: box.width, height: box.width / ratio)
    }

    /// Width over height of a fixed shape.
    private var fixedRatio: CGFloat {
        guard let ratio = aspect.ratio else { return turnedSize.width / turnedSize.height }
        return portrait ? 1 / ratio : ratio
    }

    /// The crop frame in points.
    private var frameSize: CGSize {
        if aspect == .free, let freeSize { return freeSize }
        return fit(fixedRatio)
    }

    /// The scale at which the photo just covers the frame.
    private var coverScale: CGFloat {
        max(frameSize.width / turnedSize.width, frameSize.height / turnedSize.height)
    }

    private var scale: CGFloat { max(scaleStore, coverScale) }
    private var zoom: CGFloat { scale / coverScale }

    /// The most it may zoom: the crop keeps a long side of at least minimumEdge pixels.
    private var maxZoom: CGFloat {
        let longAtCover = max(frameSize.width, frameSize.height) / coverScale / tiltZoom
        return max(1, min(5, longAtCover / CGFloat(MomentImage.minimumEdge)))
    }

    /// How much the tilted photo is enlarged to keep its corners filled.
    private var tiltZoom: CGFloat {
        MomentImage.straightenZoom(width: turnedSize.width, height: turnedSize.height, degrees: angle)
    }

    private var shownSize: CGSize {
        CGSize(width: turnedSize.width * scale, height: turnedSize.height * scale)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                GeometryReader { proxy in
                    ZStack {
                        if let image = turnedPreview {
                            // Tilted live here; MomentImage.straightened does the same on upload.
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .frame(width: shownSize.width, height: shownSize.height)
                                .scaleEffect(tiltZoom)
                                .rotationEffect(.degrees(angle))
                                .frame(width: shownSize.width, height: shownSize.height)
                                .clipped()
                                .offset(offset)
                        }
                        // Dim what will be cut off, then draw the frame and thirds.
                        Rectangle()
                            .fill(Color.black.opacity(0.6))
                            .mask {
                                Rectangle()
                                    .overlay {
                                        Rectangle().frame(width: frameSize.width, height: frameSize.height)
                                            .offset(frameShift)
                                            .blendMode(.destinationOut)
                                    }
                                    .compositingGroup()
                            }
                            .allowsHitTesting(false)
                        ThirdsGuide(divisions: tilting ? 6 : 3)
                            .stroke(Color.white.opacity(tilting ? 0.5 : 0.35), lineWidth: 0.5)
                            .animation(.easeOut(duration: 0.15), value: tilting)
                            .frame(width: frameSize.width, height: frameSize.height)
                            .offset(frameShift)
                            .allowsHitTesting(false)
                        Rectangle()
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                            .frame(width: frameSize.width, height: frameSize.height)
                            .offset(frameShift)
                            .allowsHitTesting(false)
                        if aspect == .free { handles }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(dragAndPinch)
                    .onAppear {
                        area = proxy.size
                        if !ready { restore() }
                    }
                    .onChange(of: proxy.size) { _, new in
                        // Keep the same part framed when the window changes size.
                        let kept = result.crop
                        area = new
                        apply(kept)
                    }
                }
                .frame(minHeight: 300)

                controls
            }
            .padding(.vertical)
            .background(Color.black.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .navigationTitle("자르기·회전")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        onDone(result)
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 760, minHeight: 660, idealHeight: 780)
        #endif
    }

    /// The three tools; only the picked one's controls show, so each stays big and clear.
    private enum Tool: String, CaseIterable, Identifiable {
        case crop = "자르기", rotate = "회전", zoom = "확대"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .crop: return "crop"
            case .rotate: return "rotate.left"
            case .zoom: return "plus.magnifyingglass"
            }
        }
    }

    private var isPristine: Bool {
        turns == 0 && angle == 0 && aspect == .original && zoom < 1.001 && result.crop == CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            ZStack {
                switch tool {
                case .crop: cropPanel
                case .rotate: rotatePanel
                case .zoom: zoomPanel
                }
            }
            .frame(height: 96)
            .frame(maxWidth: 460)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.18), value: tool)

            HStack(spacing: 0) {
                ForEach(Tool.allCases) { item in
                    Button {
                        tool = item
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon).font(.system(size: 20, weight: .medium))
                            Text(item.rawValue).font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(tool == item ? Color.yellow : Color.white.opacity(0.6))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tool == item ? .isSelected : [])
                }
            }
            .frame(maxWidth: 360)

            Text(hint)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 36, alignment: .top)
                .padding(.horizontal)
        }
    }

    private var hint: String {
        switch tool {
        case .crop:
            return aspect == .free
                ? "모서리나 변을 끌어 원하는 모양으로 자르고, 사진을 끌어 위치를 맞춰 주세요."
                : "비율을 고르고 사진을 끌어 위치를 맞춰 주세요."
        case .rotate:
            return "눈금을 좌우로 끌어 기울기를 맞춰 주세요. 두 번 탭하면 수평으로 돌아가요."
        case .zoom:
            return "막대나 두 손가락으로 크기를, 사진을 끌어 위치를 맞춰 주세요."
        }
    }

    private var cropPanel: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MomentCropAspect.allCases) { item in
                        Button { setAspect(item) } label: {
                            Text(item.title)
                                .font(.footnote.weight(aspect == item ? .semibold : .regular))
                                .foregroundStyle(aspect == item ? Color.black : Color.white)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(aspect == item ? Color.yellow : Color.white.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(aspect == item ? .isSelected : [])
                    }
                }
                .padding(.horizontal)
                .frame(minWidth: 0)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 12) {
                Button {
                    portrait.toggle()
                    resetFraming()
                } label: {
                    Label(portrait ? "세로" : "가로", systemImage: portrait ? "rectangle.portrait" : "rectangle")
                }
                .disabled(aspect.ratio == nil || aspect == .square)
                .accessibilityLabel("가로 세로 바꾸기")
                resetButton
            }
            .buttonStyle(.bordered)
            .font(.footnote)
        }
    }

    private var rotatePanel: some View {
        VStack(spacing: 10) {
            StraightenDial(angle: $angle, editing: $tilting)
                .padding(.horizontal)
            HStack(spacing: 12) {
                Button { turn() } label: {
                    Label("90° 회전", systemImage: "rotate.left")
                }
                .accessibilityLabel("왼쪽으로 90도 회전")
                resetButton
            }
            .buttonStyle(.bordered)
            .font(.footnote)
        }
    }

    private var zoomPanel: some View {
        VStack(spacing: 10) {
            Text(String(format: "%.1f×", zoom))
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(zoom > 1.001 ? Color.yellow : Color.secondary)
            HStack(spacing: 12) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { zoom }, set: setZoom), in: 1...max(maxZoom, 1.0001))
                    .tint(.yellow)
                    .disabled(maxZoom <= 1.01)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            if maxZoom <= 1.01 {
                Text("업로드 최소 크기 때문에 더 확대할 수 없어요.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var resetButton: some View {
        Button {
            turns = 0
            angle = 0
            aspect = .original
            portrait = false
            makePreview()
            resetFraming()
        } label: {
            Label("처음대로", systemImage: "arrow.uturn.backward")
        }
        .disabled(isPristine)
    }

    // MARK: Gestures

    private var dragAndPinch: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? offset
                dragStart = start
                offset = clamped(CGSize(width: start.width + value.translation.width,
                                        height: start.height + value.translation.height))
            }
            .onEnded { _ in dragStart = nil }
            .simultaneously(with:
                MagnifyGesture()
                    .onChanged { value in
                        let start = zoomStart ?? zoom
                        zoomStart = start
                        setZoom(start * value.magnification)
                    }
                    .onEnded { _ in zoomStart = nil }
            )
    }

    /// 자유: corner and edge handles. Each moves its own edges; the photo stays still while
    /// dragging, and on release the frame is centred and enlarged to fill the area again.
    private var handles: some View {
        let rect = CGRect(x: frameShift.width - frameSize.width / 2, y: frameShift.height - frameSize.height / 2,
                          width: frameSize.width, height: frameSize.height)
        let spots: [(x: CGFloat, y: CGFloat)] = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]
        return ZStack {
            ForEach(spots.indices, id: \.self) { i in
                let spot = spots[i]
                let corner = spot.x != 0 && spot.y != 0
                Group {
                    if corner {
                        CornerMark(x: spot.x, y: spot.y)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 20, height: 20)
                    } else {
                        Capsule().fill(Color.white)
                            .frame(width: spot.x == 0 ? 26 : 4, height: spot.x == 0 ? 4 : 26)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .offset(x: rect.midX + spot.x * rect.width / 2, y: rect.midY + spot.y * rect.height / 2)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in moveHandle(spot, by: value.translation) }
                        .onEnded { _ in
                            handleStart = nil
                            withAnimation(.snappy(duration: 0.3)) { apply(result.crop) }
                        }
                )
                .accessibilityHidden(true)
            }
        }
    }

    private func moveHandle(_ spot: (x: CGFloat, y: CGFloat), by t: CGSize) {
        if handleStart == nil {
            let rect = CGRect(x: frameShift.width - frameSize.width / 2, y: frameShift.height - frameSize.height / 2,
                              width: frameSize.width, height: frameSize.height)
            handleStart = (rect, scale)
            scaleStore = scale
        }
        guard let start = handleStart else { return }
        // The photo's edges and the area's edges (from the area's centre) bound the frame.
        let image = CGRect(x: offset.width - shownSize.width / 2, y: offset.height - shownSize.height / 2,
                           width: shownSize.width, height: shownSize.height)
        let bounds = image.intersection(CGRect(x: -area.width / 2 + 4, y: -area.height / 2 + 4,
                                               width: area.width - 8, height: area.height - 8))
        // Never thinner than a finger; result() keeps the long side at minimumEdge pixels or more.
        let minPoints = max(Self.minSide, CGFloat(MomentImage.minimumEdge) * start.scale / 3)
        var left = start.rect.minX, right = start.rect.maxX, top = start.rect.minY, bottom = start.rect.maxY
        if spot.x < 0 { left = min(max(left + t.width, bounds.minX), right - minPoints) }
        if spot.x > 0 { right = max(min(right + t.width, bounds.maxX), left + minPoints) }
        if spot.y < 0 { top = min(max(top + t.height, bounds.minY), bottom - minPoints) }
        if spot.y > 0 { bottom = max(min(bottom + t.height, bounds.maxY), top + minPoints) }
        freeSize = CGSize(width: right - left, height: bottom - top)
        frameShift = CGSize(width: (left + right) / 2, height: (top + bottom) / 2)
    }

    // MARK: State

    private func restore() {
        turns = ((start.quarterTurns % 4) + 4) % 4
        angle = start.angle
        aspect = start.aspect
        portrait = start.portrait ?? (turnedSize.height > turnedSize.width)
        makePreview()
        apply(start.crop)
        ready = true
    }

    private func makePreview() {
        if preview == nil { preview = MomentImage.scaled(original, maxEdge: 1600) }
        turnedPreview = preview.flatMap { MomentImage.rotated($0, quarterTurns: turns) }
    }

    /// Frames `crop` (fractions of the turned photo): the frame as large as the area allows,
    /// centred, with the photo scaled and moved to match.
    private func apply(_ crop: CGRect) {
        let w = max(crop.width * turnedSize.width, 1), h = max(crop.height * turnedSize.height, 1)
        if aspect == .free { freeSize = fit(w / h) }
        frameShift = .zero
        let frame = frameSize
        let s = max(frame.width / w, frame.height / h)
        scaleStore = s
        offset = clamped(CGSize(width: (0.5 - crop.midX) * turnedSize.width * s,
                                height: (0.5 - crop.midY) * turnedSize.height * s))
    }

    private func turn() {
        // Counter-clockwise, like the Photos app's rotate button.
        turns = (turns + 3) % 4
        portrait.toggle()
        makePreview()
        resetFraming()
    }

    private func setAspect(_ item: MomentCropAspect) {
        guard item != aspect else { return }
        if item == .free {
            // Start from what is framed now, so nothing jumps.
            freeSize = frameSize
            aspect = .free
            apply(result.crop)
        } else {
            aspect = item
            resetFraming()
        }
    }

    private func resetFraming() {
        freeSize = nil
        if aspect == .free { freeSize = fit(turnedSize.width / turnedSize.height) }
        frameShift = .zero
        scaleStore = 0
        offset = .zero
    }

    private func setZoom(_ value: CGFloat) {
        scaleStore = coverScale * min(max(value, 1), maxZoom)
        offset = clamped(offset)
    }

    /// Keeps the photo over the whole frame.
    private func clamped(_ offset: CGSize) -> CGSize {
        let maxX = max((shownSize.width - frameSize.width) / 2, 0)
        let maxY = max((shownSize.height - frameSize.height) / 2, 0)
        let rel = CGSize(width: offset.width - frameShift.width, height: offset.height - frameShift.height)
        return CGSize(width: min(max(rel.width, -maxX), maxX) + frameShift.width,
                      height: min(max(rel.height, -maxY), maxY) + frameShift.height)
    }

    /// What the frame holds, as fractions of the turned photo.
    private var result: MomentCropEdit {
        let s = scale
        var w = frameSize.width / s, h = frameSize.height / s
        // Never smaller than the upload minimum.
        let minimum = CGFloat(MomentImage.minimumEdge)
        if max(w, h) < minimum {
            let grow = minimum / max(w, h)
            w = min(w * grow, turnedSize.width)
            h = min(h * grow, turnedSize.height)
        }
        let cx = turnedSize.width / 2 - (offset.width - frameShift.width) / s
        let cy = turnedSize.height / 2 - (offset.height - frameShift.height) / s
        let x = min(max(cx - w / 2, 0), turnedSize.width - w)
        let y = min(max(cy - h / 2, 0), turnedSize.height - h)
        let crop = CGRect(x: x / turnedSize.width, y: y / turnedSize.height,
                          width: w / turnedSize.width, height: h / turnedSize.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return MomentCropEdit(quarterTurns: turns, angle: angle, crop: crop, aspect: aspect, portrait: portrait)
    }
}

/// An L at one corner of the frame, opening inward.
private struct CornerMark: Shape {
    let x: CGFloat
    let y: CGFloat

    func path(in rect: CGRect) -> Path {
        let cx = x < 0 ? rect.minX + rect.width / 2 - 2 : rect.maxX - rect.width / 2 + 2
        let cy = y < 0 ? rect.minY + rect.height / 2 - 2 : rect.maxY - rect.height / 2 + 2
        let len: CGFloat = 12
        var path = Path()
        path.move(to: CGPoint(x: cx - x * len, y: cy))
        path.addLine(to: CGPoint(x: cx, y: cy))
        path.addLine(to: CGPoint(x: cx, y: cy - y * len))
        return path
    }
}

/// Rule-of-thirds lines inside the crop frame (a finer grid while tilting, to line up horizons).
private struct ThirdsGuide: Shape {
    var divisions = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let n = max(divisions, 2)
        for i in 1..<n {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(n)
            let y = rect.minY + rect.height * CGFloat(i) / CGFloat(n)
            path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

/// A ruler for tilting the photo: drag it sideways, one tick per degree, −45° to 45°.
/// It clicks into 0° when passing it; double-tap (or tap the number) to level it again.
private struct StraightenDial: View {
    @Binding var angle: Double
    @Binding var editing: Bool
    @State private var dragStart: Double?

    private static let range: ClosedRange<Double> = -45...45
    private static let spacing: CGFloat = 7

    var body: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { angle = 0 }
            } label: {
                Text(label)
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(angle == 0 ? Color.secondary : Color.yellow)
                    .contentTransition(.numericText(value: angle))
                    .frame(minWidth: 56)
            }
            .buttonStyle(.plain)
            .disabled(angle == 0)

            GeometryReader { proxy in
                let mid = proxy.size.width / 2
                Canvas { ctx, size in
                    for deg in Int(Self.range.lowerBound)...Int(Self.range.upperBound) {
                        let x = mid + (CGFloat(deg) - CGFloat(angle)) * Self.spacing
                        guard x > -2, x < size.width + 2 else { continue }
                        let major = deg % 5 == 0
                        let h: CGFloat = deg == 0 ? 18 : (major ? 13 : 7)
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: (size.height - h) / 2))
                        line.addLine(to: CGPoint(x: x, y: (size.height + h) / 2))
                        ctx.stroke(line, with: .color(.white.opacity(major ? 0.75 : 0.35)), lineWidth: major ? 1.2 : 1)
                    }
                    // The fixed needle in the middle.
                    var needle = Path()
                    needle.move(to: CGPoint(x: mid, y: 0))
                    needle.addLine(to: CGPoint(x: mid, y: size.height))
                    ctx.stroke(needle, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                           .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = dragStart ?? angle
                            dragStart = start
                            editing = true
                            var next = start - Double(value.translation.width / Self.spacing)
                            next = min(max(next, Self.range.lowerBound), Self.range.upperBound)
                            if abs(next) < 0.4 { next = 0 }
                            angle = (next * 10).rounded() / 10
                        }
                        .onEnded { _ in
                            dragStart = nil
                            editing = false
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.snappy(duration: 0.25)) { angle = 0 }
                }
            }
            .frame(height: 30)
        }
        .sensoryFeedback(.selection, trigger: angle == 0)
        .sensoryFeedback(.selection, trigger: Int((angle / 5).rounded(.towardZero)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("기울기")
        .accessibilityValue(label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: angle = min(angle + 1, Self.range.upperBound)
            case .decrement: angle = max(angle - 1, Self.range.lowerBound)
            @unknown default: break
            }
        }
    }

    private var label: String {
        angle == 0 ? "0°" : String(format: "%+.1f°", angle)
    }
}
