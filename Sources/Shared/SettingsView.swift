import SwiftUI

/// Camera settings, built from whatever /v1/props reports.
///
/// Every `<key>` that comes with a `<key>List` is settable through
/// PUT /v1/params/camera. Keys this app has no label for are still shown
/// under "기타", so a GR IV-only setting appears without a code change.
struct SettingsView: View {
    @State private var props: [String: Any] = [:]
    @State private var error: String?
    @State private var busyKey: String?
    @State private var showRaw = false

    private static let colorKeys = ["effect"]
    private static let exposureKeys = ["exposureMode", "tv", "av", "sv", "xv", "meteringMode", "WBMode", "focusSetting"]
    private static let fileKeys = ["stillFormat", "stillSize", "shootMode", "captureMode", "movieSize"]
    /// Shown but not changeable from here: switching the GR IV to movie turns its Wi-Fi off.
    private static let readOnly: Set<String> = ["captureMode"]
    /// Not shown: live view size, Wi-Fi channel and playback/capture switching would cut
    /// or confuse the connection this app runs on.
    private static let hidden: Set<String> = ["reso", "channel", "operationMode"]

    static let labels: [String: String] = [
        "effect": "이미지 컨트롤 / 효과",
        "exposureMode": "노출 모드", "tv": "셔터 속도", "av": "조리개", "sv": "ISO", "xv": "노출 보정",
        "meteringMode": "측광", "WBMode": "화이트 밸런스",
        "focusSetting": "초점 방식", "movieSize": "동영상 크기",
        "stillFormat": "파일 형식", "stillSize": "이미지 크기", "captureMode": "촬영 모드", "shootMode": "드라이브",
    ]

    static let valueLabels: [String: String] = [
        "off": "스탠다드", "col_vivid": "비비드", "col_custom1": "사용자 1", "col_custom2": "사용자 2",
        "efc_monochrome": "모노톤", "efc_softMonochrome": "소프트 모노톤", "efc_hardMonochrome": "하드 모노톤",
        "efc_highContrast": "하이 콘트라스트 흑백", "efc_posiFilm": "포지티브 필름", "efc_bleachBypass": "블리치 바이패스",
        "efc_retro": "복고풍", "efc_HDRTone": "HDR 톤", "efc_negaFilm": "네거티브 필름", "efc_cinemaYellow": "시네마톤 (옐로)",
        "efc_cinemaGreen": "시네마톤 (그린)", "efc_cineYellow": "시네마톤 (옐로)", "efc_cineGreen": "시네마톤 (그린)",
        "efc_crossProcess": "크로스 프로세스", "col_custom3": "사용자 3",
        "jpeg": "JPEG", "dng": "RAW", "rawdng": "RAW + JPEG",
        "auto": "자동", "multiwb": "멀티 패턴 AWB", "daylight": "일광", "shade": "그늘", "cloud": "흐림",
        "fluorescent": "형광등", "tungsten": "백열등", "manual": "수동",
        "autoWarm": "자동(따뜻한 색)", "autoWhite": "자동(화이트 우선)", "daylightFluorescent": "주광색 형광등",
        "dayWhiteFluorescent": "주백색 형광등", "coolWhiteFluorescent": "백색 형광등", "warmWhiteFluorescent": "온백색 형광등",
        "cte": "CTE", "manual1": "수동 WB", "colorTemp1": "색온도", "custom1": "사용자 WB 1", "custom2": "사용자 WB 2", "custom3": "사용자 WB 3",
        "multi": "분할 측광", "center": "중앙 중점 측광", "spot": "스폿 측광", "highlight": "하이라이트 중점 측광",
        "single": "1매 촬영", "self2s": "셀프타이머 2초", "self10s": "셀프타이머 10초", "continuous": "연속 촬영",
        "interval": "인터벌", "intervalSelf2s": "인터벌(2초 후)", "intervalSelf10s": "인터벌(10초 후)",
        "intervalComp": "인터벌 합성", "intervalCompSelf2s": "인터벌 합성(2초 후)", "intervalCompSelf10s": "인터벌 합성(10초 후)",
        "multiExp": "다중 노출", "multiExpSelf2s": "다중 노출(2초 후)", "multiExpSelf10s": "다중 노출(10초 후)",
        "bracket": "브라케팅", "bracketSelf2s": "브라케팅(2초 후)", "bracketSelf10s": "브라케팅(10초 후)",
        "still": "사진", "movie": "동영상",
        "L3": "L (3:2)", "M3": "M (3:2)", "S3": "S (3:2)", "XS3": "XS (3:2)",
    ]

    private var settable: [String] {
        props.keys.filter { key in
            key.hasSuffix("List") && props[String(key.dropLast(4))] != nil && props[key] is [Any]
        }
        .map { String($0.dropLast(4)) }
        .sorted()
    }

