import CoreLocation
import CoreWLAN
import Foundation

/// Switches the Mac's Wi-Fi with CoreWLAN (networksetup can't run inside the App Store
/// sandbox). macOS shows network names only to apps with Location permission, so joining
/// asks for it once.
enum WiFi {
    struct WiFiError: LocalizedError {
        let message: String
        /// The network was not in range (camera Wi-Fi off, or not up yet).
        var notFound = false
        var errorDescription: String? { message }
    }

    static func interface() throws -> CWInterface {
        guard let iface = CWWiFiClient.shared().interface() else {
            throw WiFiError(message: "Wi-Fi 인터페이스를 찾을 수 없습니다.")
        }
        return iface
    }

    static func join(_ credentials: WLANCredentials) async throws {
        guard await LocationPermission.shared.request() else {
            throw WiFiError(message: "카메라 Wi-Fi 이름을 찾으려면 위치 권한이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 위치 서비스에서 GR Mac을 켜세요.")
        }
        let iface = try interface()
        if iface.ssid() == credentials.ssid { return }
        try await Task.detached {
            if iface.powerOn() == false { try iface.setPower(true) }
            // An exact-name scan also finds networks that don't broadcast often.
            let found = (try? iface.scanForNetworks(withName: credentials.ssid)) ?? []
            guard let network = found.max(by: { $0.rssiValue < $1.rssiValue }) else {
                throw WiFiError(message: "카메라 Wi-Fi(\(credentials.ssid))가 보이지 않습니다. 카메라 Wi-Fi가 꺼져 있습니다.", notFound: true)
            }
            do {
                try iface.associate(to: network, password: credentials.passphrase)
            } catch let error as NSError where error.code == -3912 {
                // CoreWLAN -3912: the network went out of range — the camera's AP is off.
                throw WiFiError(message: "카메라 Wi-Fi(\(credentials.ssid))가 보이지 않습니다. 카메라 Wi-Fi가 꺼져 있습니다.", notFound: true)
            } catch {
                throw WiFiError(message: "\(credentials.ssid) 접속 실패: \(error.localizedDescription)")
            }
        }.value
    }

    /// Power-cycle Wi-Fi so macOS auto-joins its usual network again.
    static func restore() async {
        guard let iface = try? interface() else { return }
        try? iface.setPower(false)
        try? await Task.sleep(for: .seconds(1))
        try? iface.setPower(true)
    }
}

extension WiFi {
    struct Network: Hashable {
        let ssid: String
        let rssi: Int
        let channel: Int
    }

    /// Networks the Mac can see now. macOS hides SSIDs from apps without Location
    /// permission, so this asks for it once; nil when it is not granted.
    static func nearby() async -> [Network]? {
        guard await LocationPermission.shared.request() else { return nil }
        return await Task.detached {
            guard let iface = CWWiFiClient.shared().interface(),
                  let found = try? iface.scanForNetworks(withName: nil) else { return [] }
            return found.compactMap { n in
                n.ssid.map { Network(ssid: $0, rssi: n.rssiValue, channel: n.wlanChannel?.channelNumber ?? 0) }
            }
            .sorted { $0.rssi > $1.rssi }
        }.value
    }
}

/// Location permission, needed only to read Wi-Fi network names.
@MainActor
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private var granted: Bool {
        [.authorizedAlways, .authorized].contains(manager.authorizationStatus)
    }

    func request() async -> Bool {
        if granted { return true }
        guard manager.authorizationStatus == .notDetermined else { return false }
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
        await withCheckedContinuation { waiters.append($0) }
        return granted
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }
}
