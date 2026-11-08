import SwiftUI

/// Library filter: file type, saved or not, and shooting days. Changes are a draft until
/// 적용; the count at the bottom follows the draft, so it shows what applying would leave.
struct FilterSheet: View {
    @EnvironmentObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = LibraryModel.Refine()

    var body: some View {
        NavigationStack {
            Form {
                Section("파일 형식") {
                    chips([("모두", nil), ("JPG", Photo.Kind.jpeg), ("RAW", .raw), ("동영상", .video)],
                          selected: draft.kind) { draft.kind = $0 }
                }
                Section("저장 상태") {
                    chips(LibraryModel.Refine.Saved.allCases.map { ($0.rawValue, $0) }, selected: draft.saved) { draft.saved = $0 }
                }
                Section {
                    dateRow("시작", date: $draft.from, other: draft.to, isStart: true)
                    dateRow("끝", date: $draft.to, other: draft.from, isStart: false)
                } header: {
                    Text("촬영 날짜")
                } footer: {
                    if library.dateRange == nil { Text("카메라에 연결해 촬영 날짜를 읽으면 고를 수 있습니다.") }
                }
                Section {
                    Button("필터 해제") { draft = LibraryModel.Refine() }
                        .frame(maxWidth: .infinity)
                        .disabled(!draft.isActive)
                }
            }
            .navigationTitle("필터")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
        .onAppear { draft = library.refine }
    }

    private var footer: some View {
        let count = library.count(draft)
        return VStack(spacing: 8) {
            VStack(spacing: 2) {
                Text("필터링 결과").font(.caption).foregroundStyle(.secondary)
                Text("\(count)장").font(.title3.monospacedDigit().bold())
                    .contentTransition(.numericText())
                    .animation(.default, value: count)
            }
            Button {
                library.refine = draft
                dismiss()
            } label: {
                Text("적용").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(count == 0)
        }
        .padding()
        .background(.bar)
    }

    /// One row of equal-width choice buttons, like GR WORLD's.
    private func chips<T: Equatable>(_ items: [(String, T)], selected: T, set: @escaping (T) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                let on = items[i].1 == selected
                Button { set(items[i].1) } label: {
                    Text(items[i].0)
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: on ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    /// Off until tapped; then a date limited to the card's shooting days, with a clear button.
    @ViewBuilder private func dateRow(_ title: String, date: Binding<Date?>, other: Date?, isStart: Bool) -> some View {
        if let range = library.dateRange {
            if let value = date.wrappedValue {
                let lower = isStart ? range.lowerBound : max(range.lowerBound, other ?? range.lowerBound)
                let upper = isStart ? min(range.upperBound, other ?? range.upperBound) : range.upperBound
                HStack {
                    DatePicker(title, selection: Binding(get: { value }, set: { date.wrappedValue = $0 }),
                               in: Calendar.current.startOfDay(for: lower)...upper, displayedComponents: .date)
                    Button { date.wrappedValue = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    date.wrappedValue = isStart ? max(range.lowerBound, Calendar.current.startOfDay(for: range.lowerBound))
                                                : range.upperBound
                } label: {
                    LabeledContent(title, value: "지정 안 함")
                }
                .foregroundStyle(.primary)
            }
        } else {
            LabeledContent(title, value: "-")
        }
    }
}
