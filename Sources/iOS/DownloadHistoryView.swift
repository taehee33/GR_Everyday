import SwiftUI
import Photos

/// 라이브러리 → 다운로드 기록: every save by time, what each photo became (in the Photos app,
/// deleted there since, in the Files app, skipped, failed), and a way to save it again.
struct DownloadHistoryView: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var connection: ConnectionModel
    @ObservedObject private var history = SaveHistory.shared
    /// Back to 사진, where the save's progress shows.
    var showPhotos: () -> Void = {}
    @State private var filter: Filter = .all
    @State private var confirmClear = false

    enum Filter: String, CaseIterable { case all = "전체", gone = "사진 앱에서 지워짐", failed = "실패" }

    private struct Session: Identifiable {
        let id: UUID
        let date: Date
        let records: [SaveHistory.Record]
    }

    var body: some View {
        let shown = filtered
        // Saved before the app kept records; found missing in Photos by name and time.
        let older = filter == .gone
            ? library.photos.filter { library.goneFromPhotos.contains($0.name) && history.latest($0.name) == nil }
            : []
        List {
            if PhotosLibrary.target.toPhotos && history.readStatus != .authorized { accessSection }
            Section {
                Picker("보기", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if shown.isEmpty && older.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "clock.arrow.circlepath",
                                       description: Text(emptyDetail))
                    .listRowBackground(Color.clear)
            } else {
                if filter != .all { bulkSection(shown.flatMap(\.records), older: older) }
                if !older.isEmpty {
                    Section("예전에 저장한 사진") {
                        ForEach(older) { photo in
                            HStack(spacing: 12) {
                                Thumb(photo: photo, showsTransfer: false)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .allowsHitTesting(false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(photo.name).font(.subheadline.weight(.medium))
                                    Text("사진 앱에서 지워짐 · 파일 앱").font(.caption).foregroundStyle(.orange)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "checkmark.circle.badge.xmark").foregroundStyle(.orange)
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
                Section {
                    Button("기록 모두 지우기", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("기록만 지워져요. 사진 앱과 파일 앱의 사진은 그대로 남아요.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear { history.refreshPresence() }
        .confirmationDialog("다운로드 기록을 모두 지울까요?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("기록 지우기", role: .destructive) { history.clear() }
        } message: {
            Text("사진은 지워지지 않아요. 다만 앱이 저장했던 사진을 기억하지 못해서, 사진 앱에만 있는 사진은 다시 저장 대상으로 보일 수 있어요.")
        }
    }

    // MARK: Data

    private var filtered: [Session] {
        let records: [SaveHistory.Record]
        switch filter {
        case .all:
            records = history.records
        case .failed:
            // Only failures not saved since.
            records = history.records.filter { r in
                r.outcome == .failed && !library.saved.contains(r.name)
            }
        case .gone:
            // The newest save of each name, when that one is gone from Photos.
            records = history.records.filter { r in
                history.latest(r.name)?.id == r.id && history.photosState(of: r) == .deleted
            }
        }
        return sessions(records)
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
                    library.save(photos)
                    showPhotos()
                } label: {
                    Label(filter == .gone ? "\(photos.count)장 사진 앱에 다시 저장" : "\(photos.count)장 다시 저장",
                          systemImage: "arrow.clockwise")
                }
                .disabled(library.isTransferring)
            } footer: {
                if photos.count < Set(records.map(\.name)).count + older.count {
                    Text("카메라에도 파일 앱에도 없는 사진은 카메라를 연결해야 저장할 수 있어요.")
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

    private func canSave(_ r: SaveHistory.Record) -> Bool {
        if library.localURL(r.photo) != nil { return true }
        return connection.isConnected && library.photos.contains { $0.id == r.photo.id }
    }

    private func row(_ r: SaveHistory.Record) -> some View {
        let state = history.photosState(of: r)
        let file = r.fileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        return HStack(spacing: 12) {
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
        .contextMenu { actions(r, state: state, file: file) }
        .swipeActions(edge: .trailing) {
            Button("기록 지우기", role: .destructive) { history.remove([r.id]) }
        }
        .swipeActions(edge: .leading) {
            if (state == .deleted || r.outcome == .failed), canSave(r), !library.saved.contains(r.name) {
                Button("다시 저장") { library.save([r.photo]); showPhotos() }.tint(.accentColor)
            }
        }
    }

    @ViewBuilder private func actions(_ r: SaveHistory.Record, state: SaveHistory.PhotosState, file: URL?) -> some View {
        if !library.saved.contains(r.name), canSave(r) {
            Button { library.save([r.photo]); showPhotos() } label: {
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
        Button(role: .destructive) { history.remove([r.id]) } label: { Label("기록 지우기", systemImage: "trash") }
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
        if file != nil { parts.append("파일 앱") } else if r.file != nil { parts.append("파일 앱에서 지워짐") }
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
