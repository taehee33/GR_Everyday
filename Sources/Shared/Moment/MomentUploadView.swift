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
/// A file without GR shot info (a film GR scan, a GR DIGITAL file) stops at `choosingCamera`:
/// the owner picks the camera from `MomentShotInfo.declarableCameras`, and only that camera is
/// kept as shot info (the file's own metadata is the scanner's or the phone's).
@MainActor
final class MomentUploadModel: ObservableObject {
    enum Phase: Equatable {
        case picking
        case preparing
        /// No GR shot info in the file: waiting for the owner to pick the camera.
        case choosingCamera
        case ready
        case uploading
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .picking
    @Published private(set) var rendered: MomentImage.Rendered?
    /// The original kept for framing (자르기·회전), and how it is framed now.
    @Published private(set) var loaded: MomentImage.Loaded?
    @Published private(set) var edit = MomentCropEdit()
    @Published private(set) var reframing = false
    @Published private(set) var fullInfo = MomentShotInfo()
    @Published var options = MomentShareOptions.load()
    @Published var caption = ""
    @Published var shareNow = false
    @Published private(set) var uploaded: MomentPhoto?
    /// The files waiting for a camera while `choosingCamera`.
    private var pendingFiles: [URL] = []

    /// The camera the owner picked, for a photo without GR shot info.
    var declaredCamera: String? { fullInfo.isCameraDeclared ? fullInfo.camera : nil }

    /// True when the owner picked a film GR: the form then asks for the film.
    var isFilmCamera: Bool { declaredCamera.map(MomentShotInfo.filmCameras.contains) ?? false }

    /// The film row: nothing, one of `MomentShotInfo.filmChoices`, or typed in `customFilm`.
    enum FilmChoice: Hashable { case none, preset(String), custom }
    @Published var filmChoice: FilmChoice = .none
    @Published var customFilm = ""

    /// The film shared with a film GR photo, or nil.
    var film: String? {
        guard isFilmCamera else { return nil }
        switch filmChoice {
        case .none: return nil
        case .preset(let name): return name
        case .custom:
            let text = customFilm.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(MomentShotInfo.filmLimit))
        }
    }

    /// Where the location comes from: none, the photo's own GPS, or a spot picked on the map.
    enum LocationChoice: Hashable { case none, photo, map }
    @Published var locationChoice: LocationChoice = .none
    @Published var mapLocation: CLLocationCoordinate2D?
    @Published var mapPlace: String?
    /// A place name the owner types (or the map fills in); shared with the photo.
    @Published var placeName = ""

    var photoHasLocation: Bool { fullInfo.lat != nil && fullInfo.lon != nil }

