import SwiftUI
import UIKit

/// 설정 › 앱 로고: the home-screen icon. 기본 로고, or a month's 당선작 (이달의 사진관) whose
/// icon came in an app update (AppIconCatalog, written by scripts/contest-icon.swift).
struct AppIconPicker: View {
    @State private var current: String? = UIApplication.shared.alternateIconName
    @State private var errorMessage: String?

    private struct Choice: Identifiable {
        /// The alternate icon's name; nil = the app's own icon.
        let iconName: String?
        let preview: String
        let title: String
        var id: String { iconName ?? "default" }
    }

    private var choices: [Choice] {
        AppIconCatalog.months.map { month in
            let p = month.split(separator: "-").compactMap { Int($0) }
            let title = p.count == 2 ? "\(p[0])년 \(p[1])월 당선작" : month
            return Choice(iconName: "AppIcon-\(month)", preview: "AppIconPreview-\(month)", title: title)
        } + [Choice(iconName: nil, preview: "AppIconPreview", title: "기본 로고")]
    }

    var body: some View {
        Form {
            Section {
                ForEach(choices) { choice in
                    Button { pick(choice) } label: {
                        HStack(spacing: 14) {
                            Image(choice.preview).resizable().scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 12.6, style: .continuous))
                            Text(choice.title).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: current == choice.iconName ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(current == choice.iconName ? AnyShapeStyle(MomentLikePlace.moment.tint) : AnyShapeStyle(.tertiary))
                        }
                    }
                    .accessibilityAddTraits(current == choice.iconName ? .isSelected : [])
                }
            } header: {
                Text("홈 화면에 보이는 아이콘을 골라 보세요.")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    Text("매달 순간들의 당선작이 앱 아이콘이 돼요. 새 당선작 아이콘은 앱을 업데이트하면 여기에 생겨요.")
                }
            }
        }
        .navigationTitle("앱 로고")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pick(_ choice: Choice) {
        guard choice.iconName != current, UIApplication.shared.supportsAlternateIcons else { return }
        errorMessage = nil
        UIApplication.shared.setAlternateIconName(choice.iconName) { error in
            Task { @MainActor in
                if let error {
                    errorMessage = "아이콘을 바꾸지 못했어요. (\(error.localizedDescription))"
                } else {
                    current = choice.iconName
                }
            }
        }
    }
}
