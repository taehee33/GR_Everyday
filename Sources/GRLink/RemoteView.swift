import SwiftUI

/// Reads the camera's M-JPEG live view (/v1/liveview) and publishes each frame.
final class LiveViewStream: NSObject, ObservableObject, URLSessionDataDelegate {
    @MainActor @Published var frame: NSImage?
    @MainActor @Published var error: String?

    private var session: URLSession?
    private var buffer = Data()

    @MainActor func start() {
        stop()
        error = nil
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session?.dataTask(with: CameraAPI.liveViewURL()).resume()
    }

    @MainActor func stop() {
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        // Frames are JPEGs separated by multipart headers: cut from SOI (FFD8) to EOI (FFD9).
        var latest: Data?
        while let soi = buffer.range(of: Data([0xFF, 0xD8])),
              let eoi = buffer.range(of: Data([0xFF, 0xD9]), in: soi.upperBound..<buffer.endIndex) {
            latest = buffer.subdata(in: soi.lowerBound..<eoi.upperBound)
            buffer.removeSubrange(buffer.startIndex..<eoi.upperBound)
        }
        if buffer.count > 4 << 20 { buffer.removeAll() }
        if let latest, let image = NSImage(data: latest) {
            Task { @MainActor in self.frame = image }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in self.error = "라이브뷰 끊김: \(error.localizedDescription)" }
    }
}

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
                            RoundedRectangle(cornerRadius: 4).stroke(.green, lineWidth: 2)
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

    private var cameraReachable: Bool { connection.state == .connected }

    private var disconnectedOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 44))
                Text("카메라 연결 끊김").font(.title2.bold())
                Text(connection.state == .lost
                     ? (connection.cameraWLANOff
                        ? "카메라 WLAN(Wi-Fi)이 꺼졌습니다.\n휴대폰의 GR WORLD를 다시 열어 WLAN을 켜면 자동으로 다시 연결합니다.\n휴대폰 화면이 잠기면 카메라가 WLAN을 끕니다."
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
    static func shutter(_ tv: String) -> String {
        let parts = tv.split(separator: ".")
        guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), d > 0 else { return tv }
        if d == 1 { return "\(n)\"" }
        if d == 10 { return "\(n / 10).\(n % 10)\"" }
        if n == 1 { return "1/\(d)" }
        return "\(n)/\(d)"
    }

    private func loadProps() async {
        props = (try? await CameraAPI.props()) ?? [:]
    }

    private func fittedRect(_ image: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func tapFocus(_ loc: CGPoint, fitted: CGRect) {
        guard fitted.contains(loc) else { return }
        let p = CGPoint(x: (loc.x - fitted.minX) / fitted.width, y: (loc.y - fitted.minY) / fitted.height)
        focusPoint = p
        Task {
            do {
                try await CameraAPI.focus(x: Int(p.x * 100), y: Int(p.y * 100))
                status = "초점 맞춤"
            } catch {
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

struct GridOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3, y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
