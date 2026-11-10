import SwiftUI

/// The app's sections: the Mac sidebar and the iPhone/iPad tabs.
enum Pane: String, CaseIterable, Identifiable {
    // Order is the Mac sidebar's and the iPhone/iPad tab bar's; on iPhone/iPad 촬영 통계 is a
    // view inside 라이브러리 rather than a tab.
    case camera = "카메라", remote = "촬영", library = "라이브러리", stats = "촬영 통계", moment = "순간들", settings = "설정"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .camera: return "camera"
        case .library: return "photo.on.rectangle"
        case .remote: return "camera.aperture"
        case .stats: return "chart.bar.xaxis"
        case .moment: return "sparkles.rectangle.stack"
        case .settings: return "gearshape"
        }
    }
}

/// Zoom of the loupe / develop canvas. `scale` 1 is "fit"; fill and 100% are reported
/// by the canvas because they depend on its size.
struct ZoomState: Equatable {
    enum Mode: Equatable { case fit, fill, actual, custom }
    var mode: Mode = .fit
    var custom: CGFloat = 1
    var offset: CGSize = .zero
    var fillScale: CGFloat = 1
    var actualScale: CGFloat = 1

    static let maxScale: CGFloat = 16

    var scale: CGFloat {
        switch mode {
        case .fit: return 1
        case .fill: return fillScale
        case .actual: return actualScale
        case .custom: return custom
        }
    }

    var isZoomed: Bool { scale > 1.001 }
    /// Relative to the image's own pixels (100% = one image pixel per screen pixel).
    var percent: Int { Int((scale / max(actualScale, 0.0001) * 100).rounded()) }

    mutating func set(_ value: CGFloat) {
        custom = min(max(value, 1), max(Self.maxScale, actualScale))
        mode = .custom
        if custom <= 1.001 { mode = .fit; offset = .zero }
    }

    mutating func reset() { mode = .fit; offset = .zero }
}
