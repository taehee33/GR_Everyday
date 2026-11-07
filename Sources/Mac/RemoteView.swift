import SwiftUI

/// Reads the camera's M-JPEG live view (/v1/liveview) and publishes each frame.
struct RemoteView: View {
    @StateObject private var live = LiveViewStream()
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var connection: ConnectionModel
    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("timer") private var timer = 0
    @State private var countdown: Int?
    @State private var shootTask: Task<Void, Never>?
    @State private var status: String?
    @State private var focusPoint: CGPoint?
    /// The camera's answer for the last tap: nil while it is still focusing.
    @State private var focusHit: Bool?
    @State private var focusTask: Task<Void, Never>?
    @State private var props: [String: Any] = [:]
    @State private var showCameraSettings = false
    @State private var busyParam: String?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let frame = live.frame {
                        let fitted = fittedRect(frame.size, in: geo.size)
                        Image(nsImage: frame).resizable().aspectRatio(contentMode: .fit)
                        if showGrid { GridOverlay().frame(width: fitted.width, height: fitted.height) }
                        if let p = focusPoint {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(focusHit.map { $0 ? Color.green : Color.orange } ?? .white, lineWidth: 2)
                                .frame(width: 60, height: 60)
                                .position(x: fitted.minX + p.x * fitted.width, y: fitted.minY + p.y * fitted.height)
                        }
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .local) { loc in tapFocus(loc, fitted: fitted) }
                    } else {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(live.error ?? "라이브뷰 연결 중…").foregroundStyle(.secondary)
                            if live.error != nil { Button("다시 시도") { live.start() } }
                        }
                    }
                    if let countdown {
                        Text("\(countdown)").font(.system(size: 120, weight: .bold)).foregroundStyle(.white).shadow(radius: 8)
                    }
                }
            }
            .overlay { if !cameraReachable { disconnectedOverlay } }
            controls
        }
        // The live view stream dies with the link; start it again when the camera is back.
        .onChange(of: connection.state) { _, state in
            if state == .connected { live.start(); Task { await loadProps() } }
        }
        .sheet(isPresented: $showCameraSettings, onDismiss: { Task { await loadProps() } }) {
            CameraSettingsSheet { showCameraSettings = false }
        }
        .onAppear { live.start(); Task { await loadProps() } }
        .onDisappear { live.stop(); shootTask?.cancel() }
    }

    /// Over USB the camera offers its files only, no live view or shutter.
    private var cameraReachable: Bool { connection.state == .connected && !connection.viaUSB }

    private var disconnectedOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 44))
                Text(connection.viaUSB ? "USB 연결에서는 원격 촬영을 쓸 수 없습니다" : "카메라 연결 끊김").font(.title2.bold())
                Text(connection.viaUSB ? "카메라가 USB로는 사진 파일만 제공합니다. 원격 촬영은 Wi-Fi로 연결하세요."
                     : connection.state == .lost
                     ? (connection.cameraWLANOff
                        ? "카메라 WLAN(Wi-Fi)이 꺼졌습니다.\n휴대폰의 GR WORLD를 다시 열어 WLAN을 켜면 자동으로 다시 연결합니다.\n연결된 뒤 휴대폰 Bluetooth를 끄면 휴대폰을 잠가도 유지됩니다."
                        : "카메라 Wi-Fi 응답이 없습니다. 다시 연결을 시도하는 중입니다…\n카메라 전원과 Wi-Fi가 켜져 있는지 확인하세요.")
                     : "카메라 탭에서 다시 연결하세요.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                if connection.state == .lost { ProgressView().controlSize(.small) }
            }
            .foregroundStyle(.white)
        }
    }

    /// Settings on the left, shutter in the middle, guide and timer on the right.
    private var controls: some View {
        HStack(spacing: 16) {
            HStack(spacing: 16) {
                Button {
                    showCameraSettings = true
                } label: {
                    Label("카메라 설정", systemImage: "slider.horizontal.3")
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                .help("색감·노출·파일 형식 (⇧⌘,)")
                paramMenu("effect", icon: "camera.filters")
                Divider().frame(height: 18)
                paramMenu("tv")
                paramMenu("av")
                paramMenu("sv")
                paramMenu("xv")
                if let status { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!cameraReachable)

            Button {
                shoot()
            } label: {
                Image(systemName: "circle.inset.filled").font(.system(size: 40))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(countdown != nil || !cameraReachable)
            .opacity(cameraReachable ? 1 : 0.3)
            .help(cameraReachable ? "셔터 (스페이스)" : "카메라에 연결되지 않았습니다")

            HStack(spacing: 16) {
                if countdown != nil {
                    Button("취소") { shootTask?.cancel(); countdown = nil }
                }
                Toggle("구도 가이드", isOn: $showGrid).toggleStyle(.switch).controlSize(.small)
                Picker("타이머", selection: $timer) {
                    Text("즉시").tag(0); Text("2초").tag(2); Text("5초").tag(5); Text("10초").tag(10)
                }
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
    }

    /// The values shown under the live view, each a menu of what the camera allows now
    /// (<key>List in /v1/props; it changes with the exposure mode).
    private func paramMenu(_ key: String, icon: String? = nil) -> some View {
        let options = (props[key + "List"] as? [Any] ?? []).map { "\($0)" }
        let current = props[key].map { "\($0)" }
        return Menu {
            ForEach(options, id: \.self) { value in
                Button {
                    Task { await setParam(key, value) }
                } label: {
                    if value == current { Label(Self.paramText(key, value), systemImage: "checkmark") }
                    else { Text(Self.paramText(key, value)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                Text(current.map { Self.paramText(key, $0) } ?? "-").font(.callout.monospaced())
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(options.isEmpty || busyParam != nil)
        .help(options.isEmpty ? SettingsView.lockedReason(key, props: props)
                              : "\(SettingsView.labels[key] ?? key) 바꾸기")
    }

    private static func paramText(_ key: String, _ value: String) -> String {
        switch key {
        case "sv": return value == "auto" ? "ISO 자동" : "ISO \(value)"
        case "xv": return "\(value) EV"
        default: return SettingsView.display(key, value)
        }
    }

    private func setParam(_ key: String, _ value: String) async {
        busyParam = key
        defer { busyParam = nil }
        do {
            try await CameraAPI.setParams([key: value])
            status = "\(SettingsView.labels[key] ?? key): \(Self.paramText(key, value))"
        } catch {
            status = "\(SettingsView.labels[key] ?? key) 변경 실패: \(error.localizedDescription)"
        }
        await loadProps()
    }

    /// The camera sends a fraction "numerator.denominator":
    /// "1.250" → "1/250", "2.1" → "2\"", "3.10" → "0.3\"", "25.10" → "2.5\"".
    private func loadProps() async {
        props = (try? await CameraAPI.props()) ?? [:]
    }

    private func fittedRect(_ image: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Focus methods where the camera doesn't autofocus, so a tap can't move the focus.
    private static let fixedFocus = ["manual": "수동(MF)", "snap": "스냅", "inf": "∞"]

    private func tapFocus(_ loc: CGPoint, fitted: CGRect) {
        guard fitted.contains(loc) else { return }
        if let setting = props["focusSetting"] as? String, let name = Self.fixedFocus[setting] {
            focusPoint = nil
            status = "초점 방식이 \(name)이라 눌러서 초점을 맞출 수 없습니다. 카메라 설정에서 초점 방식을 바꾸세요."
            return
        }
        let p = CGPoint(x: (loc.x - fitted.minX) / fitted.width, y: (loc.y - fitted.minY) / fitted.height)
        focusPoint = p
        focusHit = nil
        status = "초점 맞추는 중…"
        focusTask?.cancel()
        focusTask = Task {
            do {
                try await CameraAPI.focus(x: Int(p.x * 100), y: Int(p.y * 100))
                // The POST answers before the lens settles; the camera reports the result
                // in props.focused (verified on the GR IV HDF, fw 1.20).
                var hit = false
                for _ in 0..<6 {
                    try await Task.sleep(for: .milliseconds(250))
                    if (try await CameraAPI.props())["focused"] as? Bool == true { hit = true; break }
                }
                focusHit = hit
                status = hit ? "초점 맞음" : "초점을 맞추지 못했습니다. 너무 가까우면 카메라를 매크로 모드로 바꾸세요."
            } catch is CancellationError {
            } catch {
                focusHit = false
                status = "초점 실패: \(error.localizedDescription)"
            }
        }
    }

    private func shoot() {
        shootTask = Task {
            for remaining in stride(from: timer, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { countdown = nil; return }
            }
            countdown = nil
            do {
                try await CameraAPI.shoot()
                status = "촬영됨 — 카메라에 저장"
                await library.reload()
                await loadProps()
            } catch {
                status = "촬영 실패: \(error.localizedDescription)"
            }
        }
    }
}
