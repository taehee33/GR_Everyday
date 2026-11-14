import SwiftUI

extension View {
    /// Opens a page over the whole screen on iPhone/iPad, coming in from the right like a pushed
    /// page, with a back button (`\.momentBack`) and swipe right to go back. On the Mac a sheet.
    func momentPush<Item: Identifiable & Equatable, Page: View>(
        item: Binding<Item?>, @ViewBuilder page: @escaping (Item) -> Page
    ) -> some View {
        modifier(MomentPushPresenter(item: item, page: page))
    }
}

extension EnvironmentValues {
    /// Slides the pushed page away (set by `momentPush`); nil when the page is not pushed.
    @Entry var momentBack: (() -> Void)?
}

private struct MomentPushPresenter<Item: Identifiable & Equatable, Page: View>: ViewModifier {
    @Binding var item: Item?
    let page: (Item) -> Page
    #if os(iOS)
    /// `item`, shown without the cover's slide-up, so the page can slide in from the side.
    @State private var shown: Item?
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onChange(of: item) { _, new in
                guard new != shown else { return }
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) { shown = new }
            }
            .onChange(of: shown) { _, new in
                if new == nil { item = nil }
            }
            .fullScreenCover(item: $shown) { value in
                MomentPushedPage { page(value) }
                    .presentationBackground(.clear)
            }
        #else
        content.sheet(item: $item) { value in page(value) }
        #endif
    }
}

#if os(iOS)
/// Slides in from the right, follows a rightward swipe, and slides back out to close.
private struct MomentPushedPage<Page: View>: View {
    @ViewBuilder let page: () -> Page
    @Environment(\.dismiss) private var dismiss
    @State private var slide: CGFloat = 0
    @State private var pageWidth: CGFloat = 0
    /// Whether the current drag is a swipe back (decided on its first move).
    @State private var swiping: Bool?

    var body: some View {
        page()
            .environment(\.momentBack, close)
            .background(Color(uiColor: .systemBackground))
            .shadow(color: .black.opacity(slide > 0 ? 0.25 : 0), radius: 12)
            .offset(x: slide)
            .simultaneousGesture(swipeBack)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            .onAppear {
                slide = pageWidth > 0 ? pageWidth : 1000
                withAnimation(.easeOut(duration: 0.28)) { slide = 0 }
            }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.22)) {
            slide = max(pageWidth, 1000)
        } completion: {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { dismiss() }
        }
    }

    private var swipeBack: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { value in
                if swiping == nil {
                    swiping = value.translation.width > 0
                        && abs(value.translation.width) > abs(value.translation.height) * 1.5
                }
                if swiping == true { slide = max(0, value.translation.width) }
            }
            .onEnded { value in
                defer { swiping = nil }
                guard swiping == true else { return }
                if value.translation.width > pageWidth * 0.33 || value.predictedEndTranslation.width > pageWidth * 0.6 {
                    close()
                } else {
                    withAnimation(.spring(duration: 0.25)) { slide = 0 }
                }
            }
    }
}
#endif

/// The leading toolbar button of a detail page: ‹ back when pushed, 닫기 in a sheet.
struct MomentCloseButton: View {
    @Environment(\.momentBack) private var back
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let back {
            Button(action: back) { Image(systemName: "chevron.left") }
                .accessibilityLabel("뒤로")
        } else {
            Button("닫기") { dismiss() }
        }
    }
}
