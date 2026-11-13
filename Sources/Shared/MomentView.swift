import SwiftUI

/// 순간들 (English: Moments): photos people took with their GR. Two rooms under one roof:
/// 순간들, what everyone shared, and 내 갤러리, my own wall (upload, share, arrange). The
/// account itself (names, log out, liked photos, reports) is in 설정 › 계정.
struct MomentView: View {
    @ObservedObject private var account = MomentAccount.shared
    @State private var room: Room = .moments
    @Namespace private var underline

    enum Room: String, CaseIterable, Identifiable {
        case moments = "순간들"
        case mine = "내 갤러리"
        var id: String { rawValue }

        var english: String { self == .moments ? "Moments" : "My Gallery" }
        var line: String {
            self == .moments ? "누군가의 GR에 담긴, 오늘의 순간" : "흘러가는 일상 속, 특별한 순간"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                switch room {
                case .moments:
                    MomentPhotoList(account: account, feed: account.feed)
                        .task { if !account.feed.loaded { await account.feed.reload() } }
                        .task(id: account.me?.id) { if account.feed.loaded { await account.feed.reload() } }
                case .mine:
                    MomentAccountView(account: account)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            if room == .moments { await account.feed.reload() } else { await account.reloadPhotos() }
        }
        .task { if account.state == .loading { await account.load() } }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle(Pane.moment.rawValue)
        #endif
    }

    /// The two rooms as the page's title: the one you are in is bright, the other waits dimmed.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(room.english.uppercased())
                .font(.system(.caption, design: .serif).weight(.medium))
                .tracking(4)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                ForEach(Room.allCases) { item in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { room = item }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 30, weight: room == item ? .bold : .regular))
                            .foregroundStyle(room == item ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .padding(.bottom, 8)
                            .overlay(alignment: .bottom) {
                                // One line as wide as the title, sliding between the two.
                                if room == item {
                                    Capsule().fill(Color.primary)
                                        .frame(height: 2)
                                        .matchedGeometryEffect(id: "underline", in: underline)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(room == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
                #if os(macOS)
                if room == .moments {
                    Button { Task { await account.feed.reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(account.feed.loading)
                        .help("새로고침")
                }
                #endif
            }
            Text(room.line).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
