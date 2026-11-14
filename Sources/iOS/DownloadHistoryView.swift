import SwiftUI
import Photos

/// 라이브러리 → 다운로드 기록: every save by time, what each photo became (in the Photos app,
/// deleted there since, in the Files app, skipped, failed), and a way to save it again.
struct DownloadHistoryView: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var connection: ConnectionModel
    @ObservedObject private var history = SaveHistory.shared
    /// 선택 lives in the navigation bar (LibraryTab), where 사진 has its own.
    @Binding var selecting: Bool
    /// Row keys: "r:<record id>" for a record, "o:<photo id>" for an older save. The
    /// navigation bar shows how many.
    @Binding var selected: Set<String>
    /// Back to 사진, where the save's progress shows.
    var showPhotos: () -> Void = {}
    @State private var filter: Filter = .all
    @State private var confirmClear = false
    @State private var confirmRemove = false
    @State private var showWhyNot = false

    enum Filter: String, CaseIterable {
        case all = "전체", gone = "지워짐", failed = "실패"
        var icon: String {
            switch self {
            case .all: return "line.3.horizontal.decrease"
            case .gone: return "trash"
            case .failed: return "exclamationmark.triangle"
            }
        }
        var tint: Color {
            switch self {
            case .all: return .accentColor
            case .gone: return .orange
            case .failed: return .red
            }
        }
    }

    private struct Session: Identifiable {
        let id: UUID
        let date: Date
        let records: [SaveHistory.Record]
    }

    var body: some View {
        let shown = filtered
        // Saved before the app kept records; found missing in Photos by name and time.
        let older = filter == .failed ? [] : olderPhotos
        List {
            if PhotosLibrary.target.toPhotos && history.readStatus != .authorized { accessSection }
            if shown.isEmpty && older.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "clock.arrow.circlepath",
                                       description: Text(emptyDetail))
                    .listRowBackground(Color.clear)
            } else {
                if filter != .all, !selecting { bulkSection(shown.flatMap(\.records), older: older) }
                if !older.isEmpty {
                    Section("예전에 저장한 사진") {
                        ForEach(older) { photo in
                            HStack(spacing: 12) {
                                if selecting { checkmark(selected.contains("o:" + photo.id)) }
                                Thumb(photo: photo, showsTransfer: false)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .allowsHitTesting(false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(photo.name).font(.subheadline.weight(.medium))
                                    Text("사진 앱에서 지워짐 · 파일 앱에 사본 있음").font(.caption).foregroundStyle(.orange)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "checkmark.circle.badge.xmark").foregroundStyle(.orange)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { tap("o:" + photo.id) }
                            .contextMenu {
                                if !selecting {
                                    if canSave(photo) {
                                        Button { library.save([photo], force: true); showPhotos() } label: {
                                            Label("사진 앱에 다시 저장", systemImage: "arrow.clockwise")
                                        }
                                        .disabled(library.isTransferring)
                                    }
                                    Button(role: .destructive) { history.hide([photo.name]) } label: {
                                        Label("목록에서 삭제", systemImage: "trash")
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if !selecting {
                                    Button("목록에서 삭제", role: .destructive) { history.hide([photo.name]) }
                                }
                            }
                        }
                    }
                }
                ForEach(sessions(shown.flatMap(\.records))) { session in
                    Section {
                        ForEach(session.records) { row($0) }
                    } header: {
                        header(session)
                    }
                }
                if !selecting {
                Section {
                    Button("기록 모두 지우기", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("기록만 지워져요. 사진 앱과 파일 앱의 사진은 그대로 남아요.")
                }
                }
            }
        }
        .listStyle(.insetGrouped)
        // The list's own top gap; the chips above already give the room.
        .contentMargins(.top, 8, for: .scrollContent)
        // Pinned right under the page picker, in the same bar, so they stay while scrolling.
        .safeAreaInset(edge: .top, spacing: 0) { chips }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar(shown.flatMap(\.records), older: older) }
        }
        .onAppear { history.refreshPresence() }
        .onChange(of: filter) { selected = [] }
        .onChange(of: selecting) { if !selecting { selected = [] } }
        .alert("다운로드 기록을 모두 지울까요?", isPresented: $confirmClear) {
            Button("취소", role: .cancel) {}
            Button("기록 지우기", role: .destructive) {
                history.hide(Set(olderPhotos.map(\.name)))
                history.clear()
            }
        } message: {
            Text("사진은 지워지지 않아요.\n\n다만 앱이 어떤 사진을 저장했는지 잊어버려서, 사진 앱에만 남은 사진은 다시 저장할 사진으로 보일 수 있어요.")
        }
    }

    // MARK: Chips

    /// Chips, not a segmented control: right under the page picker that looked like a
    /// second set of pages.
    /// A plain row, not a horizontal ScrollView: inside the top inset the scroll view laid its
    /// content out under the page picker's safe area, so the chips didn't show.
    private var chips: some View {
        ChipBar {
            ForEach(Filter.allCases, id: \.self) { item in
                BarChip(title: "\(item.rawValue) \(count(item))", icon: item == .all ? nil : item.icon,
                     selected: filter == item, tint: item.tint) {
                    withAnimation(.snappy(duration: 0.2)) { filter = item }
                }
                .accessibilityLabel(item == .gone ? "사진 앱에서 지워짐 \(count(item))" : "\(item.rawValue) \(count(item))")
            }
        }
    }

    // MARK: Data

    /// Saved before the app kept records; found missing in Photos by name and time.
    private var olderPhotos: [Photo] {
        library.photos.filter {
            library.isGone($0) && history.latest($0.name) == nil && !history.hidden.contains($0.name)
        }
    }

    private var filtered: [Session] { sessions(records(for: filter)) }

    private func records(for filter: Filter) -> [SaveHistory.Record] {
        switch filter {
        case .all:
            return history.records
        case .failed:
            // Only failures not saved since.
            return history.records.filter { r in
                r.outcome == .failed && !library.saved.contains(r.name)
            }
        case .gone:
            // The newest save of each name, when that one is gone from Photos.
            return history.records.filter { r in
                history.latest(r.name)?.id == r.id && history.photosState(of: r) == .deleted
            }
        }
    }

    /// How many rows each chip would show (사진 앱에서 지워짐 also counts photos saved before
    /// the app kept records).
    private func count(_ filter: Filter) -> Int {
        let older = filter == .failed ? 0 : olderPhotos.count
        return records(for: filter).count + older
    }

    private func sessions(_ records: [SaveHistory.Record]) -> [Session] {
        Dictionary(grouping: records, by: \.session)
            .map { Session(id: $0.key, date: $0.value.map(\.date).min() ?? .distantPast,
                           records: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.date > $1.date }
    }

    // MARK: Pieces

    @ViewBuilder private var accessSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(history.readStatus == .limited ? "사진 보관함 제한된 접근" : "사진 앱에서 지운 사진 알아보기",
                      systemImage: "photo.badge.checkmark")
                    .font(.headline)
                Text(accessText).font(.subheadline).foregroundStyle(.secondary)
                switch history.readStatus {
                case .notDetermined:
                    Button("사진 보관함 접근 허용") { Task { await history.requestRead() } }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                default:
                    Button("설정 앱에서 바꾸기") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var accessText: String {
        switch history.readStatus {
        case .limited:
            return "지금부터 저장하는 사진은 사진 앱에서 지웠는지 알 수 있어요. 예전에 저장한 사진까지 확인하려면 설정 앱 → GR Everyday → 사진에서 ‘전체 접근’을 골라 주세요."
        case .notDetermined:
            return "허용하면 사진 앱에서 지운 사진을 ‘이미 저장됨’으로 건너뛰지 않고 다시 저장할 수 있어요. 앱은 자기가 저장한 사진이 남아 있는지만 확인해요."
        default:
            return "사진 앱을 읽을 수 없어서, 사진 앱에서 지운 사진도 저장된 것으로 보여요. 설정 앱 → GR Everyday → 사진에서 접근을 바꿀 수 있어요."
        }
    }

    private func header(_ session: Session) -> some View {
        let saved = session.records.filter(\.isSave).count
        let skipped = session.records.filter { $0.outcome == .skipped }.count
        let failed = session.records.filter { $0.outcome == .failed }.count
        var parts = ["\(saved)장 저장"]
        if skipped > 0 { parts.append("\(skipped)장 건너뜀") }
        if failed > 0 { parts.append("\(failed)장 실패") }
        return HStack {
            Text(session.date.formatted(.dateTime.month().day().weekday().hour().minute()))
            Spacer()
            Text(parts.joined(separator: " · ")).textCase(nil)
        }
    }

    /// Save again: the failures, or the ones deleted in Photos.
    @ViewBuilder private func bulkSection(_ records: [SaveHistory.Record], older: [Photo] = []) -> some View {
        let photos = savable(records) + older.filter { library.localURL($0) != nil || connection.isConnected }
        if !photos.isEmpty {
            Section {
                Button {
                    library.save(photos, force: true)
                    showPhotos()
                } label: {
                    Label(filter == .gone ? "\(photos.count)장 사진 앱에 다시 저장" : "\(photos.count)장 다시 저장",
                          systemImage: "arrow.clockwise")
                }
                .disabled(library.isTransferring)
            } footer: {
                if photos.count < Set(records.map(\.name)).count + older.count {
                    Text(whyNotText)
                }
            }
        }
    }

    /// The photos that can be saved now: a copy in the Files app, or the camera connected
    /// and still holding it.
    private func savable(_ records: [SaveHistory.Record]) -> [Photo] {
        var seen = Set<String>()
        return records.compactMap { r in
            guard seen.insert(r.name).inserted, canSave(r) else { return nil }
            return library.photos.first { $0.id == r.photo.id } ?? r.photo
        }
    }

    /// Why a photo can't be saved again. Connected, the camera's list is current, so one
    /// missing from it was deleted there (or the card changed); offline the app can't tell.
    private var whyNotText: String {
        let noCopy = "사진 앱에서 지워졌고 파일 앱에도 사본이 없는 사진이에요. 처음부터 사진 앱에만 저장했거나, 파일 앱에서도 지운 경우예요."
        let later = "설정 → 저장 위치를 ‘사진 앱 + 파일 앱’으로 해 두면 파일 앱에 사본이 남아서, 앞으로는 카메라 없이도 다시 저장할 수 있어요."
        if connection.isConnected {
            return noCopy + " 연결된 카메라에도 없어서(카메라에서 지웠거나 다른 메모리 카드예요) 다시 저장할 수 없어요. " + later
        }
        return noCopy + " 카메라에 아직 남아 있다면, 카메라를 연결해서 다시 받아 저장할 수 있어요. " + later
    }

    private func canSave(_ r: SaveHistory.Record) -> Bool { canSave(r.photo) }

    /// A copy in the Files app, or the camera connected and holding this very photo: same
    /// name and, when known, same shooting time (another memory card can reuse the name).
    private func canSave(_ photo: Photo) -> Bool {
        if library.localURL(photo) != nil { return true }
        guard connection.isConnected, let onCamera = library.photos.first(where: { $0.id == photo.id }) else { return false }
        return library.sameShot(onCamera)
    }

    // MARK: Selecting

    /// A tap selects, starting 선택 if it wasn't on.
    private func tap(_ key: String) {
        if !selecting { withAnimation(.snappy(duration: 0.2)) { selecting = true } }
        toggle(key)
    }

    private func toggle(_ key: String) {
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    private func checkmark(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .transition(.move(edge: .leading).combined(with: .opacity))
    }

    @ViewBuilder private func selectionBar(_ records: [SaveHistory.Record], older: [Photo]) -> some View {
        let keys = records.map { "r:" + $0.id.uuidString } + older.map { "o:" + $0.id }
        let pickedRecords = records.filter { selected.contains("r:" + $0.id.uuidString) }
        let pickedOlder = older.filter { selected.contains("o:" + $0.id) }
        let photos = savable(pickedRecords) + pickedOlder.filter(canSave)
        let count = pickedRecords.count + pickedOlder.count
        HStack(spacing: 10) {
            // The count is in the navigation bar.
            let all = !keys.isEmpty && Set(keys).isSubset(of: selected)
            Button(all ? "선택 해제" : "전체 선택") { selected = all ? [] : Set(keys) }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Button(role: .destructive) { confirmRemove = true } label: {
                Label("삭제", systemImage: "trash").lineLimit(1).fixedSize()
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
            .tint(.red)
            .disabled(count == 0)
            Button {
                library.save(photos, force: true)
                selecting = false
                selected = []
                showPhotos()
            } label: {
                Label(photos.isEmpty ? "다시 저장" : "\(photos.count)장 다시 저장", systemImage: "arrow.clockwise")
                    .lineLimit(1).fixedSize()
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .disabled(photos.isEmpty || library.isTransferring)
            if photos.count < Set(pickedRecords.map(\.name)).count + pickedOlder.count {
                // Why some (or all) can't be saved again.
                Button { showWhyNot = true } label: {
                    Image(systemName: "info.circle").font(.title3)
                }
                .accessibilityLabel("다시 저장할 수 없는 이유")
                .popover(isPresented: $showWhyNot) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("다시 저장할 수 없는 사진이 있어요").font(.headline)
                        Text(whyNotText).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                    .frame(width: 300)
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
        .confirmationDialog("\(count)개를 목록에서 삭제할까요?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("목록에서 삭제", role: .destructive) {
                history.remove(Set(pickedRecords.map(\.id)))
                history.hide(Set(pickedOlder.map(\.name)))
                selected = []
                selecting = false
            }
        } message: {
            Text("기록만 지워져요. 사진 앱과 파일 앱의 사진은 그대로 남아요.")
        }
    }

    private func row(_ r: SaveHistory.Record) -> some View {
        let state = history.photosState(of: r)
        // A copy moved to the Files app's 최근 삭제된 항목 (.Trash) is no copy any more.
        let file = r.fileURL.flatMap {
            !$0.path.contains("/.") && FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        let key = "r:" + r.id.uuidString
        return HStack(spacing: 12) {
            if selecting { checkmark(selected.contains(key)) }
            Thumb(photo: r.photo, showsTransfer: false)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.subheadline.weight(.medium))
                Text(detail(r, state: state, file: file))
                    .font(.caption)
                    .foregroundStyle(r.outcome == .failed ? Color.red : state == .deleted ? Color.orange : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            icon(r, state: state)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(key) }
        .contextMenu { if !selecting { actions(r, state: state, file: file) } }
        .swipeActions(edge: .trailing) {
            if !selecting {
                Button("목록에서 삭제", role: .destructive) { history.remove([r.id]) }
            }
        }
        // 다시 저장 is in the long-press menu; a rightward swipe goes back to 촬영 통계.
    }

    @ViewBuilder private func actions(_ r: SaveHistory.Record, state: SaveHistory.PhotosState, file: URL?) -> some View {
        if canSave(r) {
            Button { library.save([library.photos.first { $0.id == r.photo.id } ?? r.photo], force: true); showPhotos() } label: {
                Label(state == .deleted ? "사진 앱에 다시 저장" : "다시 저장", systemImage: "arrow.clockwise")
            }
            .disabled(library.isTransferring)
        }
        if state == .inPhotos || state == .unknown {
            Button { PhotosLibrary.openApp() } label: { Label("사진 앱 열기", systemImage: "photo.on.rectangle") }
        }
        if let file {
            Button { PhotosLibrary.showInFiles(file) } label: { Label("파일 앱에서 보기", systemImage: "folder") }
        }
        Button(role: .destructive) { history.remove([r.id]) } label: { Label("목록에서 삭제", systemImage: "trash") }
    }

    private func detail(_ r: SaveHistory.Record, state: SaveHistory.PhotosState, file: URL?) -> String {
        var parts: [String] = []
        switch r.outcome {
        case .failed: return "실패 · " + (r.message ?? "알 수 없는 이유")
        case .skipped: return "이미 있어서 건너뜀"
        case .resaved: parts.append("사진 앱에 다시 넣음")
        case .saved: break
        }
        switch state {
        case .inPhotos: if r.outcome == .saved { parts.append("사진 앱에 있음") }
        case .deleted: parts = ["사진 앱에서 지워짐"]
        case .unknown: if r.outcome == .saved { parts.append("사진 앱에 저장함") }
        case .none: break
        }
        if file != nil { parts.append("파일 앱에 사본 있음") }
        else if r.file != nil { parts.append("파일 앱에서도 지워짐") }
        // Saved to the Photos app only: say so where it matters, when it's gone from there.
        else if state == .deleted { parts.append("파일 앱엔 저장 안 함") }
        if let bytes = r.bytes { parts.append(TransferText.bytes(bytes)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func icon(_ r: SaveHistory.Record, state: SaveHistory.PhotosState) -> some View {
        switch (r.outcome, state) {
        case (.failed, _): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case (.skipped, _): Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary)
        case (_, .deleted): Image(systemName: "checkmark.circle.badge.xmark").foregroundStyle(.orange)
        default: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .all: return "아직 저장한 사진이 없어요"
        case .gone: return "사진 앱에서 지운 사진이 없어요"
        case .failed: return "실패한 사진이 없어요"
        }
    }

    private var emptyDetail: String {
        switch filter {
        case .all: return "사진을 저장하면 언제 무엇을 저장했는지 여기에 남아요."
        case .gone: return history.present == nil
            ? "사진 보관함 접근을 허용하면 사진 앱에서 지운 사진을 알 수 있어요."
            : "앱이 저장한 사진이 모두 사진 앱에 있어요."
        case .failed: return "저장하지 못한 사진이 생기면 여기서 다시 저장할 수 있어요."
        }
    }
}

