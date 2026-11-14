import SwiftUI

/// The 카메라 tab: registered cameras, connecting, and registering a new one over Bluetooth.
struct CameraScreen: View {
    @EnvironmentObject var connection: ConnectionModel
    /// Switches to the 라이브러리 tab.
    var openLibrary: () -> Void = {}
    /// Opens the shooting screen; nil where there is none to open (the sheet over it).
    var openShoot: (() -> Void)? = nil
    /// Opens 이미지 컨트롤 (the card's photos by image control).
    var openTones: (() -> Void)? = nil
    @State private var registering = false
    @State private var removing: SavedCamera?

    var body: some View {
        List {
            if connection.cameras.isEmpty {
                Section { newCamera }
            } else {
                ForEach(connection.cameras) { camera in
                    cameraSection(camera)
                }
            }
            statusSection
            shortcuts
            if connection.isConnected { connectedSection }
            Section {
                Button {
                    Task { await connection.connectDirect() }
                } label: {
                    Label("이미 카메라 Wi-Fi에 연결돼 있어요", systemImage: "wifi")
                }
                .disabled(connection.isBusy || connection.isConnected)
                // Always tappable: the first tap asks iOS for access, and only then can
                // a camera on the cable be seen.
                Button {
                    Task { await connection.connectUSB() }
                } label: {
                    Label(connection.usb.detected == nil ? "USB로 연결" : "USB로 연결 · \(connection.usb.detected?.name ?? "GR")",
                          systemImage: "cable.connector")
                }
                .disabled(connection.isBusy || connection.viaUSB)
            } header: {
                Text("다른 연결 방법")
            } footer: {
                Text("설정 앱에서 카메라 Wi-Fi(GR_…)에 직접 붙었을 때, 또는 케이블로 연결했을 때 써요. USB로는 사진 보기와 저장만 돼요.")
            }
        }
        .readableWidth()
        // No title on screen (the tab says 카메라); kept for the back button of the
        // shooting screen.
        .navigationTitle("카메라")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            ToolbarItem(placement: .primaryAction) {
                Button { registering = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("카메라 등록")
                    .disabled(connection.isBusy)
            }
        }
        .sheet(isPresented: $registering) { RegisterSheet(ble: connection.ble) }
        // "…을(를) 등록했어요" pops up at the top and goes away by itself.
        .overlay(alignment: .top) {
            if let notice = connection.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.green.gradient, in: Capsule())
                    .shadow(radius: 8, y: 4)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { if connection.notice == notice { connection.notice = nil } }
                    }
            }
        }
        .animation(.snappy, value: connection.notice)
        .confirmationDialog("‘\(removing?.displayName ?? "")’ 카메라를 지울까요?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("지우기", role: .destructive) { if let c = removing { connection.remove(c.id) } }
        } message: {
            Text("저장된 Wi-Fi 암호도 지워져요. 다시 쓰려면 새로 등록해야 해요.")
        }
    }

    /// No camera yet: a picture of one, the three steps, and the button.
    private var newCamera: some View {
        VStack(spacing: 18) {
            GRDrawing()
                .frame(height: 140)
                .opacity(0.55)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 6, y: 12)
                }
            VStack(spacing: 4) {
                Text("카메라를 등록해 주세요").font(.title3.bold())
                Text("한 번 등록하면 다음부터는 버튼 하나로 연결돼요.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                step(1, "dot.radiowaves.left.and.right", "카메라에서 메뉴 → 무선 통신 설정 → Bluetooth → 페어링")
                step(2, "magnifyingglass", "아래 버튼을 누르고 목록에 나온 카메라 선택")
                step(3, "number", "카메라 화면에 나온 코드를 입력")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                registering = true
            } label: {
                // An HStack, not a Label: inside a List a Label keeps room for its icon
                // column, which pushed the title off centre.
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("카메라 등록")
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .padding(.vertical, 12)
    }

    private func step(_ n: Int, _ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").font(.caption.bold()).frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            Text(text).font(.subheadline)
        }
    }

    /// Big tiles to the shooting screen and 이미지 컨트롤, there with or without a camera.
    @ViewBuilder private var shortcuts: some View {
        if let openShoot {
            Section {
                HStack(spacing: 12) {
                    tile("원격 촬영", "camera.aperture",
                         note: connection.isConnected && !connection.viaUSB ? "라이브뷰 보기" : "연결하면 쓸 수 있어요",
                         action: openShoot)
                    if let openTones {
                        tile("이미지 컨트롤", "camera.filters", note: "이미지 컨트롤별 사진", action: openTones)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    private func tile(_ title: String, _ icon: String, note: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func cameraSection(_ camera: SavedCamera) -> some View {
        Section {
            CameraRows(camera: camera, ble: connection.ble,
                       repair: { Task { await connection.repair(camera) } },
                       remove: { removing = camera })
        } header: {
            Text("My GR")
        }
    }

    /// Pairing and failures. Connecting a registered camera shows its progress in the
    /// camera card instead.
    private var showsStatus: Bool {
        switch connection.state {
        case .pairing, .failed: return true
        case .waking, .joining, .lost: return connection.cameras.isEmpty
        case .connected, .disconnected: return false
        }
    }

    @ViewBuilder private var statusSection: some View {
        if showsStatus, let message = connection.state.message {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    if connection.isBusy || connection.state == .lost {
                        ProgressView()
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(message).font(.callout)
                }
                if connection.isBusy {
                    Button("취소") { connection.cancelBluetooth() }
                }
            }
        }
    }

    private var connectedSection: some View {
        Section("카메라 정보") {
            LabeledContent("모델", value: connection.model)
            if let battery = connection.batteryText { LabeledContent("배터리", value: battery) }
            if let firmware = connection.props["firmwareVersion"] as? String { LabeledContent("펌웨어", value: firmware) }
            ForEach(connection.storages, id: \.self) { storage in
                LabeledContent(storage.name == "in" ? "내장 메모리" : storage.name.uppercased(),
                               value: [storage.files.map { "\($0)개" }, storage.remain.map { "남은 \($0)장" }]
                                   .compactMap { $0 }.joined(separator: " · "))
            }
            Button("라이브러리 열기", action: openLibrary)
            if connection.connectedCameraID == nil {
                Button("연결 끊기", role: .destructive) { Task { await connection.disconnect() } }
            }
        }
    }
}

/// Top of 라이브러리: which camera, whether it is connected, and the one button that matters
/// now. Tapping the card goes to the 카메라 tab.
struct CameraStatusCard: View {
    @EnvironmentObject var connection: ConnectionModel
    @ObservedObject var ble: BLEWaker
    let openCamera: () -> Void
    @State private var registering = false

    /// The camera to reconnect: the one on Wi-Fi, else the last one used.
    private var camera: SavedCamera? {
        if let id = connection.connectedCameraID, let c = connection.cameras.first(where: { $0.id == id }) { return c }
        return connection.cameras.max { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: connection.viaUSB ? "cable.connector" : "camera.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(dot).frame(width: 7, height: 7).padding(.top, 4)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture(perform: openCamera)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $registering) { RegisterSheet(ble: ble) }
    }

    private var title: String {
        if connection.viaUSB { return connection.model }
        if let camera { return camera.displayName }
        return "카메라를 연결해 주세요"
    }

    private var subtitle: String {
        if let message = connection.state.message { return message }
        if connection.isConnected {
            return [connection.viaUSB ? "USB로 연결됨" : "연결됨", connection.batteryText.map { "배터리 \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if camera == nil { return "카메라를 한 번 등록하면 다음부터는 버튼 하나로 연결돼요." }
        if ble.linkedCameraID == camera?.id { return "Bluetooth 연결됨 · Wi-Fi를 켜면 사진을 볼 수 있어요" }
        if let last = camera?.lastConnected { return "마지막 연결 \(last.formatted(.relative(presentation: .named)))" }
        return "연결 안 됨"
    }

    private var dot: Color {
        switch connection.state {
        case .connected: return .green
        case .lost, .pairing, .waking, .joining: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    @ViewBuilder private var action: some View {
        if connection.isBusy {
            Button("취소") { connection.cancelBluetooth() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
        } else if connection.isConnected || connection.state == .lost {
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        } else if let camera {
            Button(connection.state == .disconnected ? "연결" : "다시 연결") {
                Task { await connection.connect(camera) }
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .disabled(connection.bluetoothBusy)
        } else {
            Button("등록") { registering = true }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }
}

/// Find cameras in pairing mode and register one: iOS asks for the code shown on the camera.
struct RegisterSheet: View {
    @EnvironmentObject var connection: ConnectionModel
    /// Observed directly so the list updates as cameras appear.
    @ObservedObject var ble: BLEWaker
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("카메라에서 메뉴 → 무선 통신 설정 → Bluetooth → 페어링을 열어 두세요. 아래에 카메라가 나타나면 누르고, 뜨는 창에 카메라 화면의 코드를 입력해 주세요.")
                        .font(.callout)
                }
                Section {
                    if ble.found.isEmpty {
                        HStack { ProgressView(); Text("카메라를 찾고 있어요…").foregroundStyle(.secondary) }
                    }
                    ForEach(ble.found) { camera in
                        Button {
                            ble.stopScan()
                            dismiss()
                            Task { await connection.pair(camera) }
                        } label: {
                            Label(camera.name, systemImage: "camera")
                        }
                    }
                } header: {
                    Text("주변 카메라")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("카메라 등록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .task {
                do { try await ble.startScan() } catch { self.error = error.localizedDescription }
            }
            .onDisappear { ble.stopScan() }
        }
    }
}

/// One registered camera: name, then Bluetooth and Wi-Fi as separate connections, as in
/// GR WORLD. Bluetooth keeps a link to the camera; Wi-Fi switches the camera's Wi-Fi on over
/// it and joins, for photos and remote shooting.
struct CameraRows: View {
    @EnvironmentObject var connection: ConnectionModel
    let camera: SavedCamera
    /// Observed directly so the Bluetooth row follows the link.
    @ObservedObject var ble: BLEWaker
    let repair: () -> Void
    let remove: () -> Void

    @State private var showWiFiInfo = false
    @AppStorage("cameraLinkDetails") private var showDetails = false

    private var linked: Bool { ble.linkedCameraID == camera.id }
    private var onWiFi: Bool {
        connection.connectedCameraID == camera.id && (connection.isConnected || connection.state == .lost)
    }

    var body: some View {
        VStack(spacing: 12) {
            GRCameraPicture()
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
                .overlay(alignment: .topTrailing) { manageMenu }
            VStack(spacing: 2) {
                Text(camera.displayName).font(.title3.bold())
                // Not twice when the name is the model ("RICOH GR" before the first Wi-Fi link).
                if let model = camera.shortModel ?? (camera.displayName == "RICOH GR" ? nil : "RICOH GR"),
                   model != camera.displayName {
                    Text(model).font(.subheadline).foregroundStyle(.secondary)
                }
                if !onWiFi, !linked, let last = camera.lastConnected {
                    Text("마지막 연결 \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 8)

        connectRow

        if showDetails {
            bluetoothRow
            wifiRow
        }
    }

    /// ⓘ in the card's top-right corner: the camera's Bluetooth name, then 다시 페어링 and
    /// 카메라 지우기.
    private var manageMenu: some View {
        Menu {
            Section(camera.bleName) {
                Button(action: repair) {
                    Label("다시 페어링", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(connection.isBusy)
                Button(role: .destructive, action: remove) {
                    Label("카메라 지우기", systemImage: "trash")
                }
                .disabled(connection.isBusy)
            }
        } label: {
            Image(systemName: "info.circle").font(.title3)
        }
        .accessibilityLabel("카메라 정보")
    }

    /// One line: where each link stands, and one button that brings up whatever is missing
    /// (Bluetooth first if needed, then the camera's Wi-Fi). 자세히 shows each link on its own.
    private var connectRow: some View {
        VStack(spacing: 10) {
            // The two links centred; ⋯ on the right opens each link on its own.
            HStack(spacing: 8) {
                linkPill("Bluetooth", icon: "dot.radiowaves.left.and.right", state: bluetoothState)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                linkPill("Wi-Fi", icon: "wifi", state: wifiState)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Button {
                    withAnimation(.snappy) { showDetails.toggle() }
                } label: {
                    Image(systemName: showDetails ? "ellipsis.circle.fill" : "ellipsis.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showDetails ? "자세히 닫기" : "자세히")
            }
            if let message = progressMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            Group {
                if onWiFi {
                    Button(role: .destructive) { Task { await connection.disconnect() } } label: {
                        Text("연결 끊기").frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                } else if working {
                    Button { connection.cancelBluetooth() } label: {
                        HStack(spacing: 8) { ProgressView(); Text("연결하는 중… 취소") }
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { Task { await connection.connect(camera) } } label: {
                        Text(linked ? "Wi-Fi 연결" : "연결").font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(connection.isBusy || connection.bluetoothBusy)
                }
            }
            .buttonBorderShape(.capsule)
        }
        .padding(.bottom, 4)
        .listRowSeparator(.hidden, edges: .top)
        // Sit close under the camera name rather than a full row gap below it.
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
    }

    private enum LinkState { case off, working, on }

    /// This camera is the one connecting right now.
    private var working: Bool {
        connection.isBusy && (connection.selectedCameraID == camera.id || connection.connectedCameraID == camera.id
                              || connection.cameras.count == 1)
    }

    private var bluetoothState: LinkState {
        if linked { return .on }
        if connection.bluetoothBusy { return .working }
        if working, case .waking = connection.state { return .working }
        return .off
    }

    private var wifiState: LinkState {
        if onWiFi { return connection.state == .lost ? .working : .on }
        if working, case .joining = connection.state { return .working }
        return .off
    }

    private var progressMessage: String? {
        guard working || connection.state == .lost else { return nil }
        return connection.state.message
    }

    private func linkPill(_ title: String, icon: String, state: LinkState) -> some View {
        let color: Color = state == .on ? .green : state == .working ? .orange : .secondary
        return HStack(spacing: 5) {
            if state == .working {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: icon).font(.caption)
            }
            Text(title).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
        .accessibilityLabel("\(title) \(state == .on ? "연결됨" : state == .working ? "연결 중" : "연결 안 됨")")
    }

    private var bluetoothRow: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bluetooth")
                    Text(linked ? "연결됨" + (ble.batteryText.map { " · 배터리 \($0)" } ?? "") : "연결 안 됨")
                        .font(.caption).foregroundStyle(linked ? .green : .secondary)
                }
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(linked ? .green : .secondary)
            }
            Spacer()
            if connection.bluetoothBusy {
                ProgressView()
            } else if linked {
                Button("끊기") { connection.disconnectBluetooth() }.buttonStyle(.bordered)
            } else {
                Button("연결") { Task { await connection.connectBluetooth(camera) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(connection.isBusy)
            }
        }

    }

    private var wifiRow: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Wi-Fi")
                    Text(onWiFi ? connection.route.replacingOccurrences(of: "Wi-Fi · ", with: "") + " 연결됨"
                                : (linked ? "Bluetooth로 켤 수 있어요" : "연결 안 됨"))
                        .font(.caption).foregroundStyle(onWiFi ? .green : .secondary)
                }
            } icon: {
                Image(systemName: "wifi").foregroundStyle(onWiFi ? .green : .secondary)
            }
            if camera.credentials != nil {
                Button { showWiFiInfo = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Wi-Fi 이름과 암호 보기")
            }
            Spacer()
            if onWiFi {
                Button("끊기") { Task { await connection.disconnect() } }.buttonStyle(.bordered)
            } else {
                Button("연결") { Task { await connection.connect(camera) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(connection.isBusy || connection.bluetoothBusy)
            }
        }
        .sheet(isPresented: $showWiFiInfo) {
            if let credentials = camera.credentials { WiFiInfoSheet(credentials: credentials) }
        }
    }
}

/// The camera's Wi-Fi name and password, for joining it from the Settings app.
struct WiFiInfoSheet: View {
    let credentials: WLANCredentials
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("이름", credentials.ssid)
                    row("암호", credentials.passphrase)
                } footer: {
                    Text("설정 앱 → Wi-Fi에서 직접 연결할 때 쓰세요. 카메라를 등록할 때 Bluetooth로 받아 둔 값이에요.")
                }
            }
            .navigationTitle("카메라 Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.monospaced()).textSelection(.enabled)
            }
            Spacer()
            Button(copied == title ? "복사했어요" : "복사") {
                UIPasteboard.general.string = value
                copied = title
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}
