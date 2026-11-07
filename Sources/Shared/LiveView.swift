import SwiftUI

final class LiveViewStream: NSObject, ObservableObject, URLSessionDataDelegate {
    @MainActor @Published var frame: PlatformImage?
    @MainActor @Published var error: String?

    private var session: URLSession?
    private var buffer = Data()

    @MainActor func start() {
        stop()
        error = nil
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session?.dataTask(with: CameraAPI.liveViewURL()).resume()
    }

    @MainActor func stop() {
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        // Frames are JPEGs separated by multipart headers: cut from SOI (FFD8) to EOI (FFD9).
        var latest: Data?
        while let soi = buffer.range(of: Data([0xFF, 0xD8])),
              let eoi = buffer.range(of: Data([0xFF, 0xD9]), in: soi.upperBound..<buffer.endIndex) {
            latest = buffer.subdata(in: soi.lowerBound..<eoi.upperBound)
            buffer.removeSubrange(buffer.startIndex..<eoi.upperBound)
        }
        if buffer.count > 4 << 20 { buffer.removeAll() }
        if let latest, let image = PlatformImage(data: latest) {
            Task { @MainActor in self.frame = image }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in self.error = "라이브뷰 끊김: \(error.localizedDescription)" }
    }
}

struct GridOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3, y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
