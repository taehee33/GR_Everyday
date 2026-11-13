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
        // Already there (joined in Settings, or iOS auto-joined a saved network): asking again
        // only risks iOS's "다음 네트워크에 연결할 수 없음". GR WORLD skips the request too.
        if await currentSSID() == credentials.ssid {
            DebugLog.write("wifi: already on \(credentials.ssid)")
            return
        }
        let config = NEHotspotConfiguration(ssid: credentials.ssid, passphrase: credentials.passphrase, isWEP: false)
        // joinOnce = true made iOS fail to join the GR's AP ("다음 네트워크에 연결할 수 없음")
        // while joining by hand worked. The app leaves the network itself: disconnect() →
        // restore() removes this configuration.
        config.joinOnce = false
        do {
            try await applyWithTimeout(config)
        } catch is TimeoutError {
            DebugLog.write("wifi: apply \(credentials.ssid) got no answer from iOS")
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: credentials.ssid)
            throw WiFiError(message: "iOS가 \(credentials.ssid) 접속에 응답하지 않아요. 설정 → Wi-Fi에서 \(credentials.ssid)를 직접 눌러 접속해 보세요.")
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain {
            DebugLog.write("wifi: apply \(credentials.ssid) error \(error.code) \(error.localizedDescription)")
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
        // apply() reports success even when iOS then fails to join and shows "다음 네트워크에
        // 연결할 수 없음" (seen when the camera's AP had only just started). Confirm the phone is
        // really on the camera: iOS names a network this app configured once it is on it.
        for _ in 0..<10 {
            if await currentSSID() == credentials.ssid {
                DebugLog.write("wifi: on \(credentials.ssid)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        // In case iOS won't name it: the camera answering is proof enough.
        if await CameraAPI.ping(timeout: 2) {
            DebugLog.write("wifi: \(credentials.ssid) not named by iOS, but the camera answers")
            return
        }
        let current = await currentSSID()
        DebugLog.write("wifi: apply \(credentials.ssid) said ok but phone is on \(current ?? "another network")")
        // Drop the failed configuration so the next attempt joins afresh.
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: credentials.ssid)
        throw WiFiError(message: "\(credentials.ssid)에 접속하지 못했어요. 다시 시도하는 중…", notFound: true)
    }

    private struct TimeoutError: Error {}

    /// After a failed join iOS sometimes never answers the next apply(), which left the app
    /// on "2번째 시도" forever.
    private static func applyWithTimeout(_ config: NEHotspotConfiguration, seconds: Double = 20) async throws {
        // A task group would still wait for the stuck apply(); resume from whichever comes first.
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Error>?
            init(_ c: CheckedContinuation<Void, Error>) { continuation = c }
            func resume(_ result: Result<Void, Error>) {
                lock.lock(); let c = continuation; continuation = nil; lock.unlock()
                c?.resume(with: result)
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once(c)
            NEHotspotConfigurationManager.shared.apply(config) { error in
                once.resume(error.map { .failure($0) } ?? .success(()))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { once.resume(.failure(TimeoutError())) }
        }
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
