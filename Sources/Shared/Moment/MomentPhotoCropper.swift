import SwiftUI

/// Framing a photo before it is uploaded: turn it a quarter at a time, pick a shape (or 자유 to
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
        let longAtCover = max(frameSize.width, frameSize.height) / coverScale
        return max(1, min(5, longAtCover / CGFloat(MomentImage.minimumEdge)))
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
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .frame(width: shownSize.width, height: shownSize.height)
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
                        ThirdsGuide()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
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

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(MomentCropAspect.allCases) { item in
                    Button { setAspect(item) } label: {
                        Text(item.title)
                            .font(.footnote.weight(aspect == item ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(aspect == item ? Color.white.opacity(0.22) : Color.white.opacity(0.06),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(aspect == item ? .isSelected : [])
                }
            }
            HStack(spacing: 22) {
                Button { turn() } label: {
                    Label("회전", systemImage: "rotate.right")
                }
                .accessibilityLabel("오른쪽으로 90도 회전")
                Button {
                    portrait.toggle()
                    resetFraming()
                } label: {
                    Label(portrait ? "세로" : "가로",
                          systemImage: portrait ? "rectangle.portrait" : "rectangle")
                }
                .disabled(aspect.ratio == nil || aspect == .square)
                .accessibilityLabel("가로 세로 바꾸기")
                Button {
                    turns = 0
                    aspect = .original
                    portrait = false
                    makePreview()
                    resetFraming()
                } label: {
                    Label("처음대로", systemImage: "arrow.uturn.backward")
                }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
            HStack(spacing: 12) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { zoom }, set: setZoom), in: 1...max(maxZoom, 1.0001))
                    .disabled(maxZoom <= 1.01)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .frame(maxWidth: 360)
            Text(aspect == .free
                 ? "모서리나 변을 끌어 원하는 모양으로 자르고, 사진을 끌어 위치를 맞춰 주세요."
                 : "끌어서 위치를, 두 손가락이나 막대로 크기를 맞춰 주세요. 색과 보정은 카메라 원본 그대로예요.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
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
        turns = (turns + 1) % 4
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
        return MomentCropEdit(quarterTurns: turns, crop: crop, aspect: aspect, portrait: portrait)
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

/// Rule-of-thirds lines inside the crop frame.
private struct ThirdsGuide: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            let y = rect.minY + rect.height * CGFloat(i) / 3
            path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
