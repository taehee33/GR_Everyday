import SwiftUI

/// A GR silhouette with the "GR" mark cut out of its middle, for places without a camera
/// yet. Takes the foreground style, so it reads in light and dark and can be dimmed.
struct GRDrawing: View {
    /// Kept for callers; the silhouette is the same for every model.
    var model: String?

    var body: some View {
        Image("GRSilhouette")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .overlay {
                GeometryReader { geo in
                    Text("GR")
                        .font(.system(size: geo.size.height * 0.34, weight: .heavy, design: .rounded))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: geo.size.height * 0.04)
                        // Cut out, so whatever is behind shows through.
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .accessibilityLabel(Text("RICOH GR"))
    }
}

/// The drawn RICOH GR for a registered camera.
struct GRCameraPicture: View {
    var body: some View {
        Image("GRCamera")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityLabel(Text("RICOH GR"))
    }
}
