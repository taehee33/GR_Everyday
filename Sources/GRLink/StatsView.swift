import SwiftUI

/// 촬영 통계, modelled on GR WORLD's GR 로그: a month calendar of shooting days, then counts
/// by exposure mode, image control, aspect ratio and crop for the chosen day and in total.
/// Counted from the files on the card, so deleted shots are not included.
struct StatsView: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var stats: ShotStats
    @State private var day: Date?
    @State private var month = Calendar.current.startOfMonth(.now)

    private struct Entry {
        let date: Date?
        let video: Bool
        let record: ShotRecord?
    }

    /// One entry per shot: a RAW+JPEG pair counts once, as its JPEG.
    private var entries: [Entry] {
        let jpegs = Set(library.photos.filter { $0.kind == .jpeg }.map { ($0.name as NSString).deletingPathExtension })
        return library.photos.compactMap { photo in
            let date = library.infos[photo.id]?.date
            switch photo.kind {
            case .video: return Entry(date: date, video: true, record: nil)
            case .raw where jpegs.contains((photo.name as NSString).deletingPathExtension), .other: return nil
            case .jpeg, .raw:
                let record = stats.records[photo.id]
                return Entry(date: record?.date ?? date, video: false, record: record)
            }
        }
    }

    var body: some View {
        let all = entries
        let calendar = Calendar.current
        let onDay = day.map { d in all.filter { $0.date.map { calendar.isDate($0, inSameDayAs: d) } ?? false } } ?? []
        let perDay = Dictionary(grouping: all.compactMap(\.date), by: { calendar.startOfDay(for: $0) }).mapValues(\.count)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                HStack(alignment: .top, spacing: 20) {
                    CalendarMonth(month: $month, day: $day, counts: perDay)
                        .frame(width: 380)
                    summary(day: onDay, all: all)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 20, alignment: .top)], spacing: 20) {
                    table("노출 모드", day: onDay, all: all, fixed: ["P", "Av", "Tv", "Sn", "M"]) { $0.mode }
                    table("이미지 컨트롤", day: onDay, all: all, label: Self.toneLabel) { $0.imageTone.map(String.init) }
                    table("화상비율", day: onDay, all: all, fixed: ["3:2", "4:3", "1:1", "16:9"]) { $0.aspect }
                    table("크롭", day: onDay, all: all, fixed: ["꺼짐", "35mm", "50mm"]) { r in
                        r.focal35.map { $0 <= 28 ? "꺼짐" : "\($0)mm" }
                    }
                    if all.contains(where: { $0.record?.hdf != nil }) {
                        table("HDF", day: onDay, all: all, fixed: ["꺼짐", "켜짐"], label: Self.hdfLabel) { r in
                            r.hdf.map { ["0": "꺼짐", "1": "켜짐", "2": "레드 필터"]["\($0)"] ?? "코드 \($0)" }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { stats.scan(library.photos) }
        .onChange(of: library.photos) { _, photos in stats.scan(photos) }
        .onChange(of: all.compactMap(\.date).max()) { _, latest in
            // Open on the latest shooting day until the user picks one.
            guard day == nil, let latest else { return }
            day = calendar.startOfDay(for: latest)
            month = calendar.startOfMonth(latest)
        }
        .task {
            if day == nil, let latest = all.compactMap(\.date).max() {
                day = calendar.startOfDay(for: latest)
                month = calendar.startOfMonth(latest)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("촬영 통계").font(.largeTitle.bold())
                Text("카드에 남아 있는 사진 기준입니다. 지운 사진은 세지 않으므로 GR WORLD의 GR 로그와 숫자가 다를 수 있습니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if stats.scanning {
                ProgressView().controlSize(.small)
                Text("촬영 정보 읽는 중 · \(stats.pending)장 남음").foregroundStyle(.secondary)
                Button("중지") { stats.cancel() }
            } else if stats.pending > 0 {
                Button("이어서 읽기 (\(stats.pending)장)") { stats.scan(library.photos) }
            }
        }
    }

    private func summary(day: [Entry], all: [Entry]) -> some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                GridRow {
                    Text("")
                    Text(self.day.map { $0.formatted(.dateTime.month().day().weekday()) } ?? "날").foregroundStyle(.secondary)
                    Text("전체").foregroundStyle(.secondary)
                }
                .font(.callout)
                GridRow {
                    Image(systemName: "photo").font(.title2)
                    Text("\(day.filter { !$0.video }.count)").font(.system(size: 34, weight: .bold).monospacedDigit())
                    Text("\(all.filter { !$0.video }.count)").font(.system(size: 34, weight: .bold).monospacedDigit())
                }
                GridRow {
                    Image(systemName: "video").font(.title2)
                    Text("\(day.filter(\.video).count)").font(.system(size: 34, weight: .bold).monospacedDigit())
                    Text("\(all.filter(\.video).count)").font(.system(size: 34, weight: .bold).monospacedDigit())
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("촬영 횟수").font(.headline)
        }
    }

    /// Rows: `fixed` always (zero or not, like GR 로그), then anything else that occurred.
    private func table(_ title: String, day: [Entry], all: [Entry], fixed: [String] = [],
                       label: @escaping (String) -> String = { $0 },
                       key: @escaping (ShotRecord) -> String?) -> some View {
        func counts(_ entries: [Entry]) -> [String: Int] {
            entries.compactMap { $0.record.flatMap(key) }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        let dayCounts = counts(day), allCounts = counts(all)
        let extra = allCounts.keys.filter { !fixed.contains($0) }
            .sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
        return GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("날").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text("전체").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
                .font(.caption)
                ForEach(fixed + extra, id: \.self) { k in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text(label(k)).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(dayCounts[k] ?? 0)").monospacedDigit()
                            .foregroundStyle((dayCounts[k] ?? 0) == 0 ? .secondary : .primary)
                        Text("\(allCounts[k] ?? 0)").monospacedDigit()
                            .foregroundStyle((allCounts[k] ?? 0) == 0 ? .secondary : .primary)
                    }
                }
            }
            .padding(8)
        } label: {
            Text(title).font(.headline)
        }
    }

    private static func toneLabel(_ key: String) -> String {
        guard let code = Int(key) else { return key }
        return MakerNote.imageToneNames[code] ?? "알 수 없음 (코드 \(code))"
    }

    private static func hdfLabel(_ key: String) -> String { key }
}

/// A month grid; days with shots are tinted by count and can be picked.
private struct CalendarMonth: View {
    @Binding var month: Date
    @Binding var day: Date?
    let counts: [Date: Int]

    private var calendar: Calendar { .current }

    var body: some View {
        let busiest = max(counts.values.max() ?? 1, 1)
        GroupBox {
            VStack(spacing: 10) {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(month.formatted(.dateTime.year().month(.wide))).font(.title3.bold())
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                        if let date { cell(date, busiest: busiest) } else { Color.clear.frame(height: 40) }
                    }
                }
            }
            .padding(6)
        }
    }

    private func cell(_ date: Date, busiest: Int) -> some View {
        let count = counts[date] ?? 0
        let selected = day.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        return Button { day = date } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: date))").font(.body.monospacedDigit())
                Text(count > 0 ? "\(count)" : " ").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(count > 0 ? Color.accentColor.opacity(0.12 + 0.38 * Double(count) / Double(busiest)) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.5 : 1)
    }

    /// Weekday initials starting from the locale's first weekday (일 for Korean).
    private var weekdays: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Leading blanks, then each day of the month.
    private var cells: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    private func shift(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) { month = next }
    }
}

extension Calendar {
    func startOfMonth(_ date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}
