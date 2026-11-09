import Foundation
import NetworkExtension

/// Joins the camera's Wi-Fi with NEHotspotConfiguration: iOS asks the user once per network,
/// then switches to it while the app is in use.
enum WiFi {
    struct WiFiError: LocalizedError {
        let message: String
        /// The network was not in range (camera Wi-Fi off, or not up yet).
        var notFound = false
        var errorDescription: String? { message }
    }

    struct Network: Hashable {
        let ssid: String
        let rssi: Int
        let channel: Int
    }

    static func join(_ credentials: WLANCredentials) async throws {
        let config = NEHotspotConfiguration(ssid: credentials.ssid, passphrase: credentials.passphrase, isWEP: false)
        // Leave the camera network when the app quits, so the phone goes back to its usual one.
        config.joinOnce = true
        do {
            try await NEHotspotConfigurationManager.shared.apply(config)
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain {
            switch NEHotspotConfigurationError(rawValue: error.code) {
            case .alreadyAssociated:
                return
            case .userDenied:
                throw WiFiError(message: "카메라 Wi-Fi 연결을 허용하지 않았어요.")
            case .internal, .pending, .systemConfiguration:
                throw WiFiError(message: "\(credentials.ssid) 접속 실패: \(error.localizedDescription)")
            default:
                // iOS reports a network out of range as "unable to join".
                throw WiFiError(message: "카메라 Wi-Fi(\(credentials.ssid))가 보이지 않아요. 카메라 Wi-Fi가 꺼져 있어요.", notFound: true)
            }
        }
        // apply() returns before iOS has switched networks; the caller waits for the camera.
    }

    /// Back to the usual network.
    static func restore() async {
        let ssids = await NEHotspotConfigurationManager.shared.configuredSSIDs()
        for ssid in ssids where ssid.hasPrefix("GR") {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        }
    }

    /// The network the phone is on. iOS answers for networks this app joined, and for others
    /// once Location is allowed; otherwise nil.
    static func currentSSID() async -> String? {
        await NEHotspotNetwork.fetchCurrent()?.ssid
    }

    /// iOS doesn't let apps list nearby networks.
    static func nearby() async -> [Network]? { nil }
}
