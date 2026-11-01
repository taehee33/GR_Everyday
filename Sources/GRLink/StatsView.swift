import SwiftUI

/// 촬영 통계, modelled on GR WORLD's GR 로그: a month calendar of shooting days, then counts
/// by exposure mode, image control, aspect ratio and crop for the chosen day and in total.
/// Counted from the files on the card, so deleted shots are not included.
struct StatsView: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var stats: ShotStats
    @Binding var section: Pane
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
                    table(.mode, day: onDay, all: all, fixed: ["P", "Av", "Tv", "Sn", "M"])
                    table(.tone, day: onDay, all: all)
                    table(.aspect, day: onDay, all: all, fixed: ["3:2", "4:3", "1:1", "16:9"])
                    table(.crop, day: onDay, all: all, fixed: ["꺼짐", "35mm", "50mm"])
                    if all.contains(where: { $0.record?.hdf != nil }) {
                        table(.hdf, day: onDay, all: all, fixed: ["꺼짐", "켜짐"])
                    }
                }
                Text("줄을 누르면 라이브러리에서 그 사진만 보여 줍니다. ‘날’ 숫자를 누르면 선택한 날의 사진만 보여 줍니다.")
                    .font(.caption).foregroundStyle(.secondary)
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
            HStack {
                Text("촬영 횟수").font(.headline)
                Spacer()
                if let day = self.day {
                    Button("이 날 사진 보기") { open(ShotFilter(day: day)) }.controlSize(.small)
                }
            }
        }
    }

    /// Rows: `fixed` always (zero or not, like GR 로그), then anything else that occurred.
    private func table(_ field: ShotFilter.Field, day: [Entry], all: [Entry], fixed: [String] = []) -> some View {
        func counts(_ entries: [Entry]) -> [String: Int] {
            entries.compactMap { $0.record?.key(field) }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
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
                    let dayCount = dayCounts[k] ?? 0, allCount = allCounts[k] ?? 0
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Button { open(ShotFilter(field: field, value: k)) } label: {
                            Text(field.label(k)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .disabled(allCount == 0)
                        .help("라이브러리에서 \(field.label(k)) 사진 \(allCount)장 보기")
                        Button { open(ShotFilter(field: field, value: k, day: self.day)) } label: {
                            Text("\(dayCount)").monospacedDigit().underline(dayCount > 0)
                        }
                        .disabled(dayCount == 0)
                        .foregroundStyle(dayCount == 0 ? .secondary : .primary)
                        .help("이 날의 \(field.label(k)) 사진만 보기")
                        Text("\(allCount)").monospacedDigit()
                            .foregroundStyle(allCount == 0 ? .secondary : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        } label: {
            Text(field.rawValue).font(.headline)
        }
    }

    /// Shows the library with only these shots; the JPG/RAW/영상 picker goes back to 전체.
    private func open(_ filter: ShotFilter) {
        library.shotFilter = filter
        library.filter = .all
        library.mode = .grid
        section = .library
    }

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
