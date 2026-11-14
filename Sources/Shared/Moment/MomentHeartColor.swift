import SwiftUI
import Supabase

/// The color of 순간들 hearts (and the other 순간들 accents that use `MomentLikePlace.moment.tint`).
/// An admin sets it in 어드민 › 당선작 to match the month's winner (app_config.heart_color).
/// Read at launch and each time the app comes back to the front; the last color is kept so the
/// app opens in it. White until an admin picks another. Views that read `tint` redraw when it changes (Observation).
@MainActor @Observable
final class MomentHeartColor {
    static let shared = MomentHeartColor()
    static let defaultHex = "#FFFFFF"

    private(set) var hex: String

    /// The color as shown. White (or near it) would vanish on a light background, so in light
    /// mode it shows as black instead.
    var color: Color {
        let base = Color(hex: hex) ?? Color(hex: Self.defaultHex)!
        return Self.luminance(hex) > 0.9 ? .adaptive(light: .black, dark: base) : base
    }

    /// For text and icons on top of `color` (탐색 chips, the map button).
    var onColor: Color {
        let dark = Color(white: 0.08)
        if Self.luminance(hex) > 0.9 { return .adaptive(light: .white, dark: dark) }
        return Self.luminance(hex) > 0.5 ? dark : .white
    }

    /// Relative luminance of "#RRGGBB", 0...1.
    static func luminance(_ hex: String) -> Double {
        guard let r = Color(hex: hex)?.resolve(in: EnvironmentValues()) else { return 0 }
        func lin(_ c: Float) -> Double {
            let c = Double(c)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r.red) + 0.7152 * lin(r.green) + 0.0722 * lin(r.blue)
    }

    private static let saved = "momentHeartColor"

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.saved)
        hex = saved.flatMap { Color(hex: $0) != nil ? $0 : nil } ?? Self.defaultHex
    }

    /// Shows a color right away (the admin who just saved it), before the next read.
    func set(_ hex: String) {
        guard Color(hex: hex) != nil, hex != self.hex else { return }
        self.hex = hex
        UserDefaults.standard.set(hex, forKey: Self.saved)
    }

    func refresh(client: SupabaseClient = MomentBackend.client) async {
        struct Row: Decodable { let value: String }
        guard let row: Row = try? await client.from("app_config").select("value")
            .eq("key", value: "heart_color").single().execute().value else { return }
        set(row.value.uppercased())
    }
}

extension Color {
    /// One color in light mode, another in dark.
    static func adaptive(light: Color, dark: Color) -> Color {
        #if os(iOS)
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #else
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #endif
    }

    /// "#RRGGBB"
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    /// "#RRGGBB" in sRGB.
    var hexString: String {
        let r = resolve(in: EnvironmentValues())
        func byte(_ x: Float) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r.red), byte(r.green), byte(r.blue))
    }
}
