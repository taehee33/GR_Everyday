#if os(iOS)
import SwiftUI

/// The row right under 라이브러리's 사진 · 촬영 통계 · 다운로드 기록 picker, the same on every
/// page: capsule chips in the bar's background, at one height and inset.
struct ChipBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .labelStyle(ChipLabelStyle())
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal)
            // Room above too: flush against the page picker, the chips' top edge was cut off.
            .padding(.vertical, 8)
            .background(.bar)
    }
}

/// One capsule. Selected: filled with `tint`. Otherwise outlined. `muted` is for a chip
/// that only tells something (no action), drawn quieter.
struct BarChip: View {
    let title: String
    var icon: String?
    var selected = false
    var tint: Color = .accentColor
    var muted = false
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            label
        }
    }

    private var label: some View {
        Group {
            if let icon, title.isEmpty { Image(systemName: icon) }
            else if let icon { Label(title, systemImage: icon) }
            else { Text(title) }
        }
        .monospacedDigit()
        .font(.footnote.weight(selected ? .semibold : .regular))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, title.isEmpty ? 7 : 10).padding(.vertical, 6)
        .foregroundStyle(selected ? Color.white : muted ? Color.secondary : Color.primary)
        .background(Capsule().fill(selected ? tint : Color(.secondarySystemGroupedBackground)))
        .overlay(Capsule().strokeBorder(selected ? Color.clear : Color(.separator), lineWidth: 0.5))
        .contentShape(Capsule())
    }
}

/// Icon and title close together, for the chips.
struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
#endif