    var body: some View {
        Form {
            if let error {
                Text(error).foregroundStyle(.red)
            }
            section("색감", keys: Self.colorKeys)
            section("노출", keys: Self.exposureKeys)
            section("파일", keys: Self.fileKeys)
            let known = Set(Self.colorKeys + Self.exposureKeys + Self.fileKeys)
            let others = settable.filter { !known.contains($0) && !Self.hidden.contains($0) }
            if !others.isEmpty { section("기타", keys: others) }
            lockedSection(Self.colorKeys + Self.exposureKeys + Self.fileKeys + others)

            Section {
                DisclosureGroup("카메라가 보고한 원본 값 (props)", isExpanded: $showRaw) {
                    ScrollView {
                        Text(rawJSON).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 240)
                }
            } footer: {
                Text("GR IV의 이미지 컨트롤 세부 조정(채도·색조 등)은 카메라가 이 API로 노출하는 항목만 바꿀 수 있어요. 위 목록에 없는 값은 카메라에서 설정해 주세요.")
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    /// The camera offers a choice for `key` right now (mode dial, current mode).
    static func isChangeable(_ key: String, props: [String: Any]) -> Bool {
        options(key, props: props).count > 1 && !readOnly.contains(key)
    }

    /// The values `key` can take now: the camera's <key>List. The GR IV HDF (fw 1.20) sends
    /// an empty xvList in P although it takes exposure compensation there: setting -4.3 …
    /// 0.0 from the app worked and moved tv/av (verified 2026-11-09). So outside M the
    /// camera's ±5 EV in ⅓ steps is offered, written as it reports them ("+2.0", "-0.7");
    /// CameraAPI.setParams drops the "+" when sending, which the camera requires.
    static func options(_ key: String, props: [String: Any]) -> [String] {
        let listed = (props[key + "List"] as? [Any] ?? []).map { "\($0)" }
        if key == "xv", listed.isEmpty, props["xv"] != nil,
           (props["exposureMode"] as? String)?.uppercased() != "M" {
            return evSteps
        }
        return listed
    }

    static let evSteps: [String] = (-15...15).map { i in
        let v = (Double(i) / 3 * 10).rounded() / 10
        return i > 0 ? String(format: "+%.1f", v) : String(format: "%.1f", v)
    }

    /// Only what can be changed from here; the rest is listed at the bottom.
    @ViewBuilder
    private func section(_ title: String, keys: [String]) -> some View {
        let present = keys.filter { settable.contains($0) && Self.isChangeable($0, props: props) }
        if !present.isEmpty {
            Section(title) {
                ForEach(present, id: \.self) { key in
                    let options = Self.options(key, props: props)
                    Picker(selection: binding(key)) {
                        ForEach(options, id: \.self) { Text(Self.display(key, $0)).tag($0) }
                    } label: {
                        HStack {
                            Text(Self.labels[key] ?? key)
                            if busyKey == key { ProgressView().controlSize(.small) }
                        }
                    }
                    .tint(.accentColor)
                }
            }
        }
    }

    /// Settings fixed by the camera (mode dial, or automatic in this mode), greyed out with
    /// the reason, so they never look like something to tap.
    @ViewBuilder
    private func lockedSection(_ keys: [String]) -> some View {
        let locked = keys.filter { settable.contains($0) && !Self.isChangeable($0, props: props) }
        if !locked.isEmpty {
            Section {
                ForEach(locked, id: \.self) { key in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(Self.labels[key] ?? key)
                                Spacer()
                                Text(props[key].map { Self.display(key, "\($0)") } ?? "-")
                            }
                            Text(Self.lockedReason(key, props: props)).font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("지금은 카메라에서만 바꿀 수 있어요")
            }
        }
    }

    /// focusSetting values; kept apart because "manual" also means WB 수동.
    static let focusLabels: [String: String] = [
        "manual": "MF", "snap": "스냅", "inf": "무한원", "spot": "스폿 AF", "multiauto": "자동 영역 AF",
        "pinpoint": "핀포인트 AF", "tracking": "추적 AF", "continuous": "컨티뉴어스 AF", "zone_select": "존 선택 AF",
    ]

    /// Why the camera offers no choice for `key` right now.
    static func lockedReason(_ key: String, props: [String: Any]) -> String {
        let mode = (props["exposureMode"] as? String)?.uppercased() ?? ""
        switch key {
        case "exposureMode":
            return "노출 모드는 카메라 상단의 모드 다이얼로만 바꿀 수 있어요."
        case "captureMode":
            return "카메라에서 바꿔 주세요. 동영상으로 바꾸면 카메라 Wi-Fi가 꺼져 연결이 끊겨요."
        case "av" where ["P", "TV"].contains(mode):
            return "\(mode) 모드에서는 조리개가 자동이에요. 바꾸려면 모드 다이얼을 Av 또는 M으로 돌려 주세요."
        case "tv" where ["P", "AV"].contains(mode):
            return "\(mode) 모드에서는 셔터 속도가 자동이에요. 바꾸려면 모드 다이얼을 Tv 또는 M으로 돌려 주세요."
        default:
            return "지금 카메라 상태에서는 바꿀 수 없어요."
        }
    }

    /// "1.250" → "1/250", "10.1" → "10\"", "25.10" → "2.5\"".
    static func shutter(_ tv: String) -> String {
        let parts = tv.split(separator: ".")
        guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]), d > 0 else { return tv }
        if d == 1 { return "\(n)\"" }
        if d == 10 { return "\(n / 10).\(n % 10)\"" }
        if n == 1 { return "1/\(d)" }
        return "\(n)/\(d)"
    }

    static func display(_ key: String, _ value: String) -> String {
        if key == "tv" { return shutter(value) }
        if key == "av" { return "F\(value)" }
        if key == "focusSetting" { return focusLabels[value] ?? value }
        return Self.valueLabels[value] ?? value
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { props[key].map { "\($0)" } ?? "" },
            set: { value in Task { await set(key, value) } }
        )
    }

    private var rawJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: props, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func load() async {
        do {
            props = try await CameraAPI.props()
            error = nil
        } catch {
            self.error = "설정을 불러오지 못했어요: \(error.localizedDescription)"
        }
    }

    private func set(_ key: String, _ value: String) async {
        busyKey = key
        defer { busyKey = nil }
        do {
            try await CameraAPI.setParams([key: value])
            error = nil
        } catch {
            self.error = "\(Self.labels[key] ?? key) 변경 실패: \(error.localizedDescription)"
        }
        await load()
    }
}
