import AppKit
import Combine
import Foundation
import SwiftUI

/// A camera registered on this Mac by Bluetooth pairing.
struct SavedCamera: Codable, Identifiable, Hashable {
    /// CoreBluetooth identifier of the camera.
    let id: UUID
    /// Bluetooth name, e.g. GR_HCB02EB.
    var bleName: String
    var nickname: String?
    var model: String?
    /// Camera Wi-Fi SSID / passphrase, read over Bluetooth while pairing.
    var credentials: WLANCredentials?
    var pairedAt: Date?
    var lastConnected: Date?

    var displayName: String { nickname?.isEmpty == false ? nickname! : bleName }
    /// "RICOH GR IV HDF" → "GR IV HDF"; known after the first Wi-Fi connection.
    var shortModel: String? { model.map { $0.hasPrefix("RICOH ") ? String($0.dropFirst(6)) : $0 } }
}

/// One storage slot from /v1/props "storages".
struct CameraStorage: Hashable {
    let name: String
    let remain: Int?
    let files: Int?
}

@MainActor
final class ConnectionModel: ObservableObject {
    enum State: Equatable {
        case disconnected
        case pairing(String)
        case waking(String)
        case joining(String)
        case connected
        case lost
        case failed(String)
    }

    @Published var state: State = .disconnected
    @Published var model = "RICOH GR"
    @Published var battery: Int?
    /// Everything /v1/props reported on the last poll.
    @Published private(set) var props: [String: Any] = [:]
    /// One-line success message shown on the camera tab (e.g. after pairing).
    @Published var notice: String?
    /// The last failure was a Mac-side pairing key the camera refuses (see BLEWaker.raiseWLAN).
    @Published var needsBondRemoval = false
    /// The camera's Wi-Fi is off and no Bluetooth link is left to switch it on.
    @Published var needsRepair = false
    /// While lost: the camera's WLAN is not in range, i.e. the camera switched it off.
    @Published var cameraWLANOff = false
    /// How the Mac reaches the camera now. USB carries files only (no live view or settings).
    @Published private(set) var viaUSB = false

