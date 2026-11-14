import SwiftUI

/// 이달의 사진관 on top of 순간들: this month's theme, and the latest winner (which becomes an
/// app icon). Nothing shows until the operator has added a month (PLAN-contest.md).
struct MomentContestNotice: View {
    @ObservedObject var account: MomentAccount
    @ObservedObject var contests: MomentFeed
    @State private var opened: MomentPhoto?

    init(account: MomentAccount) {
        self.account = account
        self.contests = account.contests
    }

    private var current: MomentContest? { contests.contests.first { $0.isCurrent() } }
    private var latestWinner: MomentContest? { contests.contests.first { $0.isAnnounced && $0.winner != nil } }

    var body: some View {
        if current != nil || latestWinner != nil {
            VStack(alignment: .leading, spacing: 18) {
                if let current { intro(current) }
                if let latestWinner, let photo = latestWinner.winner { winnerCard(latestWinner, photo) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheet(item: $opened) { photo in
                MomentFeedDetail(account: account, feed: contests, photoID: photo.id)
            }
        }
    }

    private func intro(_ contest: MomentContest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let theme = contest.theme {
                Text(theme).font(.system(.caption, design: .serif)).tracking(3).foregroundStyle(.secondary)
            }
            Text(contest.title).font(.system(size: 26, weight: .semibold, design: .serif))
            (Text("이달의 당선작은 ") + Text("앱 아이콘").foregroundColor(MomentLikePlace.moment.tint) + Text("이 됩니다."))
                .font(.callout)
            Text(contest.intro ?? "\(contest.monthTitle) 한 달 동안 순간들에 공유한 사진이 모두 후보예요. 달이 끝나면 좋아요를 가장 많이 받은 사진을 확인해 당선작으로 골라요.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func winnerCard(_ contest: MomentContest, _ photo: MomentPhoto) -> some View {
        Button { opened = photo } label: {
            HStack(spacing: 14) {
                MomentContestIcon(store: account.store, photo: photo, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(contest.monthTitle) 당선작").font(.caption.weight(.semibold)).tracking(2)
                        .foregroundStyle(MomentLikePlace.moment.tint)
                    if let caption = photo.caption, !caption.isEmpty {
                        Text(caption).font(.subheadline.weight(.semibold)).lineLimit(2)
                    }
                    Text("\(photo.author?.title ?? "이름 없음") 님의 순간 · 자세히 보기")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(contest.monthTitle) 당선작, \(photo.author?.title ?? "") 님의 순간")
    }
}

/// 탐색's 이전 당선작: every announced month, newest first, as app-icon squares in a row.
struct MomentPastWinners: View {
    @ObservedObject var account: MomentAccount
    @ObservedObject var contests: MomentFeed
    @State private var opened: MomentPhoto?

    init(account: MomentAccount) {
        self.account = account
        self.contests = account.contests
    }

    private var winners: [(MomentContest, MomentPhoto)] {
        contests.contests.compactMap { c in c.isAnnounced ? c.winner.map { (c, $0) } : nil }
    }

    var body: some View {
        if !winners.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("이전 당선작").font(.subheadline.weight(.semibold))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(winners, id: \.0.id) { contest, photo in
                            Button { opened = photo } label: {
                                VStack(spacing: 6) {
                                    MomentContestIcon(store: account.store, photo: photo, size: 76)
                                    Text(contest.longMonthTitle).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(contest.longMonthTitle) 당선작, \(photo.author?.title ?? "") 님의 순간")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .sheet(item: $opened) { photo in
                MomentFeedDetail(account: account, feed: contests, photoID: photo.id)
            }
        }
    }
}

/// A winning photo as an app-icon square with rounded corners.
struct MomentContestIcon: View {
    let store: MomentStore
    let photo: MomentPhoto
    let size: CGFloat

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay { MomentRemoteImage(url: store.thumbURL(photo), contentMode: .fill) }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}
