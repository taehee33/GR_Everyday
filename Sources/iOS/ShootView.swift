import SwiftUI

/// Live view, tap to focus, shutter with a self-timer, and the camera's settings. Shown in
/// the 카메라 tab once the camera is on Wi-Fi; the top bar opens the connection screen.
struct ShootView: View {
    /// The tab is on screen. Tabs stay loaded, and starting the live view puts the camera
    /// into remote shooting, so it runs only while this tab is shown.
    let active: Bool
    /// Opens the connection screen (Bluetooth, Wi-Fi, disconnect).
    let manage: () -> Void
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
    /// The setting whose dial is open under the live view.
    @State private var dialKey: String?
    @State private var settingKey: String?

    /// Settings shown under the live view, in the camera's order.
    private static let quickKeys = ["effect", "tv", "av", "sv", "xv", "WBMode"]

    /// Focus methods where the camera doesn't autofocus, so a tap can't move the focus.
    private static let fixedFocus = ["manual": "수동(MF)", "snap": "스냅", "inf": "∞"]

    /// Landscape, full screen: the phone turns sideways and only the photo and the controls
    /// stay. The only other layout is portrait.
    @State private var fullscreen = false

    /// On the camera's Wi-Fi (or briefly lost from it): the live view can run.
    private var ready: Bool { !connection.viaUSB && (connection.isConnected || connection.state == .lost) }

    var body: some View {
        GeometryReader { geo in
            // iPad turns freely: held sideways it gets the side-column layout without the
            // 가로 모드 button (which only exists to turn the iPhone).
            let sideLayout = fullscreen || (Self.isPad && geo.size.width > geo.size.height)
            Group {
                if sideLayout {
                    ZStack {
                        liveView.ignoresSafeArea()
                        // Chips centred on the screen, kept clear of the button column on
                        // both sides so they line up with the photo.
                        VStack { Spacer(); settingsPanel.padding(.horizontal, 96).padding(.bottom, 12) }
                        HStack { Spacer(); buttonColumn }
                    }
                } else {
                    VStack(spacing: 0) {
                        liveView
                        controls.background(Color(white: 0.08))
                    }
                }
            }
            .background(.black)
            .foregroundStyle(.white)
            .tint(.white)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(fullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbar(fullscreen ? .hidden : .visible, for: .tabBar)
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
        .toolbar {
            ToolbarItem(placement: .principal) { cameraBar }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("카메라 설정")
                    .disabled(!connection.isConnected || connection.viaUSB)
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
        .onChange(of: active, initial: true) { _, active in
            if active, ready { live.start(); Task { await loadProps() } }
            if !active { live.stop(); shootTask?.cancel() }
        }
        .onChange(of: connection.state) { _, state in
            if state == .connected, active, !connection.viaUSB { live.start(); Task { await loadProps() } }
            if !ready { setLandscape(false) }
        }
        .onDisappear { live.stop(); shootTask?.cancel(); setLandscape(false) }
    }

    private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Turns the phone sideways into the full-screen layout, or back to portrait.
    private func setLandscape(_ on: Bool) {
        guard on != fullscreen || Orientation.landscape != on else { return }
        withAnimation(.easeInOut(duration: 0.25)) { fullscreen = on }
        Orientation.set(landscape: on)
    }

    private func fade(_ edge: Edge) -> LinearGradient {
        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)],
                       startPoint: edge == .bottom ? .top : .leading, endPoint: edge == .bottom ? .bottom : .trailing)
    }

