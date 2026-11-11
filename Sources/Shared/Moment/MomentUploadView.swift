import CoreLocation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Putting one GR photo on my Photowall (and, if chosen, sharing it to the feed).
/// Flow: pick a file → check it is a GR original and build the upload images → choose which
/// shot info to share → caption → upload. See PLAN-moment.md sections 2–3.
@MainActor
final class MomentUploadModel: ObservableObject {
    enum Phase: Equatable {
        case picking
        case preparing
        case ready
        case uploading
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .picking
    @Published private(set) var rendered: MomentImage.Rendered?
    @Published private(set) var fullInfo = MomentShotInfo()
    @Published var options = MomentShareOptions.load()
    @Published var caption = ""
    @Published var shareNow = false
    @Published private(set) var uploaded: MomentPhoto?

    /// Where the location comes from: none, the photo's own GPS, or a spot picked on the map.
    enum LocationChoice: Hashable { case none, photo, map }
    @Published var locationChoice: LocationChoice = .none
    @Published var mapLocation: CLLocationCoordinate2D?
    @Published var mapPlace: String?
    /// A place name the owner types (or the map fills in); shared with the photo.
    @Published var placeName = ""

    var photoHasLocation: Bool { fullInfo.lat != nil && fullInfo.lon != nil }

    /// What gets stored with the photo: the chosen groups, and a location rounded to ~1 km.
    var sharedInfo: MomentShotInfo {
        var groups = options
        groups.location = .off
        var info = fullInfo.shared(groups)
        func rounded(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        switch locationChoice {
        case .photo:
            if let lat = fullInfo.lat, let lon = fullInfo.lon { info.lat = rounded(lat); info.lon = rounded(lon) }
        case .map:
            if let c = mapLocation { info.lat = rounded(c.latitude); info.lon = rounded(c.longitude) }
        case .none:
            break
        }
        let place = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        info.place = place.isEmpty ? nil : String(place.prefix(40))
        return info
    }

    /// Reads the picked file(s) and builds the 3072 px JPEG and the thumbnail, off the main thread.
    func prepare(_ files: [URL]) async {
        phase = .preparing
        rendered = nil
        guard files.contains(where: { MomentImage.isJPEG($0) || MomentImage.isDNG($0) }) else {
            phase = .failed("GR로 찍은 JPG나 DNG 파일만 올릴 수 있어요.")
            return
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let image = try MomentImage.render(files)
                return (image, MomentShotInfo.read(image.source))
            }.value
            rendered = result.0
            fullInfo = result.1
            locationChoice = options.location == .approximate && photoHasLocation ? .photo : .none
            mapLocation = nil
            mapPlace = nil
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func upload(with store: MomentStore) async {
        guard let rendered else { return }
        phase = .uploading
        if locationChoice != .map { options.location = locationChoice == .photo ? .approximate : .off }
        options.save()
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            uploaded = try await store.upload(MomentUpload(image: rendered, info: sharedInfo,
                                                           caption: text.isEmpty ? nil : String(text.prefix(500)),
                                                           shareNow: shareNow))
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func reset() {
        phase = .picking
        rendered = nil
        fullInfo = MomentShotInfo()
        caption = ""
        shareNow = false
        uploaded = nil
        locationChoice = .none
        mapLocation = nil
        mapPlace = nil
        placeName = ""
    }

    /// Copies a picked file into our temporary folder (keeping its name, so the JPG/DNG
    /// extension survives) and gives up the security scope of the original.
    nonisolated static func copyToTemp(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appending(path: "moment-upload/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }
}

/// A file handed over by the Photos picker, as the original file (not re-encoded).
struct PickedPhotoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedPhotoFile(url: try MomentUploadModel.copyToTemp(received.file))
        }
    }
}

struct MomentUploadView: View {
    @ObservedObject var account: MomentAccount
    /// The app's save folder (Settings may have moved it); its photos are offered first.
    let saveFolder: URL
    @StateObject private var model = MomentUploadModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var pickingLocation = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("사진 올리기")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.phase == .done ? "닫기" : "취소") { dismiss() }
                            .disabled(model.phase == .uploading)
                    }
                }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.jpeg, .rawImage],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                do { await model.prepare([try MomentUploadModel.copyToTemp(url)]) } catch {
                    await model.prepare([])
                }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let file = try? await item.loadTransferable(type: PickedPhotoFile.self) {
                    await model.prepare([file.url])
                } else {
                    await model.prepare([])
                }
                photoItem = nil
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .picking:
            pickButtons
        case .preparing:
            ProgressView("GR 원본인지 확인하고 업로드용 이미지를 만드는 중…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .uploading:
            form
        case .done:
            doneView
        case .failed(let message):
            VStack(spacing: 14) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("다른 사진 고르기") { model.reset() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pickButtons: some View {
        VStack(spacing: 14) {
            Text("GR로 찍은 원본 사진(JPG 또는 DNG)을 골라 주세요. 편집하지 않은 카메라 원본만 올릴 수 있어요.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let q = account.quota {
                Text("벽 \(q.wallUsed)/\(q.wallLimit)")
                    .font(.footnote).foregroundStyle(q.wallFull ? .red : .secondary)
            }
            SavedShotsGrid(folder: saveFolder) { shot in
                Task { await model.prepare(shot.files) }
            }
            Divider()
            #if os(iOS)
            PhotosPicker(selection: $photoItem, matching: .images, preferredItemEncoding: .current) {
                Label("사진 앱에서 고르기", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            Button {
                showFileImporter = true
            } label: {
                Label("다른 위치에서 고르기", systemImage: "folder").frame(maxWidth: 260)
            }
            .buttonStyle(.bordered)
            #else
            Button {
                showFileImporter = true
            } label: {
                Label("다른 위치에서 고르기", systemImage: "folder").frame(maxWidth: 220)
            }
            .buttonStyle(.bordered)
            #endif
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(account.quota?.wallFull == true)
    }

    private var form: some View {
        Form {
            if let rendered = model.rendered {
                Section {
                    PreviewImage(data: rendered.display)
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)
                    Text("\(rendered.source.lastPathComponent) · \(Int(rendered.displaySize.width))×\(Int(rendered.displaySize.height)) · \(rendered.display.count / 1024) KB")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                CaptionBox(text: $model.caption)
            } header: {
                Label("캡션", systemImage: "text.bubble").font(.headline)
            }
            Section {
                infoToggle("카메라", isOn: $model.options.camera, value: model.fullInfo.camera)
                infoToggle("노출", isOn: $model.options.exposure, value: model.fullInfo.exposureSummary)
                infoToggle("이미지 컨트롤", isOn: $model.options.imageControl, value: model.fullInfo.imageControlSummary())
                infoToggle("촬영 일시", isOn: $model.options.takenAt,
                           value: model.fullInfo.takenAt?.formatted(date: .abbreviated, time: .shortened))
            } header: {
                Text("함께 공유할 촬영 정보")
            } footer: {
                Text("사진 파일에는 촬영 정보가 들어가지 않아요. 켠 항목만 따로 저장되고, 올린 뒤에도 끌 수 있어요. 지금 선택은 다음에도 기본값으로 쓰여요.")
            }
            Section {
                Picker("위치", selection: $model.locationChoice) {
                    Text("공유 안 함").tag(MomentUploadModel.LocationChoice.none)
                    if model.photoHasLocation {
                        Text("사진 위치").tag(MomentUploadModel.LocationChoice.photo)
                    }
                    Text("지도에서 고르기").tag(MomentUploadModel.LocationChoice.map)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.locationChoice) { _, choice in
                    if choice == .map, model.mapLocation == nil { pickingLocation = true }
                }
                switch model.locationChoice {
                case .none:
                    Text(model.photoHasLocation ? "위치를 공유하지 않아요." : "이 사진에는 위치 정보가 없어요. 원하면 지도에서 고를 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                case .photo:
                    Label("사진에 기록된 위치를 약 1km 단위로 공유해요.", systemImage: "location")
                        .font(.caption).foregroundStyle(.secondary)
                case .map:
                    HStack {
                        Label(model.mapPlace ?? (model.mapLocation == nil ? "아직 고르지 않았어요" : "고른 위치"),
                              systemImage: "mappin.and.ellipse")
                        Spacer()
                        Button(model.mapLocation == nil ? "지도 열기" : "변경") { pickingLocation = true }
                    }
                }
                TextField("장소 이름 (선택, 예: 성수동 · 남산타워)", text: $model.placeName)
                    .onChange(of: model.placeName) { _, new in
                        if new.count > 40 { model.placeName = String(new.prefix(40)) }
                    }
            } header: {
                Text("위치")
            } footer: {
                Text("장소 이름은 직접 써도 되고, 지도에서 고르면 자동으로 채워져요. 지도 위치는 다른 사람에게 약 1km 단위로만 보여요.")
            }
            Section {
                Toggle(isOn: $model.shareNow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("순간들 피드에 바로 공유하기")
                        if let q = account.quota {
                            Text("이번 달 \(q.sharesLeft)번 남았어요 (한 달 \(q.sharesPerMonth)번)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(account.quota?.sharesLeft == 0)
            } footer: {
                Text("공유하지 않으면 내 Photowall에만 걸려요. 나중에 벽에서 공유할 수도 있어요.")
            }
            Section {
                Button {
                    Task { await model.upload(with: account.store); await account.reloadPhotos() }
                } label: {
                    HStack {
                        Spacer()
                        if model.phase == .uploading {
                            ProgressView().controlSize(.small)
                            Text("올리는 중…")
                        } else {
                            Text("올리기").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(model.phase == .uploading)
                Button("다른 사진 고르기") { model.reset() }
                    .disabled(model.phase == .uploading)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $pickingLocation, onDismiss: {
            if model.locationChoice == .map, model.mapLocation == nil { model.locationChoice = .none }
        }) {
            let start = model.mapLocation
                ?? model.fullInfo.lat.flatMap { lat in model.fullInfo.lon.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } }
            MomentLocationPicker(start: start) { coordinate, place in
                model.mapLocation = coordinate
                model.mapPlace = place
                if model.placeName.isEmpty, let place { model.placeName = place }
            }
        }
    }

    private var doneView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48)).foregroundStyle(.green)
            Text(model.uploaded?.isShared == true ? "벽에 걸고 피드에 공유했어요" : "내 Photowall에 걸었어요")
                .font(.headline)
            if model.shareNow, model.uploaded?.isShared == false {
                Text("이번 달 공유 횟수를 다 써서 피드에는 공유되지 않았어요.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let rendered = model.rendered {
                PreviewImage(data: rendered.thumb).frame(height: 180)
            }
            HStack {
                Button("하나 더 올리기") { model.reset() }
                Button("닫기") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func infoToggle(_ title: String, isOn: Binding<Bool>, value: String?) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(value ?? "정보 없음").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .disabled(value == nil)
    }
}

/// The caption: a framed box with a hint and a 500-character counter, so it reads as a place
/// to write rather than another setting row.
private struct CaptionBox: View {
    @Binding var text: String
    static let limit = 500

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("이 순간에 대해 한마디 남겨 주세요 (선택)")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 160)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            .onChange(of: text) { _, new in
                if new.count > Self.limit { text = String(new.prefix(Self.limit)) }
            }
            Text("\(text.count)/\(Self.limit)")
                .font(.caption).monospacedDigit()
                .foregroundStyle(text.count >= Self.limit ? .red : .secondary)
        }
    }
}

/// Shows encoded image data (the upload preview) on either platform.
private struct PreviewImage: View {
    let data: Data

    var body: some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
        }
        #else
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit()
        }
        #endif
    }
}

/// My uploaded photos, newest first: the start of the Photowall. Tap one for its details.
struct MyMomentsGrid: View {
    @ObservedObject var account: MomentAccount
    @State private var selected: MomentPhoto?

    var body: some View {
        if account.myPhotos.isEmpty {
            Text("아직 올린 사진이 없어요.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 4)], spacing: 4) {
                ForEach(account.myPhotos) { photo in
                    Button { selected = photo } label: {
                    AsyncImage(url: account.store.thumbURL(photo)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if photo.isShared {
                            Image(systemName: "sparkles")
                                .font(.caption2.bold())
                                .padding(4)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(4)
                        }
                    }
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 520)
            .sheet(item: $selected) { photo in
                MomentPhotoDetail(account: account, photoID: photo.id)
            }
        }
    }
}
