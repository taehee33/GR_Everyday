import SwiftUI

@main
struct GRLinkApp: App {
    @StateObject private var connection = ConnectionModel()
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        WindowGroup("GR Mac") {
            ContentView()
                .environmentObject(connection)
                .environmentObject(library)
                .frame(minWidth: 960, minHeight: 640)
        }
        Settings {
            AppSettingsView()
                .environmentObject(connection)
                .environmentObject(library)
                .frame(width: 600, height: 640)
        }
    }
}

/// GR Mac's own settings: the sidebar's "설정" pane and GR Mac → 설정… (⌘,).
struct AppSettingsView: View {
    @EnvironmentObject var connection: ConnectionModel
    @EnvironmentObject var library: LibraryModel
    @AppStorage("thumbSize") private var thumbSize = 150.0
    @AppStorage("restoreWiFi") private var restoreWiFi = true
    @State private var cacheSize: Int64 = 0
    @AppStorage("turnOffCameraWiFi") private var turnOffCameraWiFi = false
    @AppStorage("loupeScroll") private var loupeScroll = ScrollAction.zoom
    @AppStorage("loupeDrag") private var loupeDrag = DragAction.pan
    @AppStorage("loupeClick") private var loupeClick = ClickAction.double
    @AppStorage("invertNavigateScroll") private var invertNavigate = false
    @AppStorage("gridDrag") private var gridDrag = GridDragAction.select
    @AppStorage("modifierScrollResizesGrid") private var modifierScrollResizes = true

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드"
    }

    /// Stamped by scripts/build-app.sh: "빌드 3 · 85651f7 · 2026-10-31 23:55".
    private var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let commit = info["GRBuildCommit"] as? String else { return "스크립트 없이 빌드됨" }
        return ["빌드 \(info["CFBundleVersion"] as? String ?? "?")", commit, info["GRBuildDate"] as? String]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("저장 폴더") {
                    HStack {
                        Text(library.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                        Button("변경…") {
                            if let url = FolderPicker.choose(from: library.destination) { library.destination = url }
                        }
                        Button("Finder에서 보기") { NSWorkspace.shared.open(library.destination) }
                            .disabled(!FileManager.default.fileExists(atPath: library.destination.path))
                    }
                }
                Toggle("촬영 날짜별 폴더로 나눠 저장 (예: 2026-10-31)", isOn: $library.dateSubfolders)
                Toggle("같은 이름의 파일이 이미 있으면 건너뛰기", isOn: $library.skipExisting)
                Toggle("저장이 끝나면 Finder에서 폴더 열기", isOn: $library.revealAfterSave)
            } header: {
                Text("사진 저장")
            } footer: {
                Text("‘미저장’은 카메라 사진의 파일 이름(예: R0000209.JPG)이 저장 폴더나 그 안의 날짜 폴더에 있는지로 판단합니다. 저장한 파일을 다른 곳으로 옮기거나 이름을 바꾸면 다시 미저장으로 표시됩니다.")
            }

            Section("라이브러리") {
                Picker("정렬", selection: $library.sort) {
                    ForEach(LibraryModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("날짜별로 묶어 보기", isOn: $library.groupByDate)
                LabeledContent("썸네일 크기") {
                    Slider(value: $thumbSize, in: 90...320, step: 10) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "photo").font(.caption)
                    } maximumValueLabel: {
                        Image(systemName: "photo").font(.title3)
                    }
                    .frame(width: 240)
                }
            }

            Section {
                Picker("사진 위에서 스크롤", selection: $loupeScroll) {
                    ForEach(ScrollAction.allCases) { Text($0.label).tag($0) }
                }
                Toggle("사진 넘기는 스크롤 방향 반대로", isOn: $invertNavigate)
                    .disabled(loupeScroll == .zoom)
                Picker("사진 위에서 드래그", selection: $loupeDrag) {
                    ForEach(DragAction.allCases) { Text($0.label).tag($0) }
                }
                Picker("사진 클릭", selection: $loupeClick) {
                    ForEach(ClickAction.allCases) { Text($0.label).tag($0) }
                }
                Picker("그리드에서 드래그", selection: $gridDrag) {
                    ForEach(GridDragAction.allCases) { Text($0.label).tag($0) }
                }
                Toggle("그리드에서 ⌘/⌥ + 스크롤로 썸네일 크기 조절", isOn: $modifierScrollResizes)
            } header: {
                Text("조작")
            } footer: {
                Text("확대 보기·편집 화면에 적용됩니다. ⌘ 또는 ⌥를 누른 채 스크롤하면 설정과 상관없이 확대/축소, 트랙패드 핀치도 항상 확대/축소입니다. 단축키는 라이브러리 툴바의 키보드 버튼에서 볼 수 있습니다.")
            }

            Section {
                Toggle("연결을 끊으면 Mac Wi-Fi를 원래 네트워크로 되돌리기", isOn: $restoreWiFi)
                Toggle("연결을 끊을 때 카메라 Wi-Fi도 끄기", isOn: $turnOffCameraWiFi)
                if turnOffCameraWiFi {
                    Text("배터리는 아끼지만, 다시 연결하려면 카메라 메뉴에서 Wi-Fi를 직접 켜야 합니다. Mac은 Bluetooth로 카메라 Wi-Fi를 켤 수 없습니다.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("연결")
            } footer: {
                Text("카메라 등록·이름 바꾸기·삭제와 Wi-Fi 정보는 ‘카메라’ 탭에서 합니다. 등록된 카메라 \(connection.cameras.count)대.")
            }

            Section {
                LabeledContent("저장된 캐시") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("비우기") {
                            library.clearCaches()
                            cacheSize = library.cacheSize
                        }
                    }
                }
            } header: {
                Text("캐시")
            } footer: {
                Text("썸네일, 촬영 날짜·방향, 재생하려고 받은 동영상을 Mac에 남겨 두어 라이브러리를 다시 열 때 카메라에 묻지 않습니다. 카메라 메모리 카드를 포맷해 파일 이름(R000xxxx)이 다시 쓰이면 비워 주세요.")
            }
            .task { cacheSize = library.cacheSize }

            Section("정보") {
                LabeledContent("버전", value: version)
                LabeledContent("빌드") { Text(build).textSelection(.enabled) }
                LabeledContent("진단 로그") {
                    Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([DebugLog.url]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case camera = "카메라", library = "라이브러리", remote = "원격 촬영", settings = "설정"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .camera: return "camera"
        case .library: return "photo.on.rectangle"
        case .remote: return "camera.aperture"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var connection: ConnectionModel
    @EnvironmentObject var library: LibraryModel
    @State private var section: Pane = .camera
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(Pane.allCases, selection: $section) { s in
                // Settings work without a camera; the camera panes show the connect screen until then.
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .safeAreaInset(edge: .bottom) { StatusBox() }
            .navigationSplitViewColumnWidth(220)
        } detail: {
            switch section {
            case .camera: CameraView(ble: connection.ble, section: $section)
            case .settings: AppSettingsView()
            case .library, .remote:
                if connection.isConnected || connection.state == .lost {
                    if section == .library { LibraryView() } else { RemoteView() }
                } else {
                    ContentUnavailableView {
                        Label("카메라에 연결되지 않음", systemImage: "camera")
                    } description: {
                        Text("카메라 탭에서 Wi-Fi 또는 USB로 연결하세요.")
                    } actions: {
                        Button("카메라 탭으로") { section = .camera }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        // Full screen / ⇧Tab: no title bar or sidebar button above the photo either.
        .toolbar(library.immersive ? .hidden : .visible, for: .windowToolbar)
        // Tab / ⇧Tab / full screen in the library hide the sidebar too.
        .onChange(of: library.panels && !library.immersive) { _, show in
            withAnimation { columns = show ? .all : .detailOnly }
        }
        .onChange(of: section) { _, s in
            if s != .library, library.immersive || !library.panels {
                library.immersive = false
                library.panels = true
            }
        }
        .onChange(of: connection.state) { _, state in
            if state == .connected { Task { await library.reload() } }
        }
    }
}

struct StatusBox: View {
    @EnvironmentObject var connection: ConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.callout.bold())
            }
            if connection.isConnected || connection.state == .lost {
                Label(connection.route, systemImage: connection.viaUSB ? "cable.connector" : "wifi")
                    .font(.caption).foregroundStyle(.secondary)
                Text(connection.model + (connection.battery.map { " · 배터리 \($0)%" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Button("연결 끊기") { Task { await connection.disconnect() } }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var title: String {
        switch connection.state {
        case .connected: return "연결됨"
        case .lost: return connection.cameraWLANOff ? "카메라 WLAN 꺼짐 — 다시 켜면 자동 연결" : "연결 끊김 — 재시도 중"
        case .pairing: return "페어링 중…"
        case .waking, .joining: return "연결 중…"
        case .disconnected, .failed: return "연결 안 됨"
        }
    }

    private var color: Color {
        switch connection.state {
        case .connected: return .green
        case .lost, .pairing, .waking, .joining: return .orange
        case .disconnected, .failed: return .gray
        }
    }
}
