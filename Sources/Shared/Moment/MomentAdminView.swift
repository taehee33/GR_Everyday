import SwiftUI

/// 설정 › 계정 › 어드민 (only for the people in `admins`): people's monthly shares and wall
/// limits, the defaults, 당선작, and the admin list. See MomentAdmin and PLAN-admin.md.
struct MomentAdminView: View {
    @ObservedObject var admin = MomentAdmin.shared
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { AdminUsersPage() } label: {
                        Label("사용자", systemImage: "person.2")
                    }
                    NavigationLink { AdminDefaultsPage() } label: {
                        Label("기본값", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("사람마다 한 달 공유 한도와 벽 최대 장수를 기본값으로 두거나 따로 정할 수 있어요.")
                }
                Section {
                    NavigationLink { AdminContestsPage() } label: {
                        Label("당선작", systemImage: "trophy")
                    }
                } footer: {
                    Text("테스트용으로 달이 끝나기 전에도 당선작을 넣고 뺄 수 있어요. 바로 순간들에 보여요.")
                }
                Section {
                    NavigationLink { AdminMembersPage() } label: {
                        Label("어드민 명단", systemImage: "person.badge.key")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("어드민")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기", action: onClose) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 600)
        #endif
    }
}

// MARK: - Pieces

/// A number with a stepper and a field to type it, for limits that can be large.
private struct NumberRow: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...10_000

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .labelsHidden()
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Stepper(title, value: $value, in: range).labelsHidden()
        }
        .onChange(of: value) { if !range.contains(value) { value = min(max(value, range.lowerBound), range.upperBound) } }
    }
}

/// Runs an admin call, showing its error.
@MainActor
private final class AdminTask: ObservableObject {
    @Published var busy = false
    @Published var error: String?

    @discardableResult
    func run(_ body: @escaping () async throws -> Void) async -> Bool {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await body()
            return true
        } catch {
            if !(error.isCancellation || Task.isCancelled) { self.error = error.localizedDescription }
            return false
        }
    }
}

private struct ErrorRow: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message).font(.footnote).foregroundStyle(.red)
        }
    }
}

// MARK: - 사용자

private struct AdminUsersPage: View {
    @StateObject private var task = AdminTask()
    @State private var search = ""
    @State private var users: [MomentAdmin.User]?

