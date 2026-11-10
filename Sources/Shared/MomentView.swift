import SwiftUI

/// 순간들 (English: Moments): photos people took with their GR, shared for everyone to browse, and
/// each person's own Photowall arranged as they like. Not built yet; the tab holds its place.
struct MomentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: Pane.moment.icon)
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                Text(Pane.moment.rawValue).font(.title.bold())
                Text("Moments").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("GR로 찍은 순간을 함께 보는 공간이에요.\n내가 올린 사진은 Photowall에 원하는 대로 걸어 둘 수 있어요.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("준비하고 있어요")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(Pane.moment.rawValue)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
