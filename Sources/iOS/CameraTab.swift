import SwiftUI

/// Registered cameras, connecting, and registering a new one over Bluetooth.
struct CameraTab: View {
    @EnvironmentObject var connection: ConnectionModel
    @Binding var section: Pane
    @State private var registering = false
    @State private var removing: SavedCamera?

    var body: some View {
        NavigationStack {
            List {
                if connection.cameras.isEmpty {
                    Section {
                        Label("카메라 메뉴 → 무선 통신 설정 → Bluetooth → 페어링을 연 뒤 아래 버튼을 누르세요.",
                              systemImage: "dot.radiowaves.left.and.right")
                        Button("카메라 등록") { registering = true }
                    } header: {
                        Text("등록된 카메라 없음")
                    }
                } else {
                    ForEach(connection.cameras) { camera in
                        cameraSection(camera)
                    }
                }
                statusSection
                if connection.isConnected { connectedSection }
                Section {
                    Button("이미 카메라 Wi-Fi에 연결됨") { Task { await connection.connectDirect() } }
                        .disabled(connection.isBusy || connection.isConnected)
                } footer: {
                    Text("설정 앱에서 카메라 Wi-Fi(GR_…)에 직접 연결했다면 누르세요.")
                }
                Section {
                    // Always tappable: the first tap asks iOS for access, and only then can
                    // a camera on the cable be seen.
                    Button {
                        Task { await connection.connectUSB() }
                    } label: {
                        Label(connection.usb.detected == nil ? "USB로 연결" : "USB로 연결 · \(connection.usb.detected?.name ?? "GR")",
                              systemImage: "cable.connector")
                    }
                    .disabled(connection.isBusy || connection.viaUSB)
                } footer: {
                    Text("카메라를 USB 카메라 어댑터(라이트닝 iPhone) 또는 USB-C 케이블로 연결하고 켠 뒤 누르세요. USB로는 사진 보기·저장만 되고, 원격 촬영과 카메라 설정은 Wi-Fi에서 됩니다. iPhone의 인터넷은 그대로 쓸 수 있습니다.")
                }
            }
            .navigationTitle("카메라")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { registering = true } label: { Image(systemName: "plus") }
                        .disabled(connection.isBusy)
                }
            }
            .sheet(isPresented: $registering) { RegisterSheet(ble: connection.ble) }
            .confirmationDialog("‘\(removing?.displayName ?? "")’ 카메라 정보를 지울까요?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("지우기", role: .destructive) { if let c = removing { connection.remove(c.id) } }
            } message: {
                Text("저장된 Wi-Fi 암호도 지워집니다. 다시 쓰려면 새로 등록해야 합니다.")
            }
        }
    }

    private func cameraSection(_ camera: SavedCamera) -> some View {
        Section {
            CameraRows(camera: camera, ble: connection.ble)
        } footer: {
            HStack {
                Button("다시 페어링") { Task { await connection.repair(camera) } }
                Spacer()
                Button("지우기", role: .destructive) { removing = camera }
            }
            .font(.footnote)
            .disabled(connection.isBusy)
        }
    }

    @ViewBuilder private var statusSection: some View {
        if let message = connection.state.message {
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
        } else if let notice = connection.notice {
            Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green) }
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
            Button("라이브러리 열기") { section = .library }
            if connection.connectedCameraID == nil {
                Button("연결 끊기", role: .destructive) { Task { await connection.disconnect() } }
            }
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
                    Text("카메라에서 메뉴 → 무선 통신 설정 → Bluetooth → 페어링을 열어 두세요. 아래에 카메라가 나타나면 누르고, iPhone에 뜨는 창에 카메라 화면의 코드를 입력하세요.")
                        .font(.callout)
                }
                Section {
                    if ble.found.isEmpty {
                        HStack { ProgressView(); Text("카메라를 찾는 중…").foregroundStyle(.secondary) }
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

    private var linked: Bool { ble.linkedCameraID == camera.id }
    private var onWiFi: Bool {
        connection.connectedCameraID == camera.id && (connection.isConnected || connection.state == .lost)
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.title).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(camera.displayName).font(.headline)
                Text(camera.shortModel ?? "RICOH GR").font(.subheadline).foregroundStyle(.secondary)
                if !onWiFi, !linked, let last = camera.lastConnected {
                    Text("마지막 연결 \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)

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

        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Wi-Fi")
                    Text(onWiFi ? connection.route.replacingOccurrences(of: "Wi-Fi · ", with: "") + " 연결됨"
                                : (linked ? "Bluetooth로 켤 수 있음" : "연결 안 됨"))
                        .font(.caption).foregroundStyle(onWiFi ? .green : .secondary)
                }
            } icon: {
                Image(systemName: "wifi").foregroundStyle(onWiFi ? .green : .secondary)
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
    }
}
