import SwiftUI

/// One of my photos on the wall: the full view, caption, place and shot info, and what can be
/// done with it (share to 순간들, take it off the feed, delete).
struct MomentPhotoDetail: View {
    @ObservedObject var account: MomentAccount
    let photoID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnshare = false
    @State private var confirmDelete = false

    private var photo: MomentPhoto? { account.myPhotos.first { $0.id == photoID } }

    var body: some View {
        NavigationStack {
            Group {
                if let photo {
                    content(photo)
                } else {
                    Text("사진을 찾을 수 없어요.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("내 사진")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    private func content(_ photo: MomentPhoto) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MomentFullImage(store: account.store, photo: photo)

                statusLine(photo)

                if let caption = photo.caption {
                    Text(caption).font(.body).textSelection(.enabled)
                }

                MomentInfoSection(info: photo.info)

                actions(photo)

                if let message = account.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .confirmationDialog("순간들 피드에서 내릴까요?", isPresented: $confirmUnshare, titleVisibility: .visible) {
            Button("피드에서 내리기", role: .destructive) { Task { await account.unshare(photo) } }
        } message: {
            Text("벽에는 그대로 남아요. 이번 달 공유 횟수는 돌아오지 않아요.")
        }
        .confirmationDialog("이 사진을 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                Task { if await account.delete(photo) { dismiss() } }
            }
        } message: {
            Text("벽과 피드에서 사라지고 되돌릴 수 없어요. 이번 달 공유 횟수는 돌아오지 않아요.")
        }
    }

    private func statusLine(_ photo: MomentPhoto) -> some View {
        HStack(spacing: 8) {
            if photo.status == .hidden {
                Label("신고가 쌓여 숨겨졌어요", systemImage: "eye.slash").foregroundStyle(.orange)
            } else if let shared = photo.sharedAt {
                Label("순간들에 공유됨 · \(shared.formatted(date: .abbreviated, time: .omitted))", systemImage: "sparkles")
                    .foregroundStyle(.tint)
            } else {
                Label("내 벽에만 걸려 있어요", systemImage: "square.grid.2x2").foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(photo.likeCount) 좋아요").foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    @ViewBuilder private func actions(_ photo: MomentPhoto) -> some View {
        VStack(spacing: 10) {
            if photo.status == .published {
                if photo.isShared {
                    Button { confirmUnshare = true } label: {
                        Label("피드에서 내리기", systemImage: "xmark.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    let left = account.quota?.sharesLeft ?? 0
                    Button {
                        Task { await account.share(photo) }
                    } label: {
                        VStack(spacing: 2) {
                            Label("순간들에 공유하기", systemImage: "sparkles")
                            Text("이번 달 \(left)번 남았어요").font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(left == 0)
                }
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("삭제", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .disabled(account.busy)
        .padding(.top, 4)
    }
}

/// The full view (3072 px), with the thumbnail blurred underneath until it arrives.
struct MomentFullImage: View {
    let store: MomentStore
    let photo: MomentPhoto

    var body: some View {
        AsyncImage(url: store.displayURL(photo)) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            AsyncImage(url: store.thumbURL(photo)) { image in
                image.resizable().scaledToFit().blur(radius: 2)
            } placeholder: {
                Rectangle().fill(.quaternary)
                    .aspectRatio(CGFloat(photo.width) / CGFloat(max(photo.height, 1)), contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Place and the shot info the owner chose to share.
struct MomentInfoSection: View {
    let info: MomentShotInfo

    var body: some View {
        if let place {
            Label(place, systemImage: "mappin.and.ellipse").font(.callout)
        }
        let rows: [(String, String)] = [
            ("카메라", info.camera),
            ("노출", info.exposureSummary),
            ("이미지 컨트롤", info.imageControlSummary(maxSettings: 12)),
            ("HDF", info.imageControl?.hdf),
            ("촬영 일시", info.takenAt?.formatted(date: .long, time: .shortened)),
        ].compactMap { label, value in value.map { (label, $0) } }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("촬영 정보").font(.headline)
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                        Text(row.1).textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var place: String? {
        if let place = info.place { return place }
        if info.lat != nil { return "대략적인 위치 있음" }
        return nil
    }
}
