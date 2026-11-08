import SwiftUI

/// The (i) sheet in the photo viewer, laid out like GR WORLD's: EXIF, then the shooting
/// settings. Everything here is already on the phone without the camera: the camera's
/// per-photo info (photo-info.json, ~190 bytes a photo) and the maker-note record kept for
/// 촬영 통계. Pixel size and focal length come from the saved file when there is one.
struct PhotoInfoSheet: View {
    @EnvironmentObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let photo: Photo
    @State private var local: PhotoMetadata?

    var body: some View {
        NavigationStack {
            List {
                Section("EXIF") { rows(exif) }
                if photo.kind != .video {
                    Section("촬영 설정") { rows(settings) }
                    let tone = MakerNote.toneSettings(record?.toneParams ?? local?.shot?.toneParams)
                    if !tone.isEmpty {
                        Section {
                            ForEach(tone, id: \.name) { LabeledContent($0.name, value: $0.value) }
                        } header: {
                            Text(toneTitle)
                        } footer: {
                            if tone.contains(where: { $0.name.hasPrefix("?") }) {
                                Text("?는 카메라 메뉴의 어느 항목인지 아직 확인하지 못한 값입니다.")
                            }
                        }
                    }
                }
            }
            .navigationTitle(photo.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .task(id: library.localURL(photo)) {
            guard let url = library.localURL(photo), photo.kind != .video else { return }
            local = await Task.detached { PhotoMetadata.read(url) }.value
        }
    }

    @ViewBuilder private func rows(_ items: [(String, String)]) -> some View {
        if items.isEmpty {
            Text("정보 없음 · 카메라에 연결하면 읽습니다").foregroundStyle(.secondary)
        }
        ForEach(items, id: \.0) { item in
            LabeledContent(item.0, value: item.1)
        }
    }

    private var info: PhotoInfo? { library.infos[photo.id] }
    private var record: ShotRecord? { library.shotRecord(photo) }
    private func extra(_ key: String) -> String? { info?.extras[key].flatMap { $0.isEmpty ? nil : $0 } }

    private var exif: [(String, String)] {
        var out: [(String, String)] = []
        if let model = extra("cameraModel") ?? local?.camera { out.append(("모델", model)) }
        if let date = info?.date ?? record?.date {
            out.append(("촬영 날짜", date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())))
        }
        if let pixels = local?.pixelSize ?? pixelSize { out.append(("기록 사이즈", pixels)) }
        if let bytes = extra("size").flatMap(Int64.init) {
            out.append(("파일 크기", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        guard photo.kind != .video else { return out }
        if let tv = extra("tv").flatMap(Self.shutter) ?? local?.shutter { out.append(("셔터 속도", tv)) }
        if let av = extra("av") { out.append(("조리개 값", "F\(av)")) } else if let av = local?.aperture { out.append(("조리개 값", av)) }
        if let sv = extra("sv") { out.append(("ISO 감도", "ISO\(sv)")) } else if let iso = local?.iso { out.append(("ISO 감도", iso)) }
        if let xv = extra("xv").flatMap(Double.init) { out.append(("노출 보정", String(format: "EV%+.1f", xv).replacingOccurrences(of: "+0.0", with: "0.0"))) }
        if let focal = record?.focal35 {
            out.append(("초점 거리", focal <= 28 ? "\(focal)mm 상당" : "\(focal)mm 상당 (크롭)"))
        } else if let focal = local?.focalLength {
            out.append(("초점 거리", focal))
        }
        return out
    }

    /// "이미지 컨트롤 · 스탠다드"
    private var toneTitle: String {
        let code = record?.imageTone ?? local?.shot?.imageControl?.code
        guard let code else { return "이미지 컨트롤" }
        return "이미지 컨트롤 · " + (MakerNote.imageToneNames[code] ?? "코드 \(code)")
    }

    private var settings: [(String, String)] {
        var out: [(String, String)] = []
        if let mode = record?.mode { out.append(("노출 모드", mode)) }
        if let tone = record?.imageTone {
            out.append(("이미지 컨트롤", MakerNote.imageToneNames[tone] ?? "알 수 없음 (코드 \(tone))"))
        }
        if let hdf = record?.key(.hdf) { out.append(("HDF", hdf)) }
        if let aspect = record?.aspect ?? extra("aspectRatio") { out.append(("화상비율", aspect)) }
        return out
    }

    /// GR IV sizes for 3:2 (verified: 28 / 35 / 50 mm crop); other aspects are left out.
    private var pixelSize: String? {
        guard (record?.aspect ?? extra("aspectRatio")) == "3:2" else { return nil }
        switch record?.focal35 {
        case 28?: return "6192x4128"
        case 35?: return "4944x3296"
        case 50?: return "3504x2336"
        default: return nil
        }
    }

    /// The camera writes shutter speeds as "numerator.denominator": "1.100" is 1/100 s.
    static func shutter(_ text: String) -> String? {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        if parts[0] == 1 { return "1/\(parts[1])" }
        let seconds = Double(parts[0]) / Double(parts[1])
        return seconds >= 1 && seconds == seconds.rounded() ? "\(Int(seconds))\"" : String(format: "%.1f\"", seconds)
    }
}