    var body: some View {
        Form {
            Section {
                ErrorRow(message: task.error)
                if let users {
                    if users.isEmpty {
                        Text("찾는 사람이 없어요.").foregroundStyle(.secondary)
                    }
                    ForEach(users) { user in
                        NavigationLink {
                            AdminUserPage(user: user) { updated in
                                if let i = self.users?.firstIndex(where: { $0.id == updated.id }) {
                                    self.users?[i] = updated
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(user.name)
                                    if user.isAdmin {
                                        Text("어드민").font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text("\(user.handle ?? "사용자명 없음") · 공유 \(user.sharesUsed)/\(user.sharesLimit) · 벽 \(user.wallUsed)/\(user.wallLimit)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } footer: {
                Text("공유 횟수는 이번 달(UTC 기준) 순간들에 공유한 횟수예요. 최근 가입한 100명까지 보여요.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("사용자")
        .searchable(text: $search, prompt: "사용자명이나 표시 이름")
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await task.run { users = try await MomentAdmin.shared.users(search: search) }
        }
        .refreshable { await task.run { users = try await MomentAdmin.shared.users(search: search) } }
    }
}

private struct AdminUserPage: View {
    @State var user: MomentAdmin.User
    let onSaved: (MomentAdmin.User) -> Void

    @StateObject private var shareTask = AdminTask()
    @StateObject private var wallTask = AdminTask()
    @State private var defaults: MomentAdmin.Defaults?
    @State private var ownShares = false
    @State private var sharesLimit = 3
    @State private var ownWall = false
    @State private var wallLimit = 15

    var body: some View {
        Form {
            Section {
                LabeledContent("표시 이름", value: user.displayName ?? "없음")
                LabeledContent("사용자명", value: user.handle ?? "없음")
                LabeledContent("가입", value: user.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                if ownShares {
                    NumberRow(title: "한 달 공유 한도", value: $sharesLimit)
                } else {
                    LabeledContent("한 달 공유 한도", value: defaultText(defaults?.sharesPerMonth, unit: "회"))
                }
                Toggle("이 사람만 따로 정하기", isOn: $ownShares)
                LabeledContent("이번 달 공유한 횟수", value: "\(user.sharesUsed)회")
                Button("저장") { Task { await saveShares() } }
                    .disabled(shareTask.busy || !sharesChanged)
                ErrorRow(message: shareTask.error)
            } header: {
                Text("순간들 공유")
            } footer: {
                Text("따로 정하지 않으면 기본값을 따라요. 이번 달(UTC 기준) 남은 횟수: \(max(user.sharesLimit - user.sharesUsed, 0))회")
            }

            Section {
                if ownWall {
                    NumberRow(title: "벽 최대 장수", value: $wallLimit)
                } else {
                    LabeledContent("벽 최대 장수", value: defaultText(defaults?.wallPhotosFree, unit: "장"))
                }
                Toggle("이 사람만 따로 정하기", isOn: $ownWall)
                LabeledContent("벽에 있는 사진", value: "\(user.wallUsed)장")
                Button("저장") { Task { await saveWall() } }
                    .disabled(wallTask.busy || !wallChanged)
                ErrorRow(message: wallTask.error)
            } header: {
                Text("벽")
            } footer: {
                Text(ownWall && wallLimit < user.wallUsed
                     ? "지금 있는 사진보다 적게 정하면 사진은 그대로 남고, 새로 올리지만 못해요."
                     : "따로 정하지 않으면 기본값을 따라요.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(user.name)
        .onAppear(perform: fill)
        .task { defaults = try? await MomentAdmin.shared.defaults() }
        .onChange(of: ownShares) { if ownShares && user.sharesOverride == nil { sharesLimit = user.sharesLimit } }
        .onChange(of: ownWall) { if ownWall && !user.wallOwn { wallLimit = user.wallLimit } }
    }

    private func defaultText(_ value: Int?, unit: String) -> String {
        value.map { "기본값 · \($0)\(unit)" } ?? "기본값"
    }

    private func fill() {
        ownShares = user.sharesOverride != nil
        sharesLimit = user.sharesOverride ?? user.sharesLimit
        ownWall = user.wallOwn
        wallLimit = user.wallLimit
    }

    private var sharesChanged: Bool { (ownShares ? sharesLimit : nil) != user.sharesOverride }
    private var wallChanged: Bool { ownWall != user.wallOwn || (ownWall && wallLimit != user.wallLimit) }

    private func saveShares() async {
        let id = user.id, limit = ownShares ? sharesLimit : nil
        if await shareTask.run({ try await MomentAdmin.shared.setShareLimit(id, limit) }) { await readBack() }
    }

    private func saveWall() async {
        let id = user.id, limit = ownWall ? wallLimit : nil
        if await wallTask.run({ try await MomentAdmin.shared.setWallLimit(id, limit) }) { await readBack() }
    }

    /// The default numbers and counts come from the server.
    private func readBack() async {
        let id = user.id
        if let fresh = try? await MomentAdmin.shared.users(search: user.handle ?? user.displayName ?? "")
            .first(where: { $0.id == id }) {
            user = fresh
            fill()
            onSaved(fresh)
        }
    }
}

// MARK: - 기본값

private struct AdminDefaultsPage: View {
    @StateObject private var task = AdminTask()
    @State private var loaded: MomentAdmin.Defaults?
    @State private var value = MomentAdmin.Defaults(sharesPerMonth: 3, wallPhotosFree: 15)

    var body: some View {
        Form {
            if loaded != nil {
                Section {
                    NumberRow(title: "한 달 공유 한도", value: $value.sharesPerMonth)
                } footer: {
                    Text("따로 한도를 정하지 않은 모든 사람에게 바로 적용돼요.")
                }
                Section {
                    NumberRow(title: "벽 최대 장수", value: $value.wallPhotosFree)
                } footer: {
                    Text("따로 정하지 않은 모든 사람에게 바로 적용돼요.")
                }
                Section {
                    Button("저장") {
                        Task {
                            let v = value
                            if await task.run({ try await MomentAdmin.shared.setDefaults(v) }) { loaded = v }
                        }
                    }
                    .disabled(task.busy || loaded == value)
                    ErrorRow(message: task.error)
                }
            } else {
                Section {
                    ErrorRow(message: task.error)
                    if task.error == nil { HStack { Spacer(); ProgressView(); Spacer() } }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("기본값")
        .task {
            await task.run {
                let v = try await MomentAdmin.shared.defaults()
                loaded = v
                value = v
            }
        }
    }
}

// MARK: - 당선작

private struct AdminContestsPage: View {
    @StateObject private var task = AdminTask()
    @State private var contests: [MomentAdmin.Contest]?
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                ErrorRow(message: task.error)
                if let contests {
                    if contests.isEmpty {
                        Text("아직 등록한 달이 없어요.").foregroundStyle(.secondary)
                    }
                    ForEach(contests) { contest in
                        NavigationLink {
                            AdminContestPage(contest: contest, onChange: reload)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contest.monthTitle)
                                    Text(contest.title).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(contest.winner != nil ? "당선작 있음" : "당선작 없음")
                                    .font(.caption)
                                    .foregroundStyle(contest.winner != nil ? AnyShapeStyle(MomentLikePlace.moment.tint) : AnyShapeStyle(.secondary))
                            }
                        }
                    }
                } else if task.error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } footer: {
                Text("달마다 한 줄이에요. 줄이 있어야 순간들 위에 그 달의 사진관이 보여요.")
            }
            AdminHeartColorSection()
        }
        .formStyle(.grouped)
        .navigationTitle("당선작")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("달 추가", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                AdminContestEditor(existing: Set(contests?.map(\.month) ?? [])) {
                    adding = false
                    Task { await reload() }
                } onCancel: { adding = false }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 420)
            #endif
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        await task.run { contests = try await MomentAdmin.shared.contests() }
    }
}

/// 순간들 heart color, to match the month's winner: a few presets, or any color.
private struct AdminHeartColorSection: View {
    @StateObject private var task = AdminTask()
    @State private var picked = MomentHeartColor.shared.color

    private static let presets: [(String, String)] = [
        ("#FFFFFF", "하양 (기본)"), ("#FFC200", "노랑"), ("#FF8A00", "주황"), ("#FF4D6D", "분홍"), ("#E53935", "빨강"),
        ("#7C4DFF", "보라"), ("#2F80ED", "파랑"), ("#00B894", "초록"),
    ]

    private var saved: String { MomentHeartColor.shared.hex }
    private var pickedHex: String { picked.hexString }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "heart.fill").font(.title2)
                    .foregroundStyle(MomentHeartColor.luminance(pickedHex) > 0.9
                                     ? Color.adaptive(light: .black, dark: picked) : picked)
                Text(pickedHex).font(.body.monospaced()).foregroundStyle(.secondary)
                Spacer()
                ColorPicker("색 고르기", selection: $picked, supportsOpacity: false).labelsHidden()
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Self.presets, id: \.0) { hex, name in
                        let color = Color(hex: hex)!
                        Button { picked = color } label: {
                            Circle().fill(color).frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                                .overlay(Circle().strokeBorder(.primary, lineWidth: pickedHex == hex ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 3)
            }
            .scrollIndicators(.hidden)
            Button("저장") {
                Task {
                    let hex = pickedHex
                    await task.run { try await MomentAdmin.shared.setHeartColor(hex) }
                }
            }
            .disabled(task.busy || pickedHex == saved)
            ErrorRow(message: task.error)
        } header: {
            Text("순간들 하트 색")
        } footer: {
            Text("당선작에 맞춰 바꿔 보세요. 하양처럼 아주 밝은 색은 라이트 모드에서 검정으로 보여요. 이 기기는 바로 바뀌고, 다른 사람은 앱을 열거나 다시 앱으로 돌아올 때 바뀌어요.")
        }
        .task { await MomentHeartColor.shared.refresh(); picked = MomentHeartColor.shared.color }
    }
}

/// A new month: which month, its title, theme and intro.
private struct AdminContestEditor: View {
    let existing: Set<String>
    let onSaved: () -> Void
    let onCancel: () -> Void

    @StateObject private var task = AdminTask()
    @State private var month = MomentContest.monthKey(Date())
    @State private var title = ""
    @State private var theme = ""
    @State private var intro = ""

    /// From a year ago to three months ahead, newest first.
    private var months: [String] {
        let cal = MomentContest.korea
        return (-3...12).compactMap { cal.date(byAdding: .month, value: -$0, to: Date()) }
            .map(MomentContest.monthKey)
    }

    var body: some View {
        Form {
            Picker("달", selection: $month) {
                ForEach(months, id: \.self) { key in
                    Text(MomentContest(month: key, title: "").longMonthTitle + (existing.contains(key) ? " (있음)" : ""))
                        .tag(key)
                }
            }
            TextField("제목 (예: 11월 사진관)", text: $title)
            TextField("주제 한 줄", text: $theme)
            TextField("소개 글", text: $intro, axis: .vertical).lineLimit(3...6)
            if existing.contains(month) {
                Text("이 달은 이미 있어요. 저장하면 제목과 글을 바꿔요.").font(.footnote).foregroundStyle(.secondary)
            }
            ErrorRow(message: task.error)
        }
        .formStyle(.grouped)
        .navigationTitle("달 추가")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("취소", action: onCancel) }
            ToolbarItem(placement: .confirmationAction) {
                Button("저장") {
                    Task {
                        let m = month, t = title.trimmingCharacters(in: .whitespaces), th = theme, i = intro
                        if await task.run({ try await MomentAdmin.shared.saveContest(month: m, title: t, theme: th, intro: i) }) {
                            onSaved()
                        }
                    }
                }
                .disabled(task.busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { if title.isEmpty { title = "\(MomentContest(month: month, title: "").monthTitle) 사진관" } }
    }
}

/// One month: edit its text, put a winner in or take it out, delete the month.
private struct AdminContestPage: View {
    @State var contest: MomentAdmin.Contest
    let onChange: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var task = AdminTask()
    @State private var title = ""
    @State private var theme = ""
    @State private var intro = ""
    @State private var ranking: [MomentAdmin.Candidate]?
    @State private var confirmDelete = false

    private var store: MomentStore { MomentAccount.shared.store }

    var body: some View {
        Form {
            Section("글") {
                TextField("제목", text: $title)
                TextField("주제 한 줄", text: $theme)
                TextField("소개 글", text: $intro, axis: .vertical).lineLimit(3...6)
                Button("글 저장") {
                    Task {
                        let m = contest.month, t = title, th = theme, i = intro
                        if await task.run({ try await MomentAdmin.shared.saveContest(month: m, title: t, theme: th, intro: i) }) {
                            contest.title = t
                            await onChange()
                        }
                    }
                }
                .disabled(task.busy || title.trimmingCharacters(in: .whitespaces).isEmpty
                          || (title == contest.title && theme == (contest.theme ?? "") && intro == (contest.intro ?? "")))
            }

            Section {
                if let winner = contest.winner {
                    HStack(spacing: 12) {
                        thumb(store.thumbURL(winner))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ranking?.first(where: { $0.photoID == winner })?.author ?? "당선작")
                            if let at = contest.announcedAt {
                                Text("\(at.formatted(date: .abbreviated, time: .shortened)) 발표")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("빼기", role: .destructive) { Task { await setWinner(nil) } }
                            .disabled(task.busy)
                    }
                } else {
                    Text("아직 당선작이 없어요. 아래 후보에서 골라 넣어 보세요.").foregroundStyle(.secondary)
                }
                ErrorRow(message: task.error)
            } header: {
                Text("당선작")
            } footer: {
                Text("넣으면 바로 발표된 것으로 보이고, 빼면 발표 전으로 돌아가요. 앱 아이콘은 앱 업데이트 때 따로 넣어야 해요.")
            }

            Section {
                if let ranking {
                    if ranking.isEmpty {
                        Text("이 달에 순간들에 공유된 사진이 없어요.").foregroundStyle(.secondary)
                    }
                    ForEach(ranking) { candidate in
                        HStack(spacing: 12) {
                            Text("\(candidate.rank)").font(.callout.monospacedDigit()).frame(width: 24)
                            thumb(candidate.thumbURL.flatMap(URL.init(string:)) ?? store.thumbURL(candidate.photoID))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.author ?? "이름 없음").lineLimit(1)
                                Text("좋아요 \(candidate.likes)" + (candidate.likesNow != candidate.likes ? " (지금 \(candidate.likesNow))" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let caption = candidate.caption, !caption.isEmpty {
                                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if contest.winner == candidate.photoID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(MomentLikePlace.moment.tint)
                            } else {
                                Button("넣기") { Task { await setWinner(candidate.photoID) } }
                                    .disabled(task.busy)
                            }
                        }
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } header: {
                Text("후보 (좋아요 순)")
            } footer: {
                Text("그 달(한국 시간)에 순간들에 공유된 사진이에요. 좋아요는 말일까지 받은 것만 세요.")
            }

            Section {
                Button("이 달 지우기", role: .destructive) { confirmDelete = true }
                    .disabled(task.busy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(contest.monthTitle)
        .onAppear {
            title = contest.title
            theme = contest.theme ?? ""
            intro = contest.intro ?? ""
        }
        .task { await loadRanking() }
        .refreshable { await loadRanking() }
        .alert("\(contest.monthTitle)을 지울까요?", isPresented: $confirmDelete) {
            Button("취소", role: .cancel) {}
            Button("지우기", role: .destructive) {
                Task {
                    let m = contest.month
                    if await task.run({ try await MomentAdmin.shared.deleteContest(month: m) }) {
                        await onChange()
                        dismiss()
                    }
                }
            }
        } message: {
            Text("순간들에서 이 달의 사진관과 당선작이 사라져요. 사진은 지워지지 않아요.")
        }
    }

    private func loadRanking() async {
        let m = contest.month
        await task.run { ranking = try await MomentAdmin.shared.ranking(month: m) }
    }

    private func setWinner(_ photo: UUID?) async {
        let m = contest.month
        if await task.run({ try await MomentAdmin.shared.setWinner(month: m, photo: photo) }) {
            contest.winner = photo
            contest.announcedAt = photo == nil ? nil : (contest.announcedAt ?? Date())
            await onChange()
            // 순간들 shows the winner straight away.
            await MomentAccount.shared.contests.reload()
        }
    }

    private func thumb(_ url: URL) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.secondary.opacity(0.15)
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 10.8, style: .continuous))
    }
}

// MARK: - 어드민 명단

private struct AdminMembersPage: View {
    @StateObject private var task = AdminTask()
    @State private var members: [MomentAdmin.Member]?
    @State private var handle = ""
    @State private var removing: MomentAdmin.Member?

    private var myID: UUID? { MomentAccount.shared.me?.id }

    var body: some View {
        Form {
            Section {
                if let members {
                    ForEach(members) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName ?? member.handle ?? "이름 없음")
                                Text(member.handle ?? "사용자명 없음").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if member.id == myID {
                                Text("나").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("빼기", role: .destructive) { removing = member }
                                .disabled(task.busy || members.count <= 1)
                        }
                    }
                } else if task.error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } header: {
                Text("어드민")
            }
            Section {
                HStack {
                    TextField("사용자명", text: $handle)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { Task { await add() } }
                    Button("추가") { Task { await add() } }
                        .disabled(task.busy || handle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ErrorRow(message: task.error)
            } header: {
                Text("어드민 추가")
            } footer: {
                Text("추가한 사람은 설정 › 계정에서 어드민 페이지를 볼 수 있어요. 마지막 한 명은 뺄 수 없어요.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("어드민 명단")
        .task { await reload() }
        .alert("어드민에서 뺄까요?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("취소", role: .cancel) {}
            Button("빼기", role: .destructive) {
                guard let member = removing else { return }
                Task {
                    if await task.run({ try await MomentAdmin.shared.removeMember(member.id) }) {
                        await reload()
                        if member.id == myID { await MomentAdmin.shared.refresh(account: .shared) }
                    }
                }
            }
        } message: {
            Text(removing?.id == myID ? "나를 빼면 이 페이지를 더 볼 수 없어요." : "\(removing?.handle ?? "이 사람")은 어드민 페이지를 더 볼 수 없어요.")
        }
    }

    private func reload() async {
        await task.run { members = try await MomentAdmin.shared.members() }
    }

    private func add() async {
        let h = handle
        if await task.run({ try await MomentAdmin.shared.addMember(handle: h) }) {
            handle = ""
            await reload()
        }
    }
}