    /// What gets stored with the photo: the chosen groups, and the exact location when the
    /// owner chose to share one (2026-11-13: no longer rounded).
    var sharedInfo: MomentShotInfo {
        var groups = options
        groups.location = .off
        // A picked camera is the only thing saying the photo is a GR, so it is always shared.
        if declaredCamera != nil { groups.camera = true }
        var info = fullInfo.shared(groups)
        info.film = info.camera == nil ? nil : film
        switch locationChoice {
        case .photo:
            if let lat = fullInfo.lat, let lon = fullInfo.lon { info.lat = lat; info.lon = lon }
        case .map:
            if let c = mapLocation { info.lat = c.latitude; info.lon = c.longitude }
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
        guard files.contains(where: MomentImage.isImage) else {
            phase = .failed("사진 파일만 올릴 수 있어요.")
            return
        }
        loaded = nil
        edit = MomentCropEdit()
        filmChoice = .none
        customFilm = ""
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let loaded = try MomentImage.load(files)
                let image = try MomentImage.render(loaded, edit: MomentCropEdit())
                return (loaded, image, MomentShotInfo.read(image.source))
            }.value
            loaded = result.0
            rendered = result.1
            fullInfo = result.2
            locationChoice = options.location == .approximate && photoHasLocation ? .photo : .none
            mapLocation = nil
            mapPlace = nil
            phase = .ready
        } catch MomentImage.Failure.notGROriginal {
            pendingFiles = files
            phase = .choosingCamera
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Builds the upload images for the waiting file with the camera the owner picked. Nothing
    /// else is read from the file: no exposure, date or location.
    func prepare(camera: String) async {
        let files = pendingFiles
        guard !files.isEmpty, MomentShotInfo.declarableCameras.contains(camera) else { return }
        phase = .preparing
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let loaded = try MomentImage.load(files, declared: true)
                return (loaded, try MomentImage.render(loaded, edit: MomentCropEdit()))
            }.value
            loaded = result.0
            rendered = result.1
            fullInfo = MomentShotInfo(camera: camera, cameraSource: .declared)
            locationChoice = .none
            mapLocation = nil
            mapPlace = nil
            pendingFiles = []
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Changes the picked camera on the upload form.
    func changeDeclaredCamera(_ camera: String) {
        guard declaredCamera != nil, MomentShotInfo.declarableCameras.contains(camera) else { return }
        fullInfo.camera = camera
    }

    /// Turns and crops the photo as framed, and builds the upload files again.
    func reframe(_ new: MomentCropEdit) async {
        guard let loaded, new != edit else { return }
        reframing = true
        defer { reframing = false }
        do {
            rendered = try await Task.detached(priority: .userInitiated) {
                try MomentImage.render(loaded, edit: new)
            }.value
            edit = new
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
        loaded = nil
        edit = MomentCropEdit()
        fullInfo = MomentShotInfo()
        pendingFiles = []
        caption = ""
        shareNow = false
        uploaded = nil
        locationChoice = .none
        mapLocation = nil
        mapPlace = nil
        placeName = ""
        filmChoice = .none
        customFilm = ""
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
    @State private var cropping = false
    /// The film GR just picked in `cameraChoice`; its film is asked next, before the form.
    @State private var filmCamera: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.phase == .done ? "" : "사진 업로드")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if model.phase != .done {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("취소") { dismiss() }
                                .disabled(model.phase == .uploading)
                        }
                    }
                }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.jpeg, .rawImage, .image],
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
        case .choosingCamera:
            if let filmCamera { filmChoice(for: filmCamera) } else { cameraChoice }
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

    #if os(iOS)
    /// The app's saved photos first; Photos and Files pickers below for anything else.
    private var pickButtons: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("GR 원본(JPG·DNG)만 올릴 수 있어요. 자르기와 회전은 올리기 전에 해요.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let q = account.quota {
                        Text("벽 \(q.wallUsed)/\(q.wallLimit)")
                            .font(.footnote.monospacedDigit()).foregroundStyle(q.wallFull ? .red : .secondary)
                    }
                }
                SavedPhotosGrid(folder: saveFolder, onPick: { await model.prepare($0) }, openLibrary: {
                    dismiss()
                    NotificationCenter.default.post(name: .openLibraryTab, object: nil)
                })
                Divider()
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $photoItem, matching: .images, preferredItemEncoding: .current) {
                            Label("사진 앱에서", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("다른 위치에서", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    Text("필름 GR 스캔본이나 촬영 정보가 빠진 GR 사진은 여기서 고르면 카메라를 직접 지정해 올릴 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .disabled(account.quota?.wallFull == true)
    }
    #else
    private var pickButtons: some View {
        VStack(spacing: 14) {
            Text("GR로 찍은 원본 사진(JPG 또는 DNG)을 골라 주세요. 편집하지 않은 카메라 원본만 올릴 수 있어요. 올리기 전에 자르기와 회전은 할 수 있어요.\n필름 GR 스캔본이나 촬영 정보가 빠진 GR 사진은 카메라를 직접 골라 올릴 수 있어요.")
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
    #endif

    /// The "popup" for a photo without GR shot info: pick the camera, or pick another photo.
    private var cameraChoice: some View {
        Form {
            Section {
                Label("이 사진에는 GR 촬영 정보가 없어요", systemImage: "questionmark.circle")
                    .font(.headline)
                Text("필름 GR 스캔본이나 촬영 정보가 빠진 GR 사진이라면 카메라를 골라 올릴 수 있어요. 직접 고른 카메라는 사진 정보(i)에 \u{201C}직접 선택\u{201D}으로 표시되고, 노출·촬영 일시·위치 같은 파일 속 정보는 쓰지 않아요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("필름") {
                ForEach(MomentShotInfo.filmCameras, id: \.self) { cameraButton($0) }
            }
            Section("디지털") {
                ForEach(MomentShotInfo.digitalCameras, id: \.self) { cameraButton($0) }
            }
            Section {
                Button("다른 사진 고르기") { model.reset() }
            } footer: {
                Text("GR II 이후 모델은 편집하지 않은 카메라 원본(JPG·DNG)을 올리면 노출·이미지 컨트롤까지 자동으로 들어가요. GR로 찍지 않은 사진은 신고될 수 있어요.")
            }
        }
        .formStyle(.grouped)
    }

    private func cameraButton(_ camera: String) -> some View {
        Button {
            if MomentShotInfo.filmCameras.contains(camera) {
                filmCamera = camera
            } else {
                Task { await model.prepare(camera: camera) }
            }
        } label: {
            HStack {
                Text(camera).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The step after picking a film GR: which film was in it. Can be skipped.
    private func filmChoice(for camera: String) -> some View {
        Form {
            Section {
                Label("\(camera)에 넣은 필름", systemImage: "film")
                    .font(.headline)
                Text("고른 필름은 디지털 GR의 이미지 컨트롤 자리에 보여요. 목록에 없으면 직접 입력해 주세요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("직접 입력") {
                HStack {
                    TextField("필름 이름 (예: Kodak Portra 400)", text: $model.customFilm)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { useCustomFilm(camera) }
                        .onChange(of: model.customFilm) { _, text in
                            if text.count > MomentShotInfo.filmLimit {
                                model.customFilm = String(text.prefix(MomentShotInfo.filmLimit))
                            }
                        }
                    Button("다음") { useCustomFilm(camera) }
                        .disabled(model.customFilm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("필름") {
                ForEach(MomentShotInfo.filmChoices, id: \.self) { name in
                    listButton(name) { pickFilm(.preset(name), camera: camera) }
                }
            }
            Section {
                Button("필름 정보 없이 올리기") { pickFilm(.none, camera: camera) }
                Button("카메라 다시 고르기") { filmCamera = nil }
            }
        }
        .formStyle(.grouped)
    }

    private func useCustomFilm(_ camera: String) {
        guard !model.customFilm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pickFilm(.custom, camera: camera)
    }

    private func pickFilm(_ choice: MomentUploadModel.FilmChoice, camera: String) {
        model.filmChoice = choice
        filmCamera = nil
        Task { await model.prepare(camera: camera) }
    }

    private func listButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var form: some View {
        Form {
            if let rendered = model.rendered {
                Section {
                    PreviewImage(data: rendered.display)
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)
                        .overlay {
                            if model.reframing { ProgressView() }
                        }
                    VStack(spacing: 10) {
                        Text("\(rendered.source.lastPathComponent) · \(Int(rendered.displaySize.width))×\(Int(rendered.displaySize.height)) · \(rendered.display.count / 1024) KB")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        Button {
                            cropping = true
                        } label: {
                            Label(model.edit.isEdited ? "다시 자르기" : "자르기·회전", systemImage: "crop.rotate")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(model.loaded == nil || model.reframing || model.phase == .uploading)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            Section {
                CaptionBox(text: $model.caption)
            } header: {
                Label("캡션", systemImage: "text.bubble").font(.headline)
            }
            Section {
                if let declared = model.declaredCamera {
                    Picker(selection: Binding(get: { declared }, set: { model.changeDeclaredCamera($0) })) {
                        ForEach(MomentShotInfo.declarableCameras, id: \.self) { Text($0).tag($0) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("카메라")
                            Text("직접 선택 · 항상 공유돼요").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.isFilmCamera { filmRow }
                } else {
                    infoToggle("카메라", isOn: $model.options.camera, value: model.fullInfo.camera)
                }
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
                    Label("사진에 기록된 위치를 그대로 공유해요.", systemImage: "location")
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
                Text("장소 이름은 직접 써도 되고, 지도에서 고르면 자동으로 채워져요. 공유한 위치는 사진 정보(i)에서 지도로 볼 수 있어요.")
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
                Text("공유하지 않으면 내 갤러리에만 올라가요. 나중에 갤러리에서 공유할 수도 있어요.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { uploadBar }
        .sheet(isPresented: $cropping) {
            if let loaded = model.loaded {
                MomentPhotoCropper(original: loaded.image, start: model.edit) { edit in
                    Task { await model.reframe(edit) }
                }
            }
        }
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

    /// Always in reach at the bottom, so the form can scroll under it.
    private var uploadBar: some View {
        VStack(spacing: 6) {
            Button {
                Task {
                    await model.upload(with: account.store)
                    await account.reloadPhotos()
                    if account.feed.loaded { await account.feed.reload() }
                }
            } label: {
                HStack(spacing: 8) {
                    if model.phase == .uploading {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("올리는 중…")
                    } else {
                        Image(systemName: model.shareNow ? "sparkles" : "arrow.up")
                        Text(model.shareNow ? "올리고 순간들에 공유" : "내 갤러리에 올리기")
                    }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(model.phase == .uploading || model.reframing || model.rendered == nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var doneView: some View {
        UploadDoneView(
            display: model.rendered?.display,
            shared: model.uploaded?.isShared == true,
            shareMissed: model.shareNow && model.uploaded?.isShared == false,
            caption: model.uploaded == nil ? nil : {
                let text = model.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }(),
            details: [model.sharedInfo.camera, model.sharedInfo.film, model.sharedInfo.place].compactMap { $0 },
            again: { model.reset() },
            close: { dismiss() }
        )
    }

    /// For a film GR: pick the film from the list, or type it.
    @ViewBuilder private var filmRow: some View {
        Picker(selection: $model.filmChoice) {
            Text("선택 안 함").tag(MomentUploadModel.FilmChoice.none)
            ForEach(MomentShotInfo.filmChoices, id: \.self) { Text($0).tag(MomentUploadModel.FilmChoice.preset($0)) }
            Text("직접 입력").tag(MomentUploadModel.FilmChoice.custom)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("필름")
                Text("이미지 컨트롤 자리에 보여요").font(.caption).foregroundStyle(.secondary)
            }
        }
        if model.filmChoice == .custom {
            TextField("필름 이름 (예: Kodak Portra 400)", text: $model.customFilm)
                .autocorrectionDisabled()
                .onChange(of: model.customFilm) { _, text in
                    if text.count > MomentShotInfo.filmLimit {
                        model.customFilm = String(text.prefix(MomentShotInfo.filmLimit))
                    }
                }
        }
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

/// After uploading: the photo itself, large and lifted off a soft wash of its own colours, with
/// where it went underneath. It settles in with a little spring and a success tap.
private struct UploadDoneView: View {
    let display: Data?
    let shared: Bool
    let shareMissed: Bool
    let caption: String?
    let details: [String]
    let again: () -> Void
    let close: () -> Void

    @State private var shown = false

    var body: some View {
        ZStack {
            // Ambient wash: the photo, blurred far out.
            if let display {
                Color.clear
                    .overlay { PreviewImage(data: display, fill: true) }
                    .clipped()
                    .blur(radius: 70)
                    .opacity(shown ? 0.55 : 0)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            Rectangle().fill(.background.opacity(0.35)).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 16)
                if let display {
                    PreviewImage(data: display)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
                        .shadow(color: .black.opacity(0.28), radius: 28, y: 18)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: shared ? "sparkles" : "checkmark")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(shared ? Color.accentColor : .green))
                                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                                .offset(x: 14, y: 14)
                                .scaleEffect(shown ? 1 : 0.2)
                                .opacity(shown ? 1 : 0)
                                .animation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.35), value: shown)
                        }
                        .frame(maxHeight: 420)
                        .padding(.horizontal, 40)
                        .rotationEffect(.degrees(shown ? 0 : -3))
                        .scaleEffect(shown ? 1 : 0.86)
                        .offset(y: shown ? 0 : 40)
                        .opacity(shown ? 1 : 0)
                }

                VStack(spacing: 8) {
                    Text(shared ? "순간들에 공유했어요" : "내 갤러리에 올렸어요")
                        .font(.title2.weight(.bold))
                    if let caption {
                        Text("\u{201C}\(caption)\u{201D}")
                            .font(.callout).italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    if !details.isEmpty {
                        Text(details.joined(separator: "  ·  "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        chip("내 갤러리", on: true)
                        chip("순간들 피드", on: shared)
                    }
                    .padding(.top, 4)
                    if shareMissed {
                        Text("이번 달 공유 횟수를 다 써서 피드에는 올리지 못했어요.\n다음 달에 갤러리에서 공유할 수 있어요.")
                            .font(.footnote).foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 12)
                .animation(.easeOut(duration: 0.4).delay(0.2), value: shown)

                Spacer(minLength: 16)

                VStack(spacing: 4) {
                    Button(action: close) {
                        Text("완료").font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    Button(action: again) {
                        Label("한 장 더 올리기", systemImage: "plus")
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.35).delay(0.45), value: shown)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) { shown = true }
        }
        .sensoryFeedback(.success, trigger: shown) { _, new in new }
    }

    private func chip(_ title: String, on: Bool) -> some View {
        Label(title, systemImage: on ? "checkmark" : "minus")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .background(Capsule().fill(.thinMaterial))
            .opacity(on ? 1 : 0.7)
    }
}

/// Shows encoded image data (the upload preview) on either platform.
private struct PreviewImage: View {
    let data: Data
    var fill = false

    var body: some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
        }
        #else
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
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
