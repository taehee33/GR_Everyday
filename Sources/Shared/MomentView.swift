import SwiftUI

/// 순간들 (English: Moments): photos people took with their GR, shared for everyone to browse, and
/// each person's own Photowall arranged as they like. The tab has two parts: the feed of shared
/// photos, and my account (sign-in, names, uploading, my photos). The wall layout comes next.
struct MomentView: View {
    @StateObject private var account = MomentAccount()
    @State private var section: Part = .feed

    enum Part: String, CaseIterable, Identifiable {
        case feed = "피드"
        case mine = "내 순간들"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("보기", selection: $section) {
                    ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                switch section {
                case .feed:
                    MomentFeedView(account: account, feed: account.feed)
                case .mine:
                    mine
                }
            }
            .padding(section == .feed ? 16 : 32)
            .frame(maxWidth: section == .feed ? 1100 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .refreshable { if section == .feed { await account.feed.reload() } }
        .task { if account.state == .loading { await account.load() } }
        .navigationTitle(Pane.moment.rawValue)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var mine: some View {
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
            Divider().frame(maxWidth: 320).padding(.vertical, 4)
            MomentAccountView(account: account)
        }
    }
}
