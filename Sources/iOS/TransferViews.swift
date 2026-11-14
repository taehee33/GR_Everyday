import SwiftUI
import UIKit

/// Saving progress above the tab bar. While saving: the photo coming in, how far along
/// (by bytes), size and time left, and a stop button in a progress ring. Afterwards: the
/// result, which folds away by itself after a few seconds when nothing went wrong.
/// Tapping it opens the full list.
struct TransferBar: View {
    @EnvironmentObject var library: LibraryModel
    @State private var showList = false
    @State private var confirmStop = false

    var body: some View {
        let s = library.transferSummary
        Button { showList = true } label: {
            HStack(spacing: 12) {
                if library.isTransferring { running(s) } else { finished(s) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .sheet(isPresented: $showList) { TransferListSheet() }
        .confirmationDialog("저장을 멈출까요?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("저장 멈추기", role: .destructive) { library.cancelTransfers() }
        } message: {
            Text("받은 사진은 그대로 남고, 나머지는 나중에 이어서 저장할 수 있어요.")
        }
        .onChange(of: library.isTransferring) { _, saving in
            guard !saving else { return }
            let left = library.transferSummary.unsaved
            UINotificationFeedbackGenerator().notificationOccurred(left == 0 ? .success : .warning)
        }
        // Fold away a clean result; one with failures stays until it's seen.
        .task(id: library.isTransferring) {
            guard !library.isTransferring, library.transferSummary.unsaved == 0 else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !showList else { return }
            withAnimation { library.dismissTransfers() }
        }
    }

    @ViewBuilder private func running(_ s: LibraryModel.TransferSummary) -> some View {
        if let current = s.current {
            Thumb(photo: current.photo, showsTransfer: false)
                .frame(width: 40, height: 40)
                .clipShape(.rect(cornerRadius: 6))
                .allowsHitTesting(false)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text("\(PhotosLibrary.target.toPhotos ? "사진 앱" : "파일 앱")에 저장 중 · \(min(s.finished + 1, s.count))/\(s.count)")
                .font(.subheadline.weight(.semibold))
            Text(TransferText.detail(s))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        Spacer(minLength: 8)
        Button { confirmStop = true } label: {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 3)
                Circle().trim(from: 0, to: s.fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: s.fraction)
                RoundedRectangle(cornerRadius: 2).fill(.primary).frame(width: 10, height: 10)
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("저장 멈추기")
        .accessibilityValue("\(Int(s.fraction * 100))%")
    }

    @ViewBuilder private func finished(_ s: LibraryModel.TransferSummary) -> some View {
        let left = s.unsaved
        Image(systemName: left == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.title2)
            .foregroundStyle(left == 0 ? Color.green : Color.orange)
        VStack(alignment: .leading, spacing: 2) {
            Text(left == 0 ? "저장 완료" : "\(left)장을 저장하지 못했어요")
                .font(.subheadline.weight(.semibold))
            Text(TransferText.result(s))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 8)
        // The whole bar opens the list too, but that isn't obvious. With failures it's the
        // way to what failed and 다시 저장, so it stands out more.
        if left > 0 {
            Button("자세히") { showList = true }
                .buttonStyle(.borderedProminent).controlSize(.small)
        } else {
            Button("자세히") { showList = true }
                .buttonStyle(.bordered).controlSize(.small)
        }
        Button { library.dismissTransfers() } label: {
            Image(systemName: "xmark").font(.footnote.bold()).foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("닫기")
    }
}

/// Every photo of the current or last save: overall progress at the top, then what failed,
/// what's coming in, what's waiting, and (folded) what's done.
struct TransferListSheet: View {
    @EnvironmentObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDone = false

    var body: some View {
        let s = library.transferSummary
        let issues = library.transfers.filter {
            switch $0.status { case .failed, .cancelled: return true; default: return false }
        }
        let running = library.transfers.filter { if case .running = $0.status { return true } else { return false } }
        let waiting = library.transfers.filter { $0.status == .waiting }
        let done = library.transfers.filter { $0.status == .done || $0.status == .skipped }
        NavigationStack {
            List {
                Section { overview(s) }
                if !issues.isEmpty {
                    Section("저장하지 못함 \(issues.count)") { ForEach(issues) { TransferRow(transfer: $0) } }
                }
                if !running.isEmpty {
                    Section("받는 중") { ForEach(running) { TransferRow(transfer: $0) } }
                }
                if !waiting.isEmpty {
                    Section(library.isTransferring ? "대기 \(waiting.count)" : "시작하지 못함 \(waiting.count)") {
                        ForEach(waiting) { TransferRow(transfer: $0) }
                    }
                }
                if !done.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showDone) {
                            ForEach(done) { TransferRow(transfer: $0) }
                        } label: {
                            Text(s.skipped > 0 ? "완료 \(s.done) · 이미 저장됨 \(s.skipped)" : "완료 \(s.done)")
                        }
                    }
                }
            }
            .navigationTitle(library.isTransferring ? "저장 중" : "저장 결과")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if library.isTransferring {
                        Button("멈추기", role: .destructive) { library.cancelTransfers() }
                    } else if s.unsaved > 0 {
                        Button("다시 저장") { library.retryFailed() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func overview(_ s: LibraryModel.TransferSummary) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 6)
                Circle().trim(from: 0, to: library.isTransferring ? s.fraction : 1)
                    .stroke(s.unsaved > 0 && !library.isTransferring ? Color.orange
                                : library.isTransferring ? Color.accentColor : Color.green,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: s.fraction)
                Text(library.isTransferring ? "\(Int(s.fraction * 100))%" : "\(s.done)")
                    .font(.headline.monospacedDigit())
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(library.isTransferring ? "\(s.count)장 중 \(s.finished)장" : TransferText.result(s))
                    .font(.headline)
                Text(library.isTransferring ? TransferText.detail(s) : "\(TransferText.bytes(s.receivedBytes)) 받음")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One photo in the transfer list.
struct TransferRow: View {
    let transfer: LibraryModel.Transfer

    var body: some View {
        HStack(spacing: 12) {
            Thumb(photo: transfer.photo, showsTransfer: false)
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.photo.name).font(.subheadline.monospaced())
                status
            }
            Spacer(minLength: 0)
            trailing
        }
    }

    @ViewBuilder private var status: some View {
        switch transfer.status {
        case .waiting:
            Text(sizeText ?? "대기").font(.caption).foregroundStyle(.secondary)
        case .running(let p):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: p)
                Text([TransferText.bytes(transfer.received), transfer.bytes.map(TransferText.bytes)]
                        .compactMap { $0 }.joined(separator: " / "))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .done:
            Text(transfer.resaved ? "사진 앱에서 지워져 있어 다시 넣음" : sizeText ?? "저장됨")
                .font(.caption).foregroundStyle(.secondary)
        case .skipped:
            Text(PhotosLibrary.target.toPhotos ? "사진 앱에 이미 있어 건너뜀" : "파일 앱에 이미 있어 건너뜀")
                .font(.caption).foregroundStyle(.secondary)
        case .cancelled:
            Text("취소됨").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch transfer.status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .waiting: Image(systemName: "clock").foregroundStyle(.tertiary)
        case .running(let p): Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var sizeText: String? { transfer.bytes.map(TransferText.bytes) }
}

/// The grid's mark for a photo in the current save: waiting, a ring while it comes in, or
/// failed. Done photos already show the saved check.
struct TransferBadge: View {
    let status: LibraryModel.Transfer.Status

    var body: some View {
        switch status {
        case .waiting:
            Image(systemName: "clock.fill").font(.caption)
                .foregroundStyle(.white).shadow(radius: 2)
        case .running(let p):
            ZStack {
                Circle().fill(.black.opacity(0.45))
                Circle().trim(from: 0, to: p)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
            }
            .frame(width: 26, height: 26)
        case .failed, .cancelled:
            Image(systemName: "exclamationmark.circle.fill").font(.title3)
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.white, .red).shadow(radius: 2)
        case .done, .skipped:
            EmptyView()
        }
    }
}

enum TransferText {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// "182MB / 540MB · 4.2MB/s · 약 1분 남음"
    static func detail(_ s: LibraryModel.TransferSummary) -> String {
        var parts = ["\(bytes(s.receivedBytes)) / \(bytes(s.totalBytes))"]
        if let rate = s.bytesPerSecond, rate > 0 { parts.append("\(bytes(Int64(rate)))/s") }
        if let left = s.secondsLeft { parts.append(BackgroundSave.remaining(left)) }
        return parts.joined(separator: " · ")
    }

    /// "10장 저장 · 1장 다시 넣음 · 1장 이미 있음 · 1장 못 함"
    static func result(_ s: LibraryModel.TransferSummary) -> String {
        var parts = ["\(s.done - s.resaved)장 저장"]
        if s.resaved > 0 { parts.append("\(s.resaved)장 다시 넣음") }
        if s.skipped > 0 { parts.append("\(s.skipped)장 이미 있음") }
        if s.unsaved > 0 { parts.append("\(s.unsaved)장 못 함") }
        return parts.joined(separator: " · ")
    }
}
