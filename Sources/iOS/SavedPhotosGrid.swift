import SwiftUI
import ImageIO

/// 순간들 → 사진 업로드 on iPhone/iPad: the photos this app saved, from 다운로드 기록, newest
/// first, wherever they went (the Photos app, the Files app or both). A JPG and its DNG are
/// one shot. Ones deleted in Photos with no Files copy left drop out.
struct SavedPhotosGrid: View {
    @ObservedObject private var history = SaveHistory.shared
    /// The Files app folder, for photos saved there before 다운로드 기록 existed.
    var folder: URL = URL.documentsDirectory
    @State private var older: [SavedShot] = []
    /// Hands over the shot's original files (copies in a temporary folder or in Documents).
    let onPick: ([URL]) async -> Void
    /// Closes the upload sheet and goes to 라이브러리.
    var openLibrary: (() -> Void)?
    @State private var loading: String?
    @State private var error: String?

    /// One shot: its saves by file name, the JPG first.
    struct Shot: Identifiable {
        let id: String
        let date: Date
        var records: [SaveHistory.Record]
        /// A shot in the Files folder with no record (saved by an older version).
        var files: [URL] = []
        var hasRAW: Bool { records.contains { $0.photo.kind == .raw } || files.contains(where: MomentImage.isDNG) }
        var preview: SaveHistory.Record? { records.first { $0.photo.kind == .jpeg } ?? records.first }
    }

    var body: some View {
        let all = shots
        let usable = all.filter(\.usable)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("앱으로 저장한 사진", systemImage: "square.and.arrow.down").font(.headline)
                Spacer()
                if !usable.isEmpty { Text("\(usable.count)장").font(.subheadline).foregroundStyle(.secondary) }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red)
            }
            if all.contains(where: { $0.needsRead }) && !PhotosLibrary.canRead { accessCard }
            if usable.isEmpty {
                if all.isEmpty { empty }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 130), spacing: 4)], spacing: 4) {
                    ForEach(usable) { shot in
                        Button { pick(shot) } label: { SavedPhotoThumb(shot: shot, loading: loading == shot.id) }
                            .buttonStyle(.plain)
                            .disabled(loading != nil)
                    }
                }
            }
        }
        .onAppear { history.refreshPresence() }
        .task(id: folder) { older = await SavedShots.scan(folder) }
    }

    // MARK: Shots

    private var shots: [Shot] {
        var byKey: [String: Shot] = [:]
        // Newest save of each file name; only JPG and DNG can go to 순간들.
        var seen = Set<String>()
        for r in history.records.reversed() where r.isSave && (r.photo.kind == .jpeg || r.photo.kind == .raw) {
            guard seen.insert(r.name).inserted else { continue }
            let key = ((r.name as NSString).deletingPathExtension).uppercased()
            if var shot = byKey[key] {
                shot.records.append(r)
                byKey[key] = shot
            } else {
                byKey[key] = Shot(id: key, date: r.date, records: [r])
            }
        }
        for shot in older {
            let key = ((shot.files[0].lastPathComponent as NSString).deletingPathExtension).uppercased()
            guard byKey[key] == nil else { continue }
            byKey[key] = Shot(id: key, date: shot.date, records: [], files: shot.files)
        }
        return byKey.values
            .map { var s = $0; s.records.sort { ($0.photo.kind == .jpeg ? 0 : 1) < ($1.photo.kind == .jpeg ? 0 : 1) }; return s }
            .sorted { $0.date > $1.date }
            .prefix(400).map { $0 }
    }

    private func pick(_ shot: Shot) {
        loading = shot.id
        error = nil
        Task {
            defer { loading = nil }
            do {
                var files = shot.files
                var exported = Set<String>()
                for r in shot.records {
                    if let file = r.existingFile {
                        files.append(file)
                    } else if let id = r.assetID, history.photosState(of: r) != .deleted, exported.insert(id).inserted {
                        // A RAW+JPG item holds both files; take each once.
                        for url in try await PhotosLibrary.exportOriginals(id)
                        where !files.contains(where: { $0.lastPathComponent == url.lastPathComponent }) {
                            files.append(url)
                        }
                    }
                }
                guard !files.isEmpty else { throw PhotosLibrary.NotFound() }
                await onPick(files)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder private var accessCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("사진 앱에 저장한 사진을 여기서 바로 고르려면 사진 보관함 접근을 허용해 주세요.")
                .font(.footnote).foregroundStyle(.secondary)
            if history.readStatus == .notDetermined {
                Button("사진 보관함 접근 허용") { Task { await history.requestRead() } }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
            } else {
                Button("설정 앱에서 바꾸기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.arrow.down").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("카메라에서 사진을 저장하면 여기에 바로 보여요.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let openLibrary {
                Button("라이브러리로 가기", action: openLibrary)
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

extension SavedPhotosGrid.Shot {
    /// Can be picked now: a Files copy, or a Photos item the app can read.
    @MainActor var usable: Bool {
        !files.isEmpty || records.contains { r in
            if r.existingFile != nil { return true }
            guard r.assetID != nil, PhotosLibrary.canRead else { return false }
            return SaveHistory.shared.photosState(of: r) != .deleted
        }
    }

    /// Only in Photos, and the library can't be read yet.
    @MainActor var needsRead: Bool {
        !PhotosLibrary.canRead && files.isEmpty && !records.isEmpty && records.allSatisfy { $0.existingFile == nil && $0.assetID != nil }
    }
}

extension SaveHistory.Record {
    /// The Files app copy, when it's still there.
    var existingFile: URL? {
        fileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
}

private struct SavedPhotoThumb: View {
    let shot: SavedPhotosGrid.Shot
    let loading: Bool
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if shot.hasRAW {
                    Text("RAW").font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay { if loading { ZStack { Color.black.opacity(0.35); ProgressView().tint(.white) } } }
            .contentShape(Rectangle())
            .task(id: shot.id) { image = await load() }
    }

    private func load() async -> UIImage? {
        let previewFile = shot.files.first(where: MomentImage.isJPEG) ?? shot.files.first ?? shot.preview?.existingFile
        if let file = previewFile {
            return await Task.detached(priority: .utility) {
                guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 260,
                ]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
            }.value
        }
        for id in shot.records.compactMap(\.assetID) {
            if let image = await PhotosLibrary.thumbnail(id, side: 260) { return image }
        }
        return nil
    }
}
