import SwiftUI

/// Home tab, modelled on GR WORLD: one page per registered camera plus a "+" page to
/// register a new one. Each camera page connects, opens the other panes and shows
/// connection details.
struct CameraView: View {
    @EnvironmentObject var connection: ConnectionModel
    @EnvironmentObject var library: LibraryModel
    /// ConnectionModel owns it; observed here so scan results redraw the list.
    @ObservedObject var ble: BLEWaker
    @Binding var section: Pane

    /// Index into `connection.cameras`; `cameras.count` is the "+" page.
    @State private var page = 0
    @State private var showCameraSettings = false
    @State private var showInfo = true
    @State private var showPassword = false
    @State private var renaming: SavedCamera?
    @State private var newName = ""
    @State private var removing: SavedCamera?
    @State private var openLibraryWhenConnected = false
    /// Bumped after a removal so the Bluetooth row re-reads the bond.
    @State private var bondCheck = 0
    /// Whether the Mac lists the camera in its Bluetooth settings; nil while checking.
    @State private var macBond: Bool?
    @State private var bondMessage: String?

    private var cameras: [SavedCamera] { connection.cameras }
    private var current: SavedCamera? { cameras.indices.contains(page) ? cameras[page] : nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                carousel
                pageDots
                if let camera = current {
                    cameraPanel(camera)
                } else {
                    RegisterPanel(ble: ble)
                }
                if connection.isConnected && connection.connectedCameraID == nil {
                    Label("등록되지 않은 카메라(\(connection.model))에 연결돼 있습니다.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("이미 Mac이 카메라 Wi-Fi에 연결돼 있어요") { Task { await connection.connectDirect() } }
                    .buttonStyle(.link)
                    .disabled(connection.isBusy)
            }
            .padding(32)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .onAppear { page = cameras.firstIndex { $0.id == connection.selectedCameraID } ?? 0 }
        .onChange(of: page) { _, page in
            if cameras.indices.contains(page) { connection.selectedCameraID = cameras[page].id }
        }
        .onChange(of: connection.selectedCameraID) { _, id in
            if let i = cameras.firstIndex(where: { $0.id == id }) { page = i }
        }
        .onChange(of: connection.state) { _, state in
            // "이미지 가져오기" while disconnected: connect, then open the library.
            if state == .connected, openLibraryWhenConnected { section = .library }
            if !connection.isBusy { openLibraryWhenConnected = false }
        }
        .sheet(isPresented: $showCameraSettings) {
            CameraSettingsSheet { showCameraSettings = false }
        }
        .alert("카메라 이름", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("이름", text: $newName)
            Button("저장") { if let c = renaming { connection.rename(c.id, to: newName) } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 Mac에서만 쓰는 이름입니다. 비워 두면 Bluetooth 이름(GR_…)으로 표시됩니다.")
        }
        .confirmationDialog("‘\(removing?.displayName ?? "")’ 카메라 정보를 지울까요?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("지우기", role: .destructive) {
                if let c = removing {
                    connection.remove(c.id)
                    page = min(page, connection.cameras.count)
                    bondMessage = nil
                }
            }
        } message: {
            if removing != nil, macBond == true {
                Text("저장된 Wi-Fi 암호도 지워집니다. 다시 쓰려면 새로 등록해야 합니다.\n이 카메라가 아직 Mac Bluetooth에 남아 있습니다. 다시 등록하기 전에 ‘기기 지우기’도 해 두세요.")
            } else {
                Text("저장된 Wi-Fi 암호도 지워집니다. 다시 쓰려면 ‘+’에서 새로 등록해야 합니다.")
            }
        }
    }

    // MARK: Carousel

    private var carousel: some View {
        HStack {
            Button { page -= 1 } label: { Image(systemName: "chevron.left").font(.title) }
                .buttonStyle(.plain).disabled(page == 0).opacity(page == 0 ? 0.2 : 1)
            Spacer()
            VStack(spacing: 10) {
                if let camera = current {
                    Text(camera.displayName).font(.largeTitle.bold())
                    Text(camera.shortModel ?? "RICOH GR").font(.title3).foregroundStyle(.secondary)
                    statusIcons(camera)
                    CameraPicture(camera: camera)
                        .padding(.vertical, 18)
                } else {
                    Text("새 카메라").font(.largeTitle.bold())
                    Text("RICOH GR").font(.title3).foregroundStyle(.secondary)
                    Image(systemName: "camera")
                        .font(.system(size: 110, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 18)
                }
            }
            Spacer()
            Button { page += 1 } label: { Image(systemName: "chevron.right").font(.title) }
                .buttonStyle(.plain).disabled(page >= cameras.count).opacity(page >= cameras.count ? 0.2 : 1)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 14) {
            ForEach(cameras.indices, id: \.self) { i in
                Circle()
                    .fill(i == page ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                    .onTapGesture { page = i }
            }
            Image(systemName: "plus")
                .font(.body.bold())
                .foregroundStyle(page == cameras.count ? Color.primary : Color.secondary)
                .onTapGesture { page = cameras.count }
        }
    }

    private func isConnected(_ camera: SavedCamera) -> Bool {
        connection.connectedCameraID == camera.id && (connection.isConnected || connection.state == .lost)
    }

    private func statusIcons(_ camera: SavedCamera) -> some View {
        let connected = isConnected(camera)
        return HStack(spacing: 16) {
            if connected && connection.viaUSB {
                Label("USB 연결됨", systemImage: "cable.connector").foregroundStyle(.green)
            } else {
                Label(connected ? "Wi-Fi 연결됨" : "Wi-Fi 연결 안 됨", systemImage: connected ? "wifi" : "wifi.slash")
                    .foregroundStyle(connected ? .green : .secondary)
            }
            let linked = ble.linkedCameraID == camera.id
            Label(linked ? "Bluetooth 연결됨" : "Bluetooth 끊김", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(linked ? .blue : .secondary)
                .help(linked ? "이 연결로 카메라 Wi-Fi를 켤 수 있습니다." : "카메라 WLAN(Wi-Fi)은 휴대폰의 GR WORLD로 켜야 합니다.")
            if connected, let battery = connection.battery, let text = connection.batteryText {
                Label(text, systemImage: connection.onExternalPower ? "battery.100percent.bolt" : batteryIcon(battery))
            }
            if connected {
                ForEach(connection.storages, id: \.self) { storage in
                    if let remain = storage.remain {
                        HStack(spacing: 4) {
                            Text(storage.name.uppercased())
                                .font(.caption.bold()).padding(.horizontal, 4).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary, lineWidth: 1))
                            Text("\(remain)장")
                        }
                    }
                }
            }
        }
        .font(.callout)
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: Camera page

    @ViewBuilder private func cameraPanel(_ camera: SavedCamera) -> some View {
        let connected = isConnected(camera)
        stateMessages

        VStack(spacing: 0) {
            // Same as the old "다시 연결": join the camera Wi-Fi with the saved password,
            // then show the library.
            Button {
                if connected { section = .library } else {
                    openLibraryWhenConnected = true
                    Task { await connection.connect(camera) }
                }
            } label: {
                HStack {
                    Image(systemName: "wifi").font(.title2)
                    Spacer()
                    Text(connected ? "연결됨 · 라이브러리 열기" : "카메라 연결 (Wi-Fi)").font(.title3)
                    Spacer()
                    Image(systemName: "wifi").font(.title2).hidden()
                }
                .padding(.horizontal, 24).padding(.vertical, 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.9))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .disabled(connection.isBusy)

            HStack(spacing: 1) {
                tile("원격 촬영", "dot.radiowaves.left.and.right", enabled: connected && !connection.viaUSB) { section = .remote }
                tile("카메라 설정", "slider.horizontal.3", enabled: connected && !connection.viaUSB) { showCameraSettings = true }
                tile(showInfo ? "정보 숨기기" : "연결 정보", "info.circle", enabled: true) { showInfo.toggle() }
                Menu {
                    Button("이름 바꾸기…") { newName = camera.displayName; renaming = camera }
                    CameraPictureMenu(camera: camera)
                    Button("다시 페어링 (Bluetooth 다시 연결)") { Task { await connection.repair(camera) } }
                    Button("Mac Bluetooth에서 기기 지우기…") { Task { await removeBond(camera) } }
                    Divider()
                    Button("카메라 정보 지우기…", role: .destructive) { removing = camera }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver").font(.title2)
                        Text("관리").font(.callout)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                }
                .menuStyle(.button).buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(.background.secondary)
            }
            .background(.separator)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))

        if connected {
            Button("연결 끊기") { Task { await connection.disconnect() } }
                .buttonStyle(.link)
        } else {
            // After pairing the camera ignores the Mac over Bluetooth, so the iPhone
            // switches the camera's Wi-Fi on and the Mac joins it.
            Button {
                openLibraryWhenConnected = true
                Task { await connection.connectViaPhone(camera) }
            } label: {
                Label("휴대폰 GR WORLD로 WLAN(Wi-Fi) 켜고 연결", systemImage: "iphone")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(connection.isBusy)

            // A GR on a cable shows up as a PTP camera; files only, Wi-Fi stays free.
            Button {
                openLibraryWhenConnected = true
                Task { await connection.connectUSB() }
            } label: {
                Label(connection.usb.detected == nil ? "USB로 연결 (케이블을 연결하고 카메라를 켜세요)" : "USB로 연결",
                      systemImage: "cable.connector")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(connection.isBusy || connection.usb.detected == nil)
        }
        if connected && connection.viaUSB {
            Text("USB로 연결됨: 사진 보기·저장만 됩니다. 원격 촬영과 카메라 설정은 Wi-Fi 연결에서만 됩니다. Mac의 Wi-Fi(인터넷·AirPlay)는 그대로 쓸 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        Text("카메라 Wi-Fi는 Bluetooth로만 켜집니다. 페어링한 Bluetooth 연결은 앱이 켜져 있는 동안 유지되고, 끊긴 뒤에는 Mac이 카메라에 다시 붙을 수 없습니다. 그때는 휴대폰의 GR WORLD에서 카메라 WLAN(Wi-Fi)을 켜고 ‘휴대폰 GR WORLD로 WLAN(Wi-Fi) 켜고 연결’을 누르세요. 연결된 뒤 휴대폰 제어 센터에서 Bluetooth를 끄면 휴대폰을 잠가도 카메라 WLAN이 유지됩니다(Bluetooth를 켠 채 잠그면 카메라가 WLAN을 끕니다). Wi-Fi에 연결된 동안 Mac의 인터넷은 끊깁니다.")
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)

        if showInfo { infoBox(camera, connected: connected) }
    }

    @ViewBuilder private var stateMessages: some View {
        switch connection.state {
        case .pairing(let msg), .waking(let msg), .joining(let msg):
            HStack {
                ProgressView().controlSize(.small)
                Text(msg)
                Button("취소") { connection.cancelBluetooth() }
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).multilineTextAlignment(.center)
            if connection.needsRepair, let camera = current {
                Button("다시 페어링") { Task { await connection.repair(camera) } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        default:
            if let notice = connection.notice {
                Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private func tile(_ title: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.callout)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .background(.background.secondary)
        .help(enabled ? title : "카메라에 연결하면 쓸 수 있습니다")
    }

    // MARK: Connection info

    private func infoBox(_ camera: SavedCamera, connected: Bool) -> some View {
        GroupBox("연결 정보") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("상태", stateText(connected))
                row("카메라 Wi-Fi", camera.credentials?.ssid ?? "저장 안 됨")
                if let password = camera.credentials?.passphrase {
                    GridRow {
                        Text("Wi-Fi 암호").foregroundStyle(.secondary)
                        HStack {
                            Text(showPassword ? password : String(repeating: "•", count: 10))
                                .font(.body.monospaced()).textSelection(.enabled)
                            Button(showPassword ? "숨기기" : "보기") { showPassword.toggle() }.buttonStyle(.link)
                            Button("복사") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(password, forType: .string)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                row("카메라 주소", connection.viaUSB ? "USB 케이블" : CameraAPI.base.host() ?? "192.168.0.1")
                row("Bluetooth 이름", camera.bleName)
                row("Bluetooth 연결", ble.linkedCameraID == camera.id
                    ? "유지 중 — 이 연결로 카메라 Wi-Fi를 켭니다"
                    : "끊김 — 카메라 WLAN(Wi-Fi)은 휴대폰의 GR WORLD로 켜세요")
                GridRow {
                    Text("Mac Bluetooth").foregroundStyle(.secondary)
                    HStack {
                        Text(macBond.map { $0 ? "기기 등록됨" : "등록 안 됨" } ?? "확인 중…")
                        if macBond == true {
                            Button("기기 지우기") { Task { await removeBond(camera) } }.buttonStyle(.link)
                        }
                        if let bondMessage { Text(bondMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                row("모델", (connected ? connection.props["model"] as? String : nil) ?? camera.model ?? "-")
                if connected {
                    if let firmware = connection.props["firmwareVersion"] as? String { row("펌웨어", firmware) }
                    if let battery = connection.batteryText { row("배터리", battery) }
                    ForEach(connection.storages, id: \.self) { storage in
                        row("저장 공간 (\(storage.name.uppercased()))",
                            [storage.remain.map { "\($0)장 촬영 가능" }, storage.files.map { "파일 \($0)개" }]
                                .compactMap { $0 }.joined(separator: " · "))
                    }
                }
                row("등록일", camera.pairedAt.map(Self.dateText) ?? "-")
                row("마지막 연결", camera.lastConnected.map(Self.dateText) ?? "-")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            Divider()
            HStack {
                Text("이 Mac에 저장된 이 카메라의 이름·Wi-Fi 암호·기록을 지웁니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("카메라 정보 지우기…", role: .destructive) { removing = camera }
                    .disabled(connected)
                    .help(connected ? "연결을 끊은 뒤 지울 수 있습니다" : "이 카메라의 등록을 삭제합니다")
            }
            .padding(8)
        }
        .task(id: "\(camera.id)#\(bondCheck)") {
            macBond = nil
            macBond = await connection.hasMacBond(camera)
            if macBond == false { bondMessage = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            bondCheck += 1
        }
    }

    /// The key macOS keeps from pairing is refused by the camera and blocks pairing again,
    /// so it has to go before re-registering. Apps can't remove it themselves, so this
    /// opens Bluetooth settings; the state is checked again when the user comes back.
    private func removeBond(_ camera: SavedCamera) async {
        bondMessage = "Bluetooth 설정에서 \(camera.bleName) 옆 ⓘ → ‘이 기기 지우기’를 누르세요."
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func stateText(_ connected: Bool) -> String {
        if connected {
            guard connection.state == .lost else { return "연결됨" }
            return connection.cameraWLANOff
                ? "카메라 WLAN(Wi-Fi) 꺼짐 — 휴대폰의 GR WORLD를 다시 열어 WLAN을 켜면 자동으로 다시 연결합니다. 다음부터는 연결된 뒤 휴대폰 Bluetooth를 끄고 잠그세요"
                : "응답 없음 — 재시도 중"
        }
        switch connection.state {
        case .pairing, .waking, .joining: return "연결 중…"
        default: return "연결 안 됨"
        }
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "ko_KR")))
    }
}

/// "+" page: Bluetooth pairing, which registers the camera and reads its Wi-Fi password.
private struct RegisterPanel: View {
    @EnvironmentObject var connection: ConnectionModel
    @ObservedObject var ble: BLEWaker

    var body: some View {
        VStack(spacing: 16) {
            switch connection.state {
            case .pairing(let msg):
                PairingProgress(message: msg) { connection.cancelBluetooth() }
            default:
                if case .failed(let msg) = connection.state {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).multilineTextAlignment(.center)
                    if connection.needsBondRemoval {
                        Button("Bluetooth 설정 열기") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                        }
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("새 카메라 등록").font(.headline)
                        Step(number: 1, title: "카메라에서 페어링 시작",
                             detail: "MENU → 무선 통신 → Bluetooth → 페어링. 카메라가 페어링 대기 화면을 띄웁니다.")
                        Step(number: 2, title: "Mac에서 카메라 찾기",
                             detail: "아래 ‘카메라 찾기’를 누르면 GR_로 시작하는 카메라가 나타납니다.")
                        Step(number: 3, title: "페어링 코드 입력",
                             detail: "‘페어링’을 누르면 Mac에 Bluetooth 페어링 요청 창이 뜹니다. 카메라 화면의 코드를 입력하면 Wi-Fi 암호를 받아 바로 연결합니다.")

                        Divider()

                        HStack {
                            Text("찾은 카메라").font(.subheadline.bold())
                            Spacer()
                            if ble.isScanning {
                                ProgressView().controlSize(.small)
                                Button("중지") { ble.stopScan() }
                            } else {
                                Button("카메라 찾기") {
                                    Task {
                                        do { try await ble.startScan() }
                                        catch { connection.state = .failed(error.localizedDescription) }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        if ble.found.isEmpty {
                            Text(ble.isScanning ? "찾는 중… 카메라가 페어링 대기 화면인지 확인하세요." : "아직 찾은 카메라가 없습니다.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(ble.found) { camera in
                            HStack {
                                Image(systemName: "camera").foregroundStyle(.green)
                                Text(camera.name)
                                if connection.cameras.contains(where: { $0.id == camera.id }) {
                                    Badge(text: "등록됨", color: .green)
                                }
                                Text("\(camera.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("페어링") { Task { await connection.pair(camera) } }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

/// Camera settings (색감·노출·파일) in a sheet, from the camera tab and the remote view.
struct CameraSettingsSheet: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("카메라 설정").font(.headline)
                Spacer()
                Button("완료", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            SettingsView()
        }
        .frame(width: 560, height: 680)
    }
}

struct Step: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold()).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.green))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PairingProgress: View {
    let message: String
    let onCancel: () -> Void

    var body: some View {
        GroupBox {
            VStack(spacing: 14) {
                ProgressView()
                Text(message).multilineTextAlignment(.center)
                Label("코드 입력 창이 안 보이면 다른 창 뒤에 있을 수 있습니다. 카메라는 페어링 화면을 유지하세요.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Button("취소", action: onCancel)
            }
            .padding(16)
        }
    }
}
