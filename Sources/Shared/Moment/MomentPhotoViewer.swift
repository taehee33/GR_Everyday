import SwiftUI

/// One photo filling the screen: pinch (or double-tap) to zoom, drag to look around while zoomed,
/// tap to show or hide the close button. On iPhone the phone may turn while it is open.
struct MomentPhotoViewer: View {
    let store: MomentStore
    let photo: MomentPhoto
    @Environment(\.dismiss) private var dismiss
    @State private var chrome = true
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    #if os(iOS)
    @State private var wasFree = false
    #endif

    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let fitted = fittedSize(in: proxy.size)
            image
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(magnify(fitted: fitted, in: proxy.size).simultaneously(with: drag(fitted: fitted, in: proxy.size)))
                .onTapGesture(count: 2) { toggleZoom(fitted: fitted, in: proxy.size) }
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } }
                .onChange(of: proxy.size) { _, _ in reset(animated: false) }
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .topLeading) {
            if chrome {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(16)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("닫기")
                .transition(.opacity)
            }
        }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            wasFree = Orientation.free
            Orientation.setFree(true)
        }
        .onDisappear { if !wasFree { Orientation.setFree(false) } }
        #endif
    }

    private var image: some View {
        MomentRemoteImage(url: store.displayURL(photo), preview: store.thumbURL(photo))
            .accessibilityLabel(photo.caption ?? "사진")
    }

    private func fittedSize(in size: CGSize) -> CGSize {
        let ratio = CGFloat(photo.width) / CGFloat(max(photo.height, 1))
        guard size.width > 0, size.height > 0, ratio > 0 else { return size }
        return size.width / size.height > ratio
            ? CGSize(width: size.height * ratio, height: size.height)
            : CGSize(width: size.width, height: size.width / ratio)
    }

    private func magnify(fitted: CGSize, in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 0.8), maxScale)
            }
            .onEnded { _ in
                withAnimation(.spring(duration: 0.25)) {
                    scale = min(max(scale, 1), maxScale)
                    offset = clamped(offset, fitted: fitted, in: size)
                }
                lastScale = scale
                lastOffset = offset
                if scale == 1 { reset(animated: true) }
            }
    }

    private func drag(fitted: CGSize, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if scale > 1 {
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                } else if value.translation.height > 0 {
                    // Pull down to close, as in Photos.
                    offset = CGSize(width: 0, height: value.translation.height)
                }
            }
            .onEnded { value in
                if scale <= 1 {
                    if value.translation.height > 120 { dismiss() } else { reset(animated: true) }
                    return
                }
                withAnimation(.spring(duration: 0.25)) { offset = clamped(offset, fitted: fitted, in: size) }
                lastOffset = offset
            }
    }

    private func toggleZoom(fitted: CGSize, in size: CGSize) {
        if scale > 1 {
            reset(animated: true)
        } else {
            withAnimation(.spring(duration: 0.3)) { scale = 2.5 }
            lastScale = scale
        }
    }

    /// Keeps the zoomed photo covering the screen: no empty band beyond its edges.
    private func clamped(_ offset: CGSize, fitted: CGSize, in size: CGSize) -> CGSize {
        let maxX = max((fitted.width * scale - size.width) / 2, 0)
        let maxY = max((fitted.height * scale - size.height) / 2, 0)
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    private func reset(animated: Bool) {
        let apply = {
            scale = 1
            offset = .zero
        }
        if animated { withAnimation(.spring(duration: 0.25), apply) } else { apply() }
        lastScale = 1
        lastOffset = .zero
    }
}

extension View {
    /// Shows MomentPhotoViewer for `photo`: full screen on iPhone and iPad, a large sheet on Mac.
    func momentPhotoViewer(_ photo: Binding<MomentPhoto?>, store: MomentStore) -> some View {
        #if os(iOS)
        fullScreenCover(item: photo) { MomentPhotoViewer(store: store, photo: $0) }
        #else
        sheet(item: photo) {
            MomentPhotoViewer(store: store, photo: $0)
                .frame(minWidth: 900, idealWidth: 1200, minHeight: 650, idealHeight: 820)
        }
        #endif
    }
}
