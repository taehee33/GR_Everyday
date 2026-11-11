import ImageIO
import SwiftUI

/// One shot in the app's save folder: its JPG and/or DNG (same base name).
struct SavedShot: Identifiable, Hashable {
    let id: String
    let files: [URL]
    let date: Date
    /// The file to draw the grid thumbnail from (the JPG when there is one).
    var preview: URL { files.first(where: MomentImage.isJPEG) ?? files[0] }
    var hasRAW: Bool { files.contains(where: MomentImage.isDNG) }
}

enum SavedShots {
    /// JPG/DNG files in the save folder (and its date subfolders), newest first. Runs off the
    /// main thread; the folder is the one set in Settings (LibraryModel.destination), so it
    /// follows the user if they moved it.
    static func scan(_ folder: URL, limit: Int = 600) async -> [SavedShot] {
        await Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return [] }
            var groups: [String: (files: [URL], date: Date)] = [:]
            for case let url as URL in walker {
                if walker.level > 2 { walker.skipDescendants(); continue }
                guard MomentImage.isJPEG(url) || MomentImage.isDNG(url) else { continue }
                let id = url.deletingPathExtension().path
                let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                var group = groups[id] ?? ([], date)
                group.files.append(url)
                group.date = max(group.date, date)
                groups[id] = group
            }
            return groups.map { SavedShot(id: $0.key, files: $0.value.files, date: $0.value.date) }
                .sorted { $0.date > $1.date }
                .prefix(limit).map { $0 }
        }.value
    }

    /// "~/Pictures/GR" for the hint under the grid.
    static func displayPath(_ folder: URL) -> String {
        #if os(macOS)
        let home = FolderAccess.realHome.path
        let path = folder.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        #else
        return "파일 앱 › GR Everyday"
        #endif
    }
}

/// The save folder as a grid to pick one shot from.
struct SavedShotsGrid: View {
    let folder: URL
    let onPick: (SavedShot) -> Void
    @State private var shots: [SavedShot]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("저장한 사진", systemImage: "folder").font(.headline)
                Spacer()
                Text(SavedShots.displayPath(folder)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let shots {
                if shots.isEmpty {
                    Text("이 폴더에 GR 사진(JPG·DNG)이 없어요. 아래에서 다른 위치를 골라 주세요.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 130), spacing: 4)], spacing: 4) {
                            ForEach(shots) { shot in
                                Button { onPick(shot) } label: { ShotThumb(shot: shot) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(minHeight: 200, maxHeight: 360)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: folder) { shots = await SavedShots.scan(folder) }
    }
}

private struct ShotThumb: View {
    let shot: SavedShot
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
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
            .contentShape(Rectangle())
            .task(id: shot.id) { image = await Self.thumbnail(shot.preview) }
    }

    /// The file's embedded thumbnail when it has one (fast), otherwise a small render.
    static func thumbnail(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 260,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        }.value
    }
}
