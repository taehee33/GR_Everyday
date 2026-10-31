import CoreBluetooth
import IOBluetooth
import Foundation

/// Wakes a GR over Bluetooth LE and raises its Wi-Fi access point.
///
/// UUIDs from the community GR III/IIIx mapping (dm-zharov/ricoh-gr-bluetooth-api,
/// sotashimozono/gr3sync). The same strings ship in GR WORLD, which supports the GR IV.
/// macOS shows its own pairing prompt the first time an encrypted value is read.
enum GRUUID {
    static let cameraService = CBUUID(string: "4B445988-CAA0-4DD3-941D-37B4F52ACA86")
    static let cameraPower = CBUUID(string: "B58CE84C-0666-4DE9-BEC8-2D27B27B3211")
    static let wlanService = CBUUID(string: "F37F568F-9071-445D-A938-5441F2E82399")
    static let networkType = CBUUID(string: "9111CDD0-9F01-45C4-A2D4-E09E8FB0424D")
    static let ssid = CBUUID(string: "90638E5A-E77D-409D-B550-78F7E1CA5AB4")
    static let passphrase = CBUUID(string: "0F38279C-FE9E-461B-8596-81287E8C9A81")
    static let infoService = CBUUID(string: "9A5ED1C5-74CC-4C50-B5B6-66A48E7CCFF1")
    static let modelNumber = CBUUID(string: "35FE6272-6AA5-44D9-88E1-F09427F51A71")
    static let bluetoothControlService = CBUUID(string: "0F291746-0C80-4726-87A7-3C501FD3B4B6")
    static let pairedDeviceName = CBUUID(string: "FE3A32F8-A189-42DE-A391-BC81AE4DAA76")
    static let services = [cameraService, wlanService, infoService, bluetoothControlService]
}

struct WLANCredentials: Codable, Hashable {
    var ssid: String
    var passphrase: String
}

struct FoundCamera: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

@MainActor
final class BLEWaker: NSObject, ObservableObject {
    @Published private(set) var found: [FoundCamera] = []
    @Published private(set) var isScanning = false
    /// The camera whose pairing link is still open. The camera accepts the Mac only on the
    /// link made while pairing, so it is kept open (like the phone app does) to switch the
    /// camera's Wi-Fi on later. nil once the camera drops it (power off, out of range, app quit).
    @Published private(set) var linkedCameraID: UUID?
    private var held: CBPeripheral?
    private var keepAlive: Task<Void, Never>?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var poweredOn: CheckedContinuation<Void, Error>?
    private var connected: CheckedContinuation<Void, Error>?
    private var discovered: CheckedContinuation<Void, Error>?
    private var pendingCharacteristics = 0
    private var reads: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writes: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var current: CBPeripheral?
    private var loggedDevices: Set<UUID> = []
    private var awaitedAdvert: (id: UUID, continuation: CheckedContinuation<Void, Error>)?