    @Published private(set) var cameras: [SavedCamera] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(cameras), forKey: "cameras") }
    }
    /// The camera shown on the camera tab.
    @Published var selectedCameraID: UUID? {
        didSet { UserDefaults.standard.set(selectedCameraID?.uuidString, forKey: "lastCameraID") }
    }
    /// The registered camera the Mac is on now; nil when connected to one not registered here.
    @Published private(set) var connectedCameraID: UUID?

    let ble = BLEWaker()
    let usb = USBCamera()
    private var usbChanges: AnyCancellable?
    private var monitor: Task<Void, Never>?
    private var joinedByUs = false
    private var phoneJoin: Task<Void, Never>?

    var isConnected: Bool { state == .connected }
    var isBusy: Bool {
        switch state {
        case .pairing, .waking, .joining: return true
        default: return false
        }
    }
    var selectedCamera: SavedCamera? { cameras.first { $0.id == selectedCameraID } }

    /// How the Mac reaches the camera, for the status box: "USB 케이블" or "Wi-Fi · GR_HCB02EA".
    var route: String {
        if viaUSB { return "USB 케이블" }
        let ssid = (props["ssid"] as? String).map(Self.clean)
            ?? cameras.first { $0.id == connectedCameraID }?.credentials?.ssid
        return ssid.map { "Wi-Fi · \($0)" } ?? "Wi-Fi"
    }

    var storages: [CameraStorage] {
        (props["storages"] as? [[String: Any]] ?? [])
            .filter { $0["equipped"] as? Bool ?? true }
            .map {
                let photos = $0["numOfPhotos"] as? Int, movies = $0["numOfMovies"] as? Int
                let files = photos.map { $0 + (movies ?? 0) } ?? $0["numFiles"] as? Int
                return CameraStorage(name: $0["name"] as? String ?? "", remain: $0["remain"] as? Int, files: files)
            }
    }

    init() {
        var cameras = UserDefaults.standard.data(forKey: "cameras")
            .flatMap { try? JSONDecoder().decode([SavedCamera].self, from: $0) } ?? []
        let lastID = UserDefaults.standard.string(forKey: "lastCameraID").flatMap(UUID.init)
        // Earlier versions kept a single camera under separate keys.
        if cameras.isEmpty, let lastID {
            let credentials = UserDefaults.standard.data(forKey: "wlanCredentials")
                .flatMap { try? JSONDecoder().decode(WLANCredentials.self, from: $0) }
            cameras = [SavedCamera(id: lastID, bleName: UserDefaults.standard.string(forKey: "lastCameraName") ?? "RICOH GR",
                                   credentials: credentials)]
        }
        self.cameras = cameras
        selectedCameraID = lastID ?? cameras.first?.id
        // Views read connection.usb.detected; pass its changes on.
        usbChanges = usb.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        usb.onRemoved = { [weak self] in
            guard let self, self.viaUSB else { return }
            Task {
                await self.disconnect()
                self.state = .failed("USB 연결이 끊겼습니다. 케이블과 카메라 전원을 확인하세요.")
            }
        }
    }

    // MARK: Registered cameras

    func rename(_ id: UUID, to nickname: String) {
        update(id) { $0.nickname = nickname.trimmingCharacters(in: .whitespaces) }
    }

    func remove(_ id: UUID) {
        cameras.removeAll { $0.id == id }
        CameraPictures.shared.remove(id)
        if selectedCameraID == id { selectedCameraID = cameras.first?.id }
        if connectedCameraID == id { connectedCameraID = nil }
    }

    private func update(_ id: UUID, _ change: (inout SavedCamera) -> Void) {
        guard let i = cameras.firstIndex(where: { $0.id == id }) else { return }
        change(&cameras[i])
    }

    /// Whether the Mac's Bluetooth still lists the camera as paired.
    func hasMacBond(_ camera: SavedCamera) async -> Bool { await BLEWaker.isPaired(named: camera.bleName) }

    // MARK: Connecting

    /// First-time pairing (camera menu → Bluetooth → Pairing; macOS asks for the code),
    /// which also reads the camera's Wi-Fi password and joins it.
    func pair(_ found: FoundCamera) async {
        notice = nil
        needsBondRemoval = false
        state = .pairing("\(found.name)에 연결 중… Mac에 뜨는 창에 카메라 화면의 페어링 코드를 입력하세요.")
        do {
            let (model, credentials) = try await ble.pair(cameraID: found.id, name: found.name)
            self.model = model
            if cameras.contains(where: { $0.id == found.id }) {
                update(found.id) { $0.model = model; $0.credentials = credentials; $0.pairedAt = .now }
            } else {
                cameras.append(SavedCamera(id: found.id, bleName: found.name, model: model,
                                           credentials: credentials, pairedAt: .now))
            }
            selectedCameraID = found.id
            notice = "\(found.name)을(를) 등록했습니다."
            try await joinCamera(credentials, camera: found.id)
        } catch {
            needsBondRemoval = (error as? BLEWaker.BLEError) == .staleBond
            state = .failed("페어링 실패: \(error.localizedDescription)")
        }
    }

    func cancelBluetooth() {
        ble.cancel()
        if let phoneJoin {
            phoneJoin.cancel()
            self.phoneJoin = nil
            state = .disconnected
        }
    }

    /// The iPhone (GR WORLD) switches the camera's Wi-Fi on and the Mac only joins it.
    /// After pairing, the camera ignores the Mac's Bluetooth reconnects (macOS connects from
    /// its public address after handing the camera an IRK), but the iPhone reconnects fine.
    func connectViaPhone(_ camera: SavedCamera) async {
        guard let credentials = camera.credentials else {
            state = .failed("이 카메라의 Wi-Fi 정보가 없습니다. 다시 등록하세요.")
            return
        }
        notice = nil
        needsBondRemoval = false
        needsRepair = false
        let task = Task {
            do {
                try await joinCamera(credentials, camera: camera.id, waitFor: 180,
                                     waiting: "휴대폰의 GR WORLD에서 카메라에 연결해 WLAN(Wi-Fi)을 켜 주세요. \(credentials.ssid)가 보이면 바로 접속합니다. 연결된 뒤 휴대폰 제어 센터에서 Bluetooth를 끄면 휴대폰을 잠가도 카메라 WLAN이 유지됩니다(Bluetooth를 켠 채 잠그면 카메라가 WLAN을 끕니다).")
            } catch is CancellationError {
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        phoneJoin = task
        await task.value
        if phoneJoin == task { phoneJoin = nil }
    }

    /// Join a registered camera's Wi-Fi with the password saved while pairing.
    /// The GR refuses both the key macOS keeps from pairing and unpaired links, so a Mac
    /// cannot switch the camera's Wi-Fi on over Bluetooth: the user turns it on (메뉴 → 무선 LAN).
    func connect(_ camera: SavedCamera) async {
        guard let credentials = camera.credentials else {
            state = .failed("이 카메라의 Wi-Fi 정보가 없습니다. 다시 등록하세요.")
            return
        }
        notice = nil
        needsBondRemoval = false
        needsRepair = false
        // The camera only starts its Wi-Fi when a Bluetooth peer asks. The pairing link is
        // kept open for that; use it first.
        if ble.linkedCameraID == camera.id {
            state = .waking("Bluetooth로 카메라 Wi-Fi 켜는 중…")
            if let fresh = try? await ble.raiseWLANOnLink() {
                update(camera.id) { $0.credentials = fresh }
            }
        }
        do {
            try await joinCamera(credentials, camera: camera.id)
        } catch let error as WiFi.WiFiError where error.notFound {
            if ble.linkedCameraID != camera.id {
                needsRepair = true
                state = .failed("카메라 Wi-Fi가 꺼져 있고, 켜 줄 Bluetooth 연결도 끊겨 있습니다(카메라를 끄거나 앱을 다시 실행하면 끊깁니다). ‘다시 페어링’을 누르면 Bluetooth를 다시 잇고 Wi-Fi까지 켭니다.")
            } else {
                state = .joining("주변 Wi-Fi 확인 중…")
                state = .failed(await notFoundMessage(for: camera, credentials: credentials))
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Pair again to get a Bluetooth link the camera accepts, which also switches its Wi-Fi
    /// on and joins it. The camera must show its pairing screen; macOS's old key must go first.
    func repair(_ camera: SavedCamera) async {
        notice = nil
        needsRepair = false
        if await hasMacBond(camera) {
            needsBondRemoval = true
            state = .failed("먼저 Mac Bluetooth에 남은 \(camera.bleName)을(를) 지워야 합니다. 열린 Bluetooth 설정에서 \(camera.bleName) 옆 ⓘ → ‘이 기기 지우기’를 누른 뒤, 카메라를 페어링 화면(메뉴 → 무선 통신 → Bluetooth → 페어링)에 두고 ‘다시 페어링’을 다시 누르세요.")
            needsRepair = true
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
            return
        }
        needsBondRemoval = false
        state = .pairing("카메라를 페어링 화면(메뉴 → 무선 통신 → Bluetooth → 페어링)에 두세요. 카메라를 찾는 중…")
        do {
            try await ble.startScan()
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline, !ble.found.contains(where: { $0.id == camera.id }) {
                try await Task.sleep(for: .milliseconds(500))
            }
            ble.stopScan()
            guard let found = ble.found.first(where: { $0.id == camera.id }) else {
                needsRepair = true
                state = .failed("카메라를 찾지 못했습니다. 카메라가 페어링 화면인지 확인하고 다시 누르세요.")
                return
            }
            await pair(found)
        } catch {
            ble.stopScan()
            needsRepair = true
            state = .failed(error.localizedDescription)
        }
    }

    /// Say what the Mac actually sees, so "camera Wi-Fi is off" is not a guess.
    private func notFoundMessage(for camera: SavedCamera, credentials: WLANCredentials) async -> String {
        guard let networks = await WiFi.nearby() else {
            return "Mac이 카메라 Wi-Fi(\(credentials.ssid))를 찾지 못했습니다. 카메라 Wi-Fi가 켜져 있는지 확인하세요.\n(주변 Wi-Fi 이름을 확인하려면 시스템 설정 → 개인정보 보호 → 위치 서비스에서 GR Mac을 허용하세요.)"
        }
        DebugLog.write("nearby: " + networks.map { "\($0.ssid)(\($0.rssi) ch\($0.channel))" }.joined(separator: ", "))
        let cameraNetworks = networks.filter { $0.ssid.hasPrefix("GR") || $0.ssid.localizedCaseInsensitiveContains("RICOH") }
        if cameraNetworks.isEmpty {
            return "Mac 주변에 카메라 Wi-Fi가 하나도 보이지 않습니다(주변 Wi-Fi \(networks.count)개 확인). 카메라 Wi-Fi가 실제로 켜지지 않았거나, 다른 기기(휴대폰 등)가 이미 카메라 Wi-Fi에 연결돼 있을 수 있습니다."
        }
        let names = cameraNetworks.map { "\($0.ssid) (\($0.rssi) dBm)" }.joined(separator: ", ")
        return "저장된 카메라 Wi-Fi(\(credentials.ssid))는 안 보이고, Mac에는 \(names)이(가) 보입니다. 카메라 Wi-Fi 이름이 바뀌었다면 카메라를 다시 등록하세요."
    }

    /// `waiting` replaces the retry message while the camera's Wi-Fi is not up yet.
    private func joinCamera(_ credentials: WLANCredentials, camera: UUID?,
                            waitFor seconds: TimeInterval = 25, waiting: String? = nil) async throws {
        if isConnected || viaUSB { await disconnect() }
        // A camera AP that was just switched on takes a few seconds to show up in the
        // Mac's scan, and one scan can miss it; keep looking for a while.
        let deadline = Date().addingTimeInterval(seconds)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            state = .joining(attempt == 1 ? "\(credentials.ssid) Wi-Fi 접속 중…"
                                          : waiting ?? "\(credentials.ssid) Wi-Fi 찾는 중… (\(attempt)번째 시도)")
            do {
                try await WiFi.join(credentials)
                break
            } catch let error as WiFi.WiFiError where error.notFound && Date() < deadline {
                try await Task.sleep(for: .seconds(2))
            }
        }
        joinedByUs = true
        try await waitReachable()
        connectedCameraID = camera
        await didConnect()
    }

    /// The camera on a USB cable: its files through USBCamera's local server. The Mac's
    /// Wi-Fi stays on the usual network, so the internet and AirPlay keep working.
    func connectUSB() async {
        if isConnected { await disconnect() }
        notice = nil
        state = .joining("USB로 카메라 여는 중…")
        do {
            CameraAPI.base = try await usb.open()
            viaUSB = true
            joinedByUs = false
            let model = usb.serving?.name
            connectedCameraID = cameras.first { model != nil && ($0.model == model || $0.shortModel.map { model!.hasSuffix($0) } == true) }?.id
                ?? selectedCameraID
            await didConnect()
        } catch {
            usb.close()
            CameraAPI.base = CameraAPI.wifiBase
            viaUSB = false
            state = .failed(error.localizedDescription)
        }
    }

    /// The Mac is already on the camera's Wi-Fi (joined by hand).
    func connectDirect() async {
        if viaUSB { await disconnect() }
        state = .joining("카메라 응답 확인 중…")
        do {
            try await waitReachable(timeout: 5)
            joinedByUs = false
            connectedCameraID = nil
            await didConnect()
        } catch {
            state = .failed("카메라에 접속할 수 없습니다. Mac이 카메라 Wi-Fi(GR_…)에 연결돼 있는지 확인하세요.")
        }
    }

    func disconnect() async {
        monitor?.cancel()
        // Leave the camera's Wi-Fi on by default: a Mac cannot switch it back on over
        // Bluetooth, so turning it off here made every later reconnect fail.
        if viaUSB {
            usb.close()
            CameraAPI.base = CameraAPI.wifiBase
            viaUSB = false
        } else if UserDefaults.standard.bool(forKey: "turnOffCameraWiFi") { await CameraAPI.finishWLAN() }
        let restore = UserDefaults.standard.object(forKey: "restoreWiFi") as? Bool ?? true
        if joinedByUs, restore { await WiFi.restore() }
        joinedByUs = false
        cameraWLANOff = false
        connectedCameraID = nil
        props = [:]
        battery = nil
        state = .disconnected
    }

    private func waitReachable(timeout: TimeInterval = 40) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await CameraAPI.ping() { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw CameraAPI.APIError(message: "카메라 Wi-Fi에 접속했지만 응답이 없습니다.")
    }

    private func didConnect() async {
        // Read props first so the camera is recognised before the UI says "connected".
        await refreshProps()
        // Joined by hand: recognise a registered camera by its Bluetooth or Wi-Fi name.
        if connectedCameraID == nil {
            let bdName = (props["bdName"] as? String).map(Self.clean)
            let ssid = (props["ssid"] as? String).map(Self.clean)
            connectedCameraID = cameras.first {
                (bdName != nil && Self.clean($0.bleName) == bdName)
                    || (ssid != nil && $0.credentials.map { Self.clean($0.ssid) } == ssid)
            }?.id
        }
        if let id = connectedCameraID {
            update(id) { $0.lastConnected = .now; if let m = self.props["model"] as? String { $0.model = m } }
            selectedCameraID = id
        }
        state = .connected
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                // Over USB the cable state says it; an HTTP ping to the local server can time
                // out while it is busy making thumbnails and showed a false "연결 끊김".
                let alive = self.viaUSB ? self.usb.serving != nil : await CameraAPI.ping()
                if alive {
                    if self.state == .lost { self.state = .connected; self.cameraWLANOff = false }
                    await self.refreshProps()
                } else if self.state == .connected {
                    self.state = .lost
                } else if self.state == .lost, !self.viaUSB {
                    await self.rejoinLostCamera()
                }
            }
        }
    }

    /// When the camera switches its WLAN off, macOS falls back to the usual Wi-Fi. Join the
    /// camera again whenever its WLAN is back (the phone's GR WORLD turns it on).
    private func rejoinLostCamera() async {
        guard let id = connectedCameraID, let credentials = cameras.first(where: { $0.id == id })?.credentials else { return }
        do {
            try await WiFi.join(credentials)
            joinedByUs = true
            DebugLog.write("lost: rejoined \(credentials.ssid)")
        } catch let error as WiFi.WiFiError where error.notFound {
            if !cameraWLANOff { DebugLog.write("lost: \(credentials.ssid) not in range, camera WLAN off") }
            cameraWLANOff = true
        } catch {
            DebugLog.write("lost: rejoin failed: \(error.localizedDescription)")
        }
    }

    /// Names read over Bluetooth come padded with NULs to the characteristic's length.
    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
    }

    func refreshProps() async {
        guard let props = try? await CameraAPI.props() else { return }
        self.props = props
        if let m = props["model"] as? String { model = m }
        battery = props["battery"] as? Int
    }
}
