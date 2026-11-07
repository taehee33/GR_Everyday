import SwiftUI

/// Live view, tap to focus, shutter with a self-timer, and the camera's settings.
struct RemoteTab: View {
    /// The tab is on screen. Tabs stay loaded, and starting the live view puts the camera
    /// into remote shooting, so it runs only while this tab is shown.
    let active: Bool
    @EnvironmentObject var connection: ConnectionModel
    @EnvironmentObject var library: LibraryModel
    @StateObject private var live = LiveViewStream()
    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("timer") private var timer = 0
    @State private var props: [String: Any] = [:]
    @State private var status: String?
    @State private var focusPoint: CGPoint?
    @State private var focusHit: Bool?
    @State private var focusTask: Task<Void, Never>?
    @State private var shootTask: Task<Void, Never>?
    @State private var countdown: Int?
    @State private var showSettings = false

    /// Focus methods where the camera doesn't autofocus, so a tap can't move the focus.
    private static let fixedFocus = ["manual": "수동(MF)", "snap": "스냅", "inf": "∞"]

    var body: some View {
        NavigationStack {
            Group {
                if connection.isConnected || connection.state == .lost {
                    VStack(spacing: 0) {
                        liveView
                        controls
                    }
                    .background(.black)
                } else {
                    ContentUnavailableView("카메라에 연결되지 않음", systemImage: "camera.aperture",
                                           description: Text("원격 촬영은 카메라 Wi-Fi로 연결해야 쓸 수 있습니다."))
                }
            }
            .navigationTitle("원격 촬영")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .disabled(!connection.isConnected)
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await loadProps() } }) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("카메라 설정")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { showSettings = false } } }
                }
            }
        }
        .onChange(of: active, initial: true) { _, active in
            if active, connection.isConnected { live.start(); Task { await loadProps() } }
            if !active { live.stop(); shootTask?.cancel() }
        }
        .onChange(of: connection.state) { _, state in
            if state == .connected, active { live.start(); Task { await loadProps() } }
        }
    }

    private var liveView: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let frame = live.frame {
                    let fitted = fittedRect(frame.size, in: geo.size)
                    Image(platformImage: frame).resizable().aspectRatio(contentMode: .fit)
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
                        ProgressView().tint(.white)
                        Text(live.error ?? "라이브뷰 연결 중…").foregroundStyle(.secondary)
                        if live.error != nil { Button("다시 시도") { live.start() } }
                    }
                }
                if let countdown {
                    Text("\(countdown)").font(.system(size: 100, weight: .bold)).foregroundStyle(.white).shadow(radius: 8)
                }
                if connection.state == .lost {
                    Label("카메라 연결 끊김 — 다시 연결하는 중…", systemImage: "wifi.exclamationmark")
                        .padding(10).background(.ultraThinMaterial, in: Capsule())
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 14) {
                exposureText
                Spacer()
            }
            HStack {
                Toggle(isOn: $showGrid) { Image(systemName: "grid") }
                    .toggleStyle(.button)
                Spacer()
                Button(action: shoot) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 66, height: 66)
                        Circle().fill(.white).frame(width: 54, height: 54)
                    }
                }
                .disabled(!connection.isConnected || countdown != nil)
                Spacer()
                Picker("타이머", selection: $timer) {
                    Text("즉시").tag(0)
                    Text("2초").tag(2)
                    Text("5초").tag(5)
                    Text("10초").tag(10)
                }
                .pickerStyle(.menu)
            }
        }
        .padding()
        .foregroundStyle(.white)
        .tint(.white)
        .background(Color(white: 0.08))
    }

    private var exposureText: some View {
        let parts: [String] = [
            (props["effect"] as? String).map { SettingsView.display("effect", $0) },
            (props["tv"] as? String).map { SettingsView.shutter($0) },
            (props["av"] as? String).map { "F\($0)" },
            (props["sv"] as? String).map { "ISO \($0)" },
            (props["xv"] as? String).map { "\($0) EV" },
        ].compactMap { $0 }
        return Text(parts.joined(separator: "  ")).font(.caption.monospaced()).foregroundStyle(.secondary)
    }

    private func fittedRect(_ image: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func loadProps() async {
        props = (try? await CameraAPI.props()) ?? [:]
    }

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
                let verdict = try await CameraAPI.focus(x: Int(p.x * 100), y: Int(p.y * 100))
                let hit = verdict ?? true
                // A newer tap replaced this one: leave the box and message to it.
                guard !Task.isCancelled else { return }
                focusHit = hit
                status = hit ? "초점 맞춤" : "초점을 맞추지 못했습니다. 너무 가까우면 카메라를 매크로 모드로 바꾸세요."
            } catch {
                // Cancelling also ends the request in flight, which reports URLError.cancelled.
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled, !(error is CancellationError) else { return }
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
