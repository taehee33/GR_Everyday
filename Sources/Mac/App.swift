import SwiftUI

@main
struct GRLinkApp: App {
    @StateObject private var connection = ConnectionModel()
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        WindowGroup("GR Everyday") {
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

/// GR Mac's own settings: the sidebar's "설정" pane and GR Everyday → 설정… (⌘,).
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
    @AppStorage(LibraryModel.AutoSave.enabled) private var autoSave = false
    @AppStorage(LibraryModel.AutoSave.jpeg) private var autoSaveJPEG = true
    @AppStorage(LibraryModel.AutoSave.raw) private var autoSaveRAW = true
    @AppStorage(LibraryModel.AutoSave.video) private var autoSaveVideo = false
    @AppStorage(LibraryModel.AutoSave.usb) private var autoSaveUSB = true
    @AppStorage(LibraryModel.AutoSave.wifi) private var autoSaveWiFi = true
    @State private var showAbout = false

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

            Section {
                Toggle("카메라를 연결하면 새 사진 자동 저장", isOn: $autoSave)
                if autoSave {
                    LabeledContent("파일 종류") {
                        HStack(spacing: 14) {
                            Toggle("JPG", isOn: $autoSaveJPEG)
                            Toggle("RAW (DNG)", isOn: $autoSaveRAW)
                            Toggle("동영상", isOn: $autoSaveVideo)
                        }
                        .toggleStyle(.checkbox)
                    }
                    LabeledContent("연결 방식") {
                        HStack(spacing: 14) {
                            Toggle("USB", isOn: $autoSaveUSB)
                            Toggle("Wi-Fi", isOn: $autoSaveWiFi)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            } header: {
                Text("자동 저장")
            } footer: {
                Text("연결할 때마다 ‘미저장’ 사진을 위 저장 폴더로 받습니다. 카메라의 사진은 지우지 않습니다. 처음 켜면 카드에 있는 미저장 사진을 모두 받으니, 원하지 않으면 먼저 저장 폴더를 정리하거나 파일 종류를 줄이세요. Wi-Fi는 USB보다 훨씬 느리고, 동영상은 크기가 큽니다.")
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
                Text("마지막으로 본 카드의 사진 목록·썸네일, 촬영 날짜·방향, 재생하려고 받은 동영상을 Mac에 남겨 둡니다. 그래서 카메라 없이도 라이브러리를 볼 수 있고, 다시 열 때 카메라에 묻지 않습니다. 비우면 카메라 없이는 라이브러리를 볼 수 없습니다. 카드에서 지운 사진의 썸네일은 연결할 때 지웁니다. 카드를 포맷해 파일 이름(R000xxxx)이 다시 쓰이면 연결할 때 알아채고 저절로 비웁니다. 지운 사진의 촬영 통계 기록은 남습니다.")
            }
            .task { cacheSize = library.cacheSize }

            Section("정보") {
                LabeledContent("버전", value: version)
                LabeledContent("빌드") { Text(build).textSelection(.enabled) }
                LabeledContent("진단 로그") {
                    Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([DebugLog.url]) }
                }
                Button("앱 정보 및 지원…") { showAbout = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAbout) {
            NavigationStack {
                AboutView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { showAbout = false } } }
            }
            .frame(minWidth: 520, minHeight: 560)
        }
    }
}


struct ContentView: View {
    @EnvironmentObject var connection: ConnectionModel
    @EnvironmentObject var library: LibraryModel
    /// Opens on the camera screen until a library has been seen once.
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
            case .moment: MomentView()
            case .library, .remote, .stats:
                // Without a camera, the library and 촬영 통계 show the list saved from the last
                // connection; remote shooting needs the camera.
                if connection.isConnected || connection.state == .lost || (section != .remote && !library.photos.isEmpty) {
                    switch section {
                    case .library: LibraryView()
                    case .stats: StatsView(stats: library.stats, section: $section)
                    default: RemoteView()
                    }
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
            if state == .connected {
                library.prepareAutoSave(viaUSB: connection.viaUSB)
                Task { await library.reload() }
            }
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
                Text(connection.model + (connection.batteryText.map { " · 배터리 \($0)" } ?? ""))
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
