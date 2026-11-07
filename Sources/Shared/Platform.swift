import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}

extension NSImage {
    var cgImageValue: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
    convenience init(cgImageValue: CGImage) {
        self.init(cgImage: cgImageValue, size: CGSize(width: cgImageValue.width, height: cgImageValue.height))
    }
}
#else
import UIKit
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}

extension UIImage {
    var cgImageValue: CGImage? { cgImage }
    convenience init(cgImageValue: CGImage) { self.init(cgImage: cgImageValue) }
}
#endif

extension View {
    /// A text-like button: .link on the Mac, .borderless (tinted text) on iOS.
    @ViewBuilder func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }
}

/// The device's name for messages: "Mac", "iPhone" or "iPad".
enum Device {
    @MainActor static var name: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// With its subject particle: "Mac이", "iPhone이", "iPad가".
    @MainActor static var subject: String { name == "iPad" ? "iPad가" : "\(name)이" }

    /// Where the app's Bluetooth permission is switched on.
    static var bluetoothPermissionPath: String {
        #if os(macOS)
        return "시스템 설정 > 개인정보 보호 > Bluetooth에서 GR Mac을"
        #else
        return "설정 > GR Connect에서 Bluetooth를"
        #endif
    }
}

/// Opens a page of the system's settings (Bluetooth, Location) where the user fixes something
/// the app can't do itself.
enum SystemSettings {
    @MainActor static func openBluetooth() {
        #if os(macOS)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
        #else
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        #endif
    }
}
