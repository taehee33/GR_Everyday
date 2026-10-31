import CoreLocation
import CoreWLAN
import Foundation

/// Switches the Mac's Wi-Fi with networksetup. CoreWLAN would need Location
/// permission just to see the camera's SSID, so the CLI is the simpler route.
enum WiFi {
    struct WiFiError: LocalizedError {
        let message: String
        /// The network was not in range (camera Wi-Fi off, or not up yet).
        var notFound = false
        var errorDescription: String? { message }
    }

    @discardableResult
    private static func networksetup(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func interface() throws -> String {
        let out = try networksetup(["-listallhardwareports"])
        let lines = out.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
            if i + 1 < lines.count, lines[i + 1].hasPrefix("Device: ") {
                return String(lines[i + 1].dropFirst("Device: ".count))
            }
        }
        throw WiFiError(message: "Wi-Fi 인터페이스를 찾을 수 없습니다.")
    }

    static func join(_ credentials: WLANCredentials) async throws {
        let iface = try interface()
        let out = try await Task.detached {
            try networksetup(["-setairportnetwork", iface, credentials.ssid, credentials.passphrase])
        }.value
        // networksetup exits 0 on failure too and reports the error on stdout.
        if out.contains("-3912") || out.localizedCaseInsensitiveContains("could not find network") {
            // CoreWLAN error -3912: the network is not in range — the camera's AP is off.
            throw WiFiError(message: "카메라 Wi-Fi(\(credentials.ssid))가 보이지 않습니다. 카메라 Wi-Fi가 꺼져 있습니다.", notFound: true)
        }
        if !out.isEmpty { throw WiFiError(message: "\(credentials.ssid) 접속 실패: \(out)") }
    }

    /// Power-cycle Wi-Fi so macOS auto-joins its usual network again.
    static func restore() async {
        guard let iface = try? interface() else { return }
        _ = try? networksetup(["-setairportpower", iface, "off"])
        try? await Task.sleep(for: .seconds(1))
        _ = try? networksetup(["-setairportpower", iface, "on"])
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