    struct BLEError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }

        /// macOS holds a pairing key the camera refuses; only the user can remove it.
        static let staleBond = BLEError(message: "Mac에 남아 있는 이 카메라의 페어링 정보 때문에 연결이 막혀 있습니다. 아래 ‘Bluetooth 설정 열기’에서 GR_로 시작하는 카메라 옆 ⓘ → ‘이 기기 지우기’를 누른 뒤 다시 시도하세요. (처음 한 번만 필요)")
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func waitPoweredOn() async throws {
        switch central.state {
        case .poweredOn: return
        case .unauthorized: throw BLEError(message: "Bluetooth 권한이 없습니다. 시스템 설정 > 개인정보 보호 > Bluetooth에서 GR Mac을 허용하세요.")
        case .poweredOff: throw BLEError(message: "Mac의 Bluetooth가 꺼져 있습니다.")
        default:
            try await withCheckedThrowingContinuation { poweredOn = $0 }
        }
    }

    func startScan() async throws {
        try await waitPoweredOn()
        found = []
        isScanning = true
        DebugLog.write("scan start")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    /// Pair with a camera that is in pairing mode (camera menu → Bluetooth → Pairing),
    /// read its Wi-Fi credentials and raise its Wi-Fi, all on the one pairing connection.
    ///
    /// macOS has no "create bond" call: reading an encrypted characteristic makes
    /// the system show its own passkey window, where the user types the code the
    /// camera displays. The key macOS keeps afterwards is refused by the camera on every
    /// later connection (bluetoothd STATUS 634, also right after pairing, and with the iPad
    /// GR Link app on this Mac), so later reconnects go without it; see `raiseWLAN`.
    func pair(cameraID: UUID) async throws -> (model: String, credentials: WLANCredentials) {
        if hasMacBond(cameraID) { throw BLEError.staleBond }
        // The passkey prompt can appear while connecting, so leave time to type the code.
        let peripheral = try await open(cameraID, connectTimeout: 90)
        do {
            try await authenticate(peripheral)
            let model = (try? await read(GRUUID.modelNumber, on: peripheral)).map(Self.text) ?? "RICOH GR"
            await registerPairedName(on: peripheral)
            let credentials = try await raiseWLAN(on: peripheral)
            DebugLog.write("pair: done, wlan \(credentials.ssid); keeping the Bluetooth link")
            hold(peripheral, cameraID: cameraID)
            return (model, credentials)
        } catch {
            central.cancelPeripheralConnection(peripheral)
            throw error
        }
    }

    private func hold(_ peripheral: CBPeripheral, cameraID: UUID) {
        held = peripheral
        linkedCameraID = cameraID
        // A light read now and then, so neither side treats the link as idle.
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, let held = self.held, held.state == .connected, !Task.isCancelled else { return }
                _ = try? await self.read(GRUUID.cameraPower, on: held, timeout: 10)
            }
        }
    }

    /// Power the camera on and switch its Wi-Fi on over the kept pairing link.
    func raiseWLANOnLink() async throws -> WLANCredentials {
        guard let held, held.state == .connected else {
            linkedCameraID = nil
            throw BLEError(message: "카메라와 Bluetooth 연결이 없습니다.")
        }
        DebugLog.write("link: raising WLAN over kept link")
        return try await raiseWLAN(on: held)
    }

    /// Read an encrypted characteristic until macOS has finished SMP pairing.
    private func authenticate(_ peripheral: CBPeripheral) async throws {
        DebugLog.write("pair: requesting encrypted read")
        let deadline = Date().addingTimeInterval(120)
        while true {
            do {
                _ = try await read(GRUUID.passphrase, on: peripheral, timeout: 90,
                                   timeoutMessage: "페어링 코드 입력 시간이 지났습니다. 다시 시도하세요.")
                break
            } catch let error as CBATTError where [.insufficientAuthentication, .insufficientEncryption].contains(error.code) {
                // The system is pairing; the read is refused until it finishes.
                DebugLog.write("pair: waiting for authentication (\(error.code.rawValue))")
                guard Date() < deadline else { throw BLEError(message: "페어링이 완료되지 않았습니다.") }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Tell the camera who it is paired with, as the official app does.
    /// The camera rejected a Korean Mac name, so send ASCII and shorten on refusal.
    private func registerPairedName(on peripheral: CBPeripheral) async {
        let raw = Host.current().localizedName ?? ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -"))
        let ascii = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.isASCII && allowed.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        var candidates = [ascii.isEmpty ? "Mac" : ascii, "GR Mac", "Mac"]
        candidates = candidates.map { String($0.prefix(16)) }
        for name in candidates {
            do {
                try await write(Data(name.utf8), to: GRUUID.pairedDeviceName, on: peripheral)
                DebugLog.write("pair: registered name '\(name)'")
                return
            } catch {
                let ns = error as NSError
                DebugLog.write("pair: name '\(name)' refused: \(ns.domain) \(ns.code)")
            }
        }
    }

    /// Reconnect to a paired camera, power it on, raise its Wi-Fi and read the credentials.
    ///
    /// The camera refuses the key macOS kept from pairing, and macOS insists on using it,
    /// so a Mac-side key blocks the connection: report that at once instead of waiting.
    /// Without it, the link is unencrypted; with `known` credentials only the power and
    /// network-type writes are sent, nothing that would make macOS pair again.
    func raiseWLAN(cameraID: UUID, known: WLANCredentials? = nil) async throws -> (model: String, credentials: WLANCredentials) {
        if hasMacBond(cameraID) { throw BLEError.staleBond }
        try await waitForAdvertisement(cameraID)
        let peripheral = try await open(cameraID, connectTimeout: 15)
        defer { central.cancelPeripheralConnection(peripheral) }
        guard let known else {
            let model = (try? await read(GRUUID.modelNumber, on: peripheral)).map(Self.text) ?? "RICOH GR"
            return (model, try await raiseWLAN(on: peripheral))
        }
        try await write(Data([1]), to: GRUUID.cameraPower, on: peripheral)
        DebugLog.write("wake: power on written")
        try await Task.sleep(for: .seconds(2))
        try await write(Data([1]), to: GRUUID.networkType, on: peripheral)
        DebugLog.write("wake: wlan on written")
        try await Task.sleep(for: .seconds(3))
        return ("RICOH GR", known)
    }

    private func raiseWLAN(on peripheral: CBPeripheral) async throws -> WLANCredentials {
        if try await read(GRUUID.cameraPower, on: peripheral).first != 1 {
            try await write(Data([1]), to: GRUUID.cameraPower, on: peripheral)
            try await Task.sleep(for: .seconds(2))
        }
        if try await read(GRUUID.networkType, on: peripheral).first != 1 {
            try await write(Data([1]), to: GRUUID.networkType, on: peripheral)
            try await Task.sleep(for: .seconds(3))
        }
        return WLANCredentials(
            ssid: Self.text(try await read(GRUUID.ssid, on: peripheral)),
            passphrase: Self.text(try await read(GRUUID.passphrase, on: peripheral))
        )
    }

    /// Remove the camera from the Mac's Bluetooth devices (System Settings → Bluetooth →
    /// ⓘ → 이 기기 지우기). CoreBluetooth's unpairPeer: is refused for apps, so this goes
    /// through IOBluetooth's device record, found by the camera's Bluetooth name.
    func removeMacBond(_ cameraID: UUID, name: String) async -> Bool {
        guard let device = Self.pairedDevice(named: name) else { return true }
        let remove = NSSelectorFromString("remove")
        if device.responds(to: remove) {
            _ = device.perform(remove)
            DebugLog.write("forget: IOBluetooth remove sent for \(name)")
        } else {
            DebugLog.write("forget: IOBluetoothDevice has no remove")
        }
        for _ in 0..<10 where Self.pairedDevice(named: name) != nil {
            try? await Task.sleep(for: .milliseconds(300))
        }
        let gone = Self.pairedDevice(named: name) == nil
        DebugLog.write("forget: \(name) removed=\(gone)")
        return gone
    }

    /// The camera as listed in the Mac's Bluetooth settings, if it is there.
    static func pairedDevice(named name: String) -> IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).first { $0.name == name }
    }

    /// Whether macOS holds a pairing key for the camera. There is no public call for this;
    /// CoreBluetooth's private pairing agent answers it (its unpairPeer: is refused for apps).
    func hasMacBond(_ cameraID: UUID) -> Bool {
        guard let peripheral = peripherals[cameraID]
            ?? central.retrievePeripherals(withIdentifiers: [cameraID]).first else { return false }
        let agentSelector = NSSelectorFromString("sharedPairingAgent")
        let isPaired = NSSelectorFromString("isPeerPaired:")
        guard central.responds(to: agentSelector),
              let agent = central.perform(agentSelector)?.takeUnretainedValue() as? NSObject,
              agent.responds(to: isPaired) else { return false }
        typealias BoolMethod = @convention(c) (NSObject, Selector, CBPeripheral) -> Bool
        let check = unsafeBitCast(agent.method(for: isPaired), to: BoolMethod.self)
        let paired = check(agent, isPaired, peripheral)
        DebugLog.write("mac bond for \(cameraID): \(paired)")
        return paired
    }

    /// Scan until the camera is heard. Connecting to a camera that is not advertising
    /// just waits, so this turns "timed out" into a clear "the camera is silent".
    private func waitForAdvertisement(_ cameraID: UUID, timeout: Double = 10) async throws {
        try await waitPoweredOn()
        DebugLog.write("waiting for advertisement from \(cameraID)")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        defer { central.stopScan(); isScanning = false }
        try await withTimeout(timeout, "카메라의 Bluetooth 신호가 없습니다. 카메라 전원을 켜고, 메뉴 → 무선 통신 → Bluetooth가 켜져 있는지 확인하세요. 카메라를 끈 상태에서도 연결하려면 Bluetooth 동작 조건을 ‘항상’으로 설정하세요.") {
            try await withCheckedThrowingContinuation { self.awaitedAdvert = (cameraID, $0) }
        }
        DebugLog.write("advertisement heard")
    }

    /// Connect and discover the GR services. Works for a camera seen in this scan
    /// or one this Mac connected to before (by its saved CoreBluetooth identifier).
    private func open(_ cameraID: UUID, connectTimeout: Double = 20,
                      timeoutMessage: String = "Bluetooth 연결 시간 초과 — 카메라가 켜져 있고 가까이 있는지 확인하세요.") async throws -> CBPeripheral {
        try await waitPoweredOn()
        stopScan()
        guard let peripheral = peripherals[cameraID]
            ?? central.retrievePeripherals(withIdentifiers: [cameraID]).first else {
            throw BLEError(message: "카메라를 찾을 수 없습니다. 카메라 Bluetooth가 켜져 있는지 확인하세요.")
        }
        peripherals[cameraID] = peripheral
        peripheral.delegate = self
        current = peripheral
        characteristics = [:]
        DebugLog.write("open: connecting \(cameraID)")
        do {
            try await withTimeout(connectTimeout, timeoutMessage) {
                try await withCheckedThrowingContinuation { self.connected = $0; self.central.connect(peripheral) }
            }
            try await withTimeout(20, "카메라 서비스 탐색 시간 초과") {
                try await withCheckedThrowingContinuation { self.discovered = $0
                    peripheral.discoverServices(GRUUID.services)
                }
            }
        } catch {
            central.cancelPeripheralConnection(peripheral)
            throw error
        }
        DebugLog.write("open: \(characteristics.count) characteristics")
        for service in peripheral.services ?? [] {
            for c in service.characteristics ?? [] {
                DebugLog.write("  char \(service.uuid.uuidString)/\(c.uuid.uuidString) props=0x\(String(c.properties.rawValue, radix: 16))")
            }
        }
        return peripheral
    }

    private func read(_ uuid: CBUUID, on peripheral: CBPeripheral, timeout: Double = 15,
                      timeoutMessage: String = "값 읽기 시간 초과 (페어링 승인 필요?)") async throws -> Data {
        guard let c = characteristics[uuid] else { throw BLEError(message: "특성 \(uuid) 없음 — 이 모델은 다른 UUID를 쓰는 것 같습니다.") }
        return try await withTimeout(timeout, timeoutMessage) {
            try await withCheckedThrowingContinuation {
                // A read that timed out earlier is still waiting; fail it before replacing it.
                self.reads[uuid]?.resume(throwing: BLEError(message: "superseded"))
                self.reads[uuid] = $0
                peripheral.readValue(for: c)
            }
        }
    }

    private func write(_ data: Data, to uuid: CBUUID, on peripheral: CBPeripheral) async throws {
        guard let c = characteristics[uuid] else { throw BLEError(message: "특성 \(uuid) 없음") }
        try await withTimeout(15, "값 쓰기 시간 초과") {
            try await withCheckedThrowingContinuation {
                self.writes[uuid]?.resume(throwing: BLEError(message: "superseded"))
                self.writes[uuid] = $0
                peripheral.writeValue(data, for: c, type: .withResponse)
            }
        }
    }

    /// Resume every waiting continuation with `error`. Only one BLE operation runs at a time.
    private func failPending(_ error: Error) {
        awaitedAdvert?.continuation.resume(throwing: error); awaitedAdvert = nil
        connected?.resume(throwing: error); connected = nil
        discovered?.resume(throwing: error); discovered = nil
        reads.values.forEach { $0.resume(throwing: error) }; reads = [:]
        writes.values.forEach { $0.resume(throwing: error) }; writes = [:]
    }

    /// Abort the current connect / pairing attempt.
    func cancel() {
        DebugLog.write("cancel requested")
        if let current, current != held { central.cancelPeripheralConnection(current) }
        failPending(BLEError(message: "취소했습니다."))
    }

    private func withTimeout<T>(_ seconds: Double, _ message: String, _ body: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // A checked continuation ignores task cancellation, so the group would wait for it
            // forever after the timer fires. Failing the pending continuation lets the body finish.
            group.addTask {
                try await withTaskCancellationHandler {
                    try await body()
                } onCancel: {
                    Task { @MainActor in
                        DebugLog.write("timeout: \(message)")
                        self.failPending(BLEError(message: message))
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw BLEError(message: message)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func text(_ data: Data) -> String {
        let bytes = data.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension BLEWaker: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            DebugLog.write("central state=\(central.state.rawValue) auth=\(CBManager.authorization.rawValue)")
            guard let c = poweredOn else { return }
            switch central.state {
            case .poweredOn: c.resume(); poweredOn = nil
            case .unauthorized, .poweredOff, .unsupported:
                c.resume(throwing: BLEError(message: "Bluetooth를 사용할 수 없습니다 (\(central.state.rawValue))."))
                poweredOn = nil
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
            let maker = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.map { String(format: "%02x", $0) }.joined() ?? ""
            // Log Ricoh devices (manufacturer 0x065F) every time, anything else once.
            let isRicoh = maker.hasPrefix("5f06") || name.uppercased().hasPrefix("GR")
            if isRicoh || loggedDevices.insert(peripheral.identifier).inserted {
                DebugLog.write("scan name=\(name) id=\(peripheral.identifier) rssi=\(RSSI) services=\(services) maker=\(maker)")
            }
            // A paired camera may advertise without its name; match it by identifier first.
            if let awaited = awaitedAdvert, awaited.id == peripheral.identifier {
                peripherals[peripheral.identifier] = peripheral
                awaitedAdvert = nil
                awaited.continuation.resume()
            }
            // GR III/IIIx/IV advertise as "GR_XXXXXX"; keep anything starting with GR.
            let advertisesGR = services.contains { s in GRUUID.services.contains { $0.uuidString == s } }
            guard name.uppercased().hasPrefix("GR") || advertisesGR else { return }
            peripherals[peripheral.identifier] = peripheral
            let camera = FoundCamera(id: peripheral.identifier, name: name.isEmpty ? "RICOH GR" : name, rssi: RSSI.intValue)
            if let i = found.firstIndex(where: { $0.id == camera.id }) { found[i] = camera } else { found.append(camera) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            DebugLog.write("connected")
            connected?.resume(); connected = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            DebugLog.write("failed to connect: \(error?.localizedDescription ?? "-")")
            connected?.resume(throwing: error ?? BLEError(message: "Bluetooth 연결 실패"))
            connected = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            DebugLog.write("disconnected: \(error?.localizedDescription ?? "-")")
            if peripheral == held {
                DebugLog.write("link: kept Bluetooth link lost")
                held = nil
                linkedCameraID = nil
                keepAlive?.cancel()
            }
            failPending(BLEError(message: "카메라 연결이 끊겼습니다\(error.map { ": \($0.localizedDescription)" } ?? ".")"))
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = peripheral.services ?? []
            DebugLog.write("services: \(services.map(\.uuid.uuidString)) error=\(error?.localizedDescription ?? "-")")
            if let error { discovered?.resume(throwing: error); discovered = nil; return }
            guard !services.isEmpty else {
                discovered?.resume(throwing: BLEError(message: "GR 서비스가 없습니다. 이 모델은 다른 UUID를 쓰는 것 같습니다."))
                discovered = nil
                return
            }
            pendingCharacteristics = services.count
            services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            service.characteristics?.forEach { characteristics[$0.uuid] = $0 }
            pendingCharacteristics -= 1
            if pendingCharacteristics == 0 { discovered?.resume(); discovered = nil }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let c = reads.removeValue(forKey: characteristic.uuid) else { return }
            DebugLog.write("read \(characteristic.uuid): \(error.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "\(characteristic.value?.count ?? 0) bytes")")
            if let error { c.resume(throwing: error) } else { c.resume(returning: characteristic.value ?? Data()) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let c = writes.removeValue(forKey: characteristic.uuid) else { return }
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }
}

/// Appends to ~/Library/Logs/GRLink.log, for diagnosing real-camera sessions.
enum DebugLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GRLink.log")

    static func write(_ line: String) {
        let text = "\(Date()) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
