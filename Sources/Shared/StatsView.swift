import SwiftUI

/// 촬영 통계, modelled on GR WORLD's GR 로그: a month calendar of shooting days, then counts
/// by exposure mode, image control, aspect ratio and crop for the chosen day and in total.
/// Counted from the files on the card plus, if wanted, shots seen before and deleted since.
struct StatsView: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var stats: ShotStats
    @Binding var section: Pane
    @State private var day: Date?
    @State private var month = Calendar.current.startOfMonth(.now)
    @AppStorage("statsIncludeDeleted") private var includeDeleted = true
    @State private var confirmClear = false
    @AppStorage("statsShowAbout") private var showAbout = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// iPhone (and iPad in a narrow split): calendar above the counts, one table per row.
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    private struct Entry {
        let date: Date?
        let video: Bool
        let record: ShotRecord?
        var deleted = false
    }

    /// One entry per shot (a RAW+JPEG pair counts once, as its JPEG), then deleted ones.
    private var entries: [Entry] {
        let card = ShotStats.shots(library.photos).map { photo in
            let date = library.infos[photo.id]?.date
            if photo.kind == .video { return Entry(date: date, video: true, record: nil) }
            let record = stats.records[photo.id]
            return Entry(date: record?.date ?? date, video: false, record: record)
        }
        return card + (includeDeleted ? deleted : [])
    }

    private var deleted: [Entry] {
        stats.deleted(from: library.photos, dates: library.infos.compactMapValues(\.date))
            .map { Entry(date: $0.date, video: $0.video, record: $0.record, deleted: true) }
    }

    var body: some View {
        let all = entries
        let calendar = Calendar.current
        let onDay = day.map { d in all.filter { $0.date.map { calendar.isDate($0, inSameDayAs: d) } ?? false } } ?? []
        let perDay = Dictionary(grouping: all.compactMap(\.date), by: { calendar.startOfDay(for: $0) }).mapValues(\.count)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if compact {
                    CalendarMonth(month: $month, day: $day, counts: perDay, open: openDay)
                    summary(day: onDay, all: all)
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        CalendarMonth(month: $month, day: $day, counts: perDay, open: openDay)
                            .frame(width: 380)
                        summary(day: onDay, all: all)
                    }
                }
                if compact {
                    // Not lazy: a lazy grid guessed the heights of tables it had not drawn, and
                    // scrolling back up then stopped short of the top, hiding the title.
                    VStack(spacing: 20) { tables(day: onDay, all: all) }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 20, alignment: .top)], spacing: 20) {
                        tables(day: onDay, all: all)
                    }
                }
                Text("줄을 누르면 라이브러리에서 그 사진만 보여 줘요. 날짜 칸의 숫자는 달력에서 고른 날의 사진 수예요. 누르면 그날 사진만 보여 줘요. 흐린 +숫자는 카드에서 지운 사진이라 라이브러리에는 없어요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(compact ? 16 : 24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { library.refreshStats() }
        .alert("지운 사진 기록을 지울까요?", isPresented: $confirmClear) {
            Button("취소", role: .cancel) {}
            Button("기록 지우기", role: .destructive) { stats.clearHistory() }
        } message: {
            Text("이 앱은 카드에서 본 사진의 촬영 정보를 기억해 두었다가, 카드에서 지운 뒤에도 통계에 넣어요. 이 기록을 지우면 지운 사진은 통계에서 빠지고, 카드에 남아 있는 사진만 다시 세요. 사진 파일은 지워지지 않아요.")
        }
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

    /// Opens the library on the day picked in the calendar.
    private var openDay: (() -> Void)? {
        guard let day else { return nil }
        return { open(ShotFilter(day: day)) }
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("촬영 통계").font(.largeTitle.bold())
            Spacer()
            if !compact { scanStatus }
        }
        if compact { HStack { scanStatus } }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $includeDeleted) {
                    Text("지운 사진 포함").tag(true)
                    Text("카드에 있는 사진만").tag(false)
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                Spacer()
                Button {
                    withAnimation(.snappy) { showAbout.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showAbout ? 180 : 0))
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(showAbout ? "설명 접기" : "설명 펼치기")
            }
            if showAbout {
                VStack(alignment: .leading, spacing: 8) {
                    Text(includeDeleted
                         ? "이 앱이 카드에서 한 번이라도 본 사진은 지운 뒤에도 세어요. 그 전에 지운 사진은 GR WORLD의 GR 로그에만 있어요."
                         : "카드에 남아 있는 사진만 세어요.")
                        .font(.callout).foregroundStyle(.secondary)
                    if !stats.history.isEmpty {
                        Button("지운 사진 기록 지우기…") { confirmClear = true }
                            .buttonStyle(.plain).font(.callout).foregroundStyle(.red)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder private var scanStatus: some View {
        if stats.scanning {
                ProgressView().controlSize(.small)
                Text("촬영 정보 읽는 중 · \(stats.pending)장 남음").foregroundStyle(.secondary)
                Button("중지") { stats.cancel() }
            } else if stats.pending > 0 {
                Button("이어서 읽기 (\(stats.pending)장)") { library.refreshStats() }
            }
    }

    private func summary(day: [Entry], all: [Entry]) -> some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                GridRow {
                    Text("")
                    Text(dayTitle(weekday: true)).foregroundStyle(.secondary)
                    Text("전체").foregroundStyle(.secondary)
                }
                .font(.callout)
                GridRow {
                    Image(systemName: "photo").font(.title2)
                    bigCount(day.filter { !$0.video })
                    bigCount(all.filter { !$0.video })
                }
                GridRow {
                    Image(systemName: "video").font(.title2)
                    bigCount(day.filter(\.video))
                    bigCount(all.filter(\.video))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            if includeDeleted, !stats.history.isEmpty, case let gone = deleted.count, gone > 0 {
                Text("카드에서 지운 사진 \(gone)장 포함 · 흐린 숫자가 지운 사진입니다")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 12)
            }
        } label: {
            Text("촬영 횟수").font(.headline)
        }
    }

    @ViewBuilder private func tables(day onDay: [Entry], all: [Entry]) -> some View {
        table(.mode, day: onDay, all: all, fixed: ["P", "Av", "Tv", "Sn", "M"])
        table(.tone, day: onDay, all: all)
        table(.aspect, day: onDay, all: all, fixed: ["3:2", "4:3", "1:1", "16:9"])
        table(.crop, day: onDay, all: all, fixed: ["28mm(기본)", "35mm", "50mm"])
        if all.contains(where: { $0.record?.hdf != nil }) {
            table(.hdf, day: onDay, all: all, fixed: ["꺼짐", "켜짐"])
        }
    }

    /// The day column's heading: the day picked on the calendar ("오늘" when it is today).
    private func dayTitle(weekday: Bool) -> String {
        guard let day else { return "날" }
        if Calendar.current.isDateInToday(day) {
            return weekday ? "오늘 · \(day.formatted(.dateTime.month().day()))" : "오늘"
        }
        return weekday ? day.formatted(.dateTime.month().day().weekday()) : day.formatted(.dateTime.month().day())
    }

    /// A big total with, when some are deleted, "지움 n" under it.
    private func bigCount(_ entries: [Entry]) -> some View {
        let gone = entries.filter(\.deleted).count
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(entries.count)").font(.system(size: 34, weight: .bold).monospacedDigit())
            Text(gone > 0 ? "지움 \(gone)" : " ").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    /// "12" or "12 +3": the card count, then deleted shots greyed.
    private func split(_ card: Int, _ gone: Int) -> some View {
        HStack(spacing: 3) {
            Text("\(card)").foregroundStyle(card + gone == 0 ? .secondary : .primary)
            if gone > 0 { Text("+\(gone)").foregroundStyle(.tertiary) }
        }
        .monospacedDigit()
    }

    /// Rows: `fixed` always (zero or not, like GR 로그), then anything else that occurred.
    private func table(_ field: ShotFilter.Field, day: [Entry], all: [Entry], fixed: [String] = []) -> some View {
        func counts(_ entries: [Entry]) -> [String: Int] {
            entries.compactMap { $0.record?.key(field) }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        let dayCounts = counts(day), allCounts = counts(all)
        let dayGone = counts(day.filter(\.deleted)), allGone = counts(all.filter(\.deleted))
        let extra = allCounts.keys.filter { !fixed.contains($0) }
            .sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
        return GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text(dayTitle(weekday: false)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text("전체").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
                .font(.caption)
                ForEach(fixed + extra, id: \.self) { k in
                    let dayCount = dayCounts[k] ?? 0, allCount = allCounts[k] ?? 0
                    let dayDeleted = dayGone[k] ?? 0, allDeleted = allGone[k] ?? 0
                    // The library only has what is on the card.
                    let dayOnCard = dayCount - dayDeleted, allOnCard = allCount - allDeleted
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Button { open(ShotFilter(field: field, value: k)) } label: {
                            Text(field.label(k)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .disabled(allOnCard == 0)
                        .help("라이브러리에서 \(field.label(k)) 사진 \(allOnCard)장 보기")
                        Button { open(ShotFilter(field: field, value: k, day: self.day)) } label: {
                            split(dayOnCard, dayDeleted).underline(dayOnCard > 0)
                        }
                        .disabled(dayOnCard == 0)
                        .help("이 날의 \(field.label(k)) 사진만 보기")
                        split(allOnCard, allDeleted)
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
    /// Opens the library on `day`; nil when no day is picked.
    var open: (() -> Void)?

    private var calendar: Calendar { .current }

    var body: some View {
        let busiest = max(counts.values.max() ?? 1, 1)
        GroupBox {
            if let open, let day {
                HStack {
                    Spacer()
                    Button(calendar.isDateInToday(day) ? "오늘 사진 보기" : "선택 날짜 사진 보기", action: open)
                        .buttonStyle(.borderless).font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 6).padding(.top, 2)
            }
            VStack(spacing: 10) {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(month.formatted(.dateTime.year().month(.wide))).font(.title3.bold())
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless)
                // A plain grid, not a lazy one: lazy grids guess heights while off screen, which
                // left the stats page short of its top after scrolling back up.
                let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                            Text(name).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        GridRow {
                            ForEach(0..<7, id: \.self) { i in
                                Group {
                                    if i < week.count, let date = week[i] { cell(date, busiest: busiest) } else { Color.clear.frame(height: 40) }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
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