    /// Camera name, battery and link state; tap for the connection screen.
    private var cameraBar: some View {
        let camera = connection.cameras.first { $0.id == connection.connectedCameraID }
        let lost = connection.state == .lost
        return Button(action: manage) {
            HStack(spacing: 6) {
                Circle().fill(!ready ? Color.gray : lost ? Color.orange : .green).frame(width: 7, height: 7)
                Text(ready ? camera?.displayName ?? connection.model : "연결 안 됨").font(.subheadline.weight(.semibold))
                if let battery = connection.batteryText {
                    Text(battery).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(white: 0.15), in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("연결 관리")
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
                } else if !ready {
                    VStack(spacing: 16) {
                        GRDrawing().frame(height: 110).opacity(0.45)
                        Text(connection.viaUSB ? "USB로는 원격 촬영을 할 수 없어요.\n카메라 Wi-Fi로 연결해 주세요."
                                               : "카메라를 Wi-Fi로 연결하면\n여기에 라이브뷰가 보여요.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(action: manage) {
                            Label("연결하러 가기", systemImage: "wifi").padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .tint(.accentColor)
                    }
                    .padding()
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
            .overlay(alignment: .topTrailing) {
                // In landscape the button sits in the right-hand column instead, clear of
                // the rounded corner. iPad rotates by itself, so it has no button.
                if ready && !fullscreen && !Self.isPad {
                    Button {
                        setLandscape(!fullscreen)
                    } label: {
                        Image(systemName: fullscreen ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .padding(12)
                    .accessibilityLabel(fullscreen ? "세로 모드로" : "가로 모드")
                }
            }
        }
    }

    /// Status, the open dial and the setting chips.
    private var settingsPanel: some View {
        VStack(spacing: 10) {
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let key = dialKey { dial(key) }
            quickSettings
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            settingsPanel
            HStack {
                gridToggle
                Spacer()
                shutterButton
                Spacer()
                timerMenu
            }
        }
        .padding()
    }

    /// Landscape full screen: grid, shutter and timer down the right edge.
    private var buttonColumn: some View {
        // Shutter in the vertical middle; the back-to-portrait button pinned at the top.
        VStack(spacing: 28) {
            timerMenu
            shutterButton
            gridToggle
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            if fullscreen {
            Button { setLandscape(false) } label: {
                Image(systemName: "rectangle.portrait.rotate")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel("세로 모드로")
            .padding(.top, 12)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
        .background(fade(.trailing))
    }

    private var gridToggle: some View {
        Toggle(isOn: $showGrid) { Image(systemName: "grid") }
            .toggleStyle(.button)
            .accessibilityLabel("격자")
    }

    private var shutterButton: some View {
        Button(action: shoot) {
            ZStack {
                Circle().stroke(.white, lineWidth: 3).frame(width: 66, height: 66)
                Circle().fill(.white).frame(width: 54, height: 54)
            }
        }
        .disabled(!connection.isConnected || connection.viaUSB || countdown != nil)
        .opacity(ready ? 1 : 0.35)
        .accessibilityLabel("셔터")
    }

    private var timerMenu: some View {
        Menu {
            Picker("셀프타이머", selection: $timer) {
                Text("끄기").tag(0)
                Text("2초").tag(2)
                Text("5초").tag(5)
                Text("10초").tag(10)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer").font(.title3)
                if timer > 0 { Text("\(timer)").font(.subheadline.monospacedDigit().bold()) }
            }
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(timer > 0 ? Color.yellow : .white)
        }
        .accessibilityLabel(timer > 0 ? "셀프타이머 \(timer)초" : "셀프타이머 꺼짐")
    }

    /// Current settings as chips. Ones the camera lets you change open a dial; the rest are
    /// greyed with a lock and say why when tapped.
    private var quickSettings: some View {
        ViewThatFits(in: .horizontal) {
            chipRow
            ScrollView(.horizontal, showsIndicators: false) { chipRow }
        }
    }

    /// The chips in one row; centred by `quickSettings` when they all fit.
    private var chipRow: some View {
            HStack(spacing: 8) {
                ForEach(Self.quickKeys.filter { props[$0] != nil }, id: \.self) { key in
                    let changeable = SettingsView.isChangeable(key, props: props)
                    let open = dialKey == key
                    Button {
                        if changeable {
                            withAnimation(.snappy) { dialKey = open ? nil : key }
                        } else {
                            dialKey = nil
                            status = SettingsView.lockedReason(key, props: props)
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Text(Self.shortLabel(key)).font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 3) {
                                if !changeable { Image(systemName: "lock.fill").font(.system(size: 8)) }
                                Text(value(key)).font(.footnote.monospacedDigit().weight(.semibold)).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(changeable ? (open ? Color.black : .white) : Color(white: 0.45))
                        .background(open ? Color.yellow : Color(white: changeable ? 0.2 : 0.12), in: Capsule())
                        .overlay {
                            if settingKey == key { ProgressView().controlSize(.mini).tint(.yellow) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
    }

    private static func shortLabel(_ key: String) -> String {
        ["effect": "이미지", "tv": "셔터", "av": "조리개", "sv": "ISO", "xv": "노출 보정", "WBMode": "WB"][key] ?? key
    }

    private func value(_ key: String) -> String {
        guard let raw = props[key].map({ "\($0)" }) else { return "-" }
        switch key {
        case "sv": return raw
        case "xv": return raw + " EV"
        default: return SettingsView.display(key, raw)
        }
    }

    /// A strip of values that scrolls like a dial; the one under the yellow mark is applied
    /// when the strip comes to rest. Tapping a value also picks it.
    private func dial(_ key: String) -> some View {
        let options = SettingsView.options(key, props: props)
        return DialStrip(options: options, itemWidth: ["effect": 150, "WBMode": 160][key] ?? 76, label: { value -> String in
            key == "xv" ? value : key == "sv" ? value : SettingsView.display(key, value)
        }, selected: props[key].map { "\($0)" }) { value in
            Task { await set(key, value) }
        }
        .id(key)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func set(_ key: String, _ value: String) async {
        guard props[key].map({ "\($0)" }) != value else { return }
        settingKey = key
        defer { settingKey = nil }
        do {
            try await CameraAPI.setParams([key: value])
            props[key] = value
            status = nil
            DebugLog.write("shoot set \(key)=\(value): ok")
        } catch {
            status = "\(SettingsView.labels[key] ?? key) 변경 실패: \(error.localizedDescription)"
            DebugLog.write("shoot set \(key)=\(value): \(error.localizedDescription)")
        }
        await loadProps()
    }

    private func fittedRect(_ image: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func loadProps() async {
        props = (try? await CameraAPI.props()) ?? [:]
        // Which settings the camera offers right now, to tell "locked by the camera" apart
        // from "not offered by the API" later.
        let summary = Self.quickKeys.map { key in
            "\(key)=\(props[key].map { "\($0)" } ?? "-") [\((props[key + "List"] as? [Any])?.count.description ?? "no list")]"
        }
        DebugLog.write("shoot props: mode=\(props["exposureMode"] ?? "-") " + summary.joined(separator: " "))
    }

    private func tapFocus(_ loc: CGPoint, fitted: CGRect) {
        guard fitted.contains(loc) else { return }
        if let setting = props["focusSetting"] as? String, let name = Self.fixedFocus[setting] {
            focusPoint = nil
            status = "초점 방식이 \(name)이라 눌러서 초점을 맞출 수 없어요. 카메라 설정에서 초점 방식을 바꿔 주세요."
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
                status = hit ? "초점 맞춤" : "초점을 맞추지 못했어요. 너무 가까우면 카메라를 매크로 모드로 바꿔 주세요."
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
                DebugLog.write("shoot failed: \(error)")
            }
        }
    }
}

/// Horizontal value dial: scroll and let go, the value under the mark is chosen.
struct DialStrip: View {
    let options: [String]
    /// Every value gets the same width: the strip snaps item edges to its margin, so equal
    /// widths put the chosen one exactly under the mark.
    let itemWidth: CGFloat
    let label: (String) -> String
    let selected: String?
    let choose: (String) -> Void
    @State private var position: String?
    @State private var settle: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        let on = option == position
                        Text(label(option))
                            .font(.subheadline.monospacedDigit().weight(on ? .bold : .regular))
                            .foregroundStyle(on ? Color.yellow : .white.opacity(0.6))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 4)
                            .frame(width: itemWidth, height: 40)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.snappy) { position = option } }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $position, anchor: .center)
            .contentMargins(.horizontal, max(geo.size.width / 2 - itemWidth / 2, 0), for: .scrollContent)
            .overlay(alignment: .top) {
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(.yellow)
            }
            .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
        }
        .frame(height: 44)
        .onAppear { position = selected }
        .onChange(of: position) { _, value in
            guard let value, value != selected else { return }
            settle?.cancel()
            settle = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                choose(value)
            }
        }
    }
}
