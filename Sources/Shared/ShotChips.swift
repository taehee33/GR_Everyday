import SwiftUI

/// Shot settings as chips, like a camera's info screen: exposure on the first line,
/// image control and HDF on the second.
struct ShotChips: View {
    let metadata: PhotoMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let exposure = [metadata.shutter, metadata.aperture, metadata.iso, metadata.compensation, metadata.focalLength]
                .compactMap { $0 }
            if !exposure.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(exposure, id: \.self) { value in
                        Chip(text: value, background: Color.primary.opacity(0.07), foreground: .secondary, monospaced: true)
                    }
                }
            }
            let shot = metadata.shot
            if shot?.hdf != nil || shot?.imageControl != nil {
                FlowLayout(spacing: 6) {
                    if let control = shot?.imageControl {
                        Chip(text: control.name ?? "알 수 없음 (\(control.code))", icon: "camera.filters",
                             background: Color.white.opacity(0.14), foreground: .primary, bold: true)
                            .help("촬영 때 이미지 컨트롤")
                    }
                    if let hdf = shot?.hdf { hdfChip(hdf) }
                }
            }
        }
    }

    @ViewBuilder private func hdfChip(_ value: Int) -> some View {
        switch value {
        case 1:
            Chip(text: "HDF ON", icon: "sparkles", background: Color.white.opacity(0.14), foreground: .primary, bold: true)
                .help("HDF(하이라이트 디퓨전 필터) 켜고 촬영")
        case 0:
            Chip(text: "HDF OFF", background: .clear, foreground: .secondary, border: true)
                .help("HDF 끄고 촬영")
        case 2:
            Chip(text: "HDF 레드 필터", icon: "sparkles", background: Color.white.opacity(0.14), foreground: .primary, bold: true)
        default:
            Chip(text: "HDF \(value)", background: .clear, foreground: .secondary, border: true)
        }
    }
}

private struct Chip: View {
    let text: String
    var icon: String? = nil
    var background: Color
    var foreground: Color
    var bold = false
    var monospaced = false
    var border = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2.bold()) }
            Text(text)
                .font(monospaced ? .caption.monospacedDigit() : .caption)
                .fontWeight(bold ? .bold : .regular)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
        .overlay { if border { Capsule().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1) } }
    }
}

/// Lays children out left to right, wrapping to a new line when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
