import AVFoundation
import Foundation
import ImageCaptureCore
import ImageIO
#if os(macOS)
import IOKit
#endif
import Network

/// A GR on a USB cable (Mac, or iPhone/iPad through a USB camera adapter / USB-C). It shows up as a PTP camera (USB class 6), not as a drive, and
/// over PTP it only offers its files: no live view, shooting or settings.
///
/// The library speaks the camera's Wi-Fi HTTP API everywhere (list, thumbnails, previews,
/// downloads, video), so a small server on 127.0.0.1 answers that API from the USB camera
/// and CameraAPI.base points at it while connected by USB.
@MainActor
final class USBCamera: NSObject, ObservableObject {
    /// A GR the Mac sees on USB, opened or not.
    @Published private(set) var detected: ICCameraDevice?
    /// The camera whose files the local server serves.
    @Published private(set) var serving: ICCameraDevice?
    /// Called when the served camera is unplugged or switched off.
    var onRemoved: (() -> Void)?

    private let browser = ICDeviceBrowser()
    /// Battery percent read over PTP while serving, refreshed every minute.
    private var battery: Int?
    private var batteryTask: Task<Void, Never>?
    private var transactionID: UInt32 = 0x1000
    /// Restarts the browser when the GR is on the bus but never reported (see watch()).
    private var watchdog: Task<Void, Never>?
    /// Waiting for the PTP session to open, then for the full file list.
    private var opened: CheckedContinuation<Void, Error>?
    private var ready: CheckedContinuation<Void, Error>?
    private var files: [String: ICCameraFile] = [:]
    private var server: LocalServer?
    /// Recently read originals, for previews of the same photo at several sizes.
    private var recent: [(id: String, data: Data)] = []

    struct USBError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    override init() {
        super.init()
        browser.delegate = self
        #if os(macOS)
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        #else
        // iOS has only local devices; a mask with the location bit may match nothing there.
        browser.browsedDeviceTypeMask = .camera
        #endif
        #if os(macOS)
        browser.start()
        watch()
        #else
        // iOS asks the user before an app may see a camera's files; ask only once one is
        // asked for (connect, or the camera tab offering USB), not at launch.
        if browser.contentsAuthorizationStatus == .authorized { browser.start() }
        #endif
    }

    #if os(iOS)
    /// Whether the user denied access to cameras' files on USB (then only Settings can change
    /// it). Control access (PTP commands: the battery level) is optional.
    var accessDenied: Bool { browser.contentsAuthorizationStatus == .denied }

    /// Ask for access to the files of cameras on USB, then start looking for one.
    func requestAccess() async {
        if browser.contentsAuthorizationStatus != .authorized {
            _ = await withCheckedContinuation { c in browser.requestContentsAuthorization { c.resume(returning: $0) } }
        }
        if browser.controlAuthorizationStatus != .authorized {
            _ = await withCheckedContinuation { c in browser.requestControlAuthorization { c.resume(returning: $0) } }
        }
        DebugLog.write("usb: access contents \(browser.contentsAuthorizationStatus.rawValue) control \(browser.controlAuthorizationStatus.rawValue) browsing \(browser.isBrowsing)")
        if browser.contentsAuthorizationStatus == .authorized, !browser.isBrowsing {
            browser.start()
            DebugLog.write("usb: browser started")
        }
        objectWillChange.send()
    }
    #endif

    #if os(macOS)
    /// Once (2026-11-01) the browser stayed silent while macOS listed the GR on USB, after
    /// the Mac's Bluetooth had been restarting for an hour; a new browser (app relaunch)
    /// found it at once. So while nothing is detected, look at the USB registry and start
    /// the browser again if a Ricoh device is there, at most every 30 s.
    private func watch() {
        watchdog = Task { [weak self] in
            var lastRestart = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.detected == nil, Date().timeIntervalSince(lastRestart) > 30 else { continue }
                guard await Task.detached(operation: { Self.ricohOnUSB() }).value, self.detected == nil else { continue }
                DebugLog.write("usb: GR on the bus but not reported; restarting the device browser")
                lastRestart = Date()
                self.browser.stop()
                self.browser.start()
            }
        }
    }

    /// Whether a Ricoh device (USB vendor 0x25FB) is attached, from the IOKit registry.
    nonisolated static func ricohOnUSB() -> Bool {
        let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        // A plain "idVendor" key matches nothing for IOUSBHostDevice; it has to be a property match.
        match[kIOPropertyMatchKey] = ["idVendor": 0x25FB]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match as CFDictionary, &iterator) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }
    #endif

    /// Open the camera's PTP session, read its file list and start the local server.
    /// Returns the base URL that answers the camera API.
    func open() async throws -> URL {
        #if os(iOS)
        await requestAccess()
        if accessDenied {
            throw USBError(message: "USB 카메라 접근이 꺼져 있어요. 설정 → GR Everyday에서 허용해 주세요.")
        }
        // The browser reports a camera that was already plugged in shortly after it starts.
        for _ in 0..<40 where detected == nil { try? await Task.sleep(for: .milliseconds(250)) }
        DebugLog.write("usb: after waiting, detected \(detected?.name ?? "none"), devices \(browser.devices?.map { $0.name ?? "?" } ?? [])")
        #endif
        guard let camera = detected else {
            #if os(iOS)
            throw USBError(message: "USB로 연결된 GR이 없어요. 카메라 어댑터(또는 USB-C 케이블)로 연결하고 카메라를 켜 주세요.")
            #else
            throw USBError(message: "USB로 연결된 GR이 없어요. 케이블을 연결하고 카메라를 켜 주세요.")
            #endif
        }
        if serving !== camera {
            DebugLog.write("usb: opening \(camera.name ?? "?")")
            try await withTimeout(30, "카메라가 USB로 응답하지 않아요. 카메라를 켜고 케이블을 다시 연결해 주세요.") {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    self.opened = c
                    camera.requestOpenSession()
                }
            }
            // The system reads every file's details before the list is complete: about 36 s for
            // 648 files on the GR IV, so this wait grows with the card.
            if camera.contentCatalogPercentCompleted < 100 {
                try await withTimeout(600, "USB로 사진 목록을 다 읽지 못했어요. 케이블을 다시 연결해 보세요.") {
                    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                        self.ready = c
                    }
                }
            }
            DebugLog.write("usb: catalog complete")
        }
        index(camera)
        if server == nil {
            let server = LocalServer { [weak self] request in
                guard let self else { return .error(503, "closed") }
                return await self.answer(request)
            }
            try await server.start()
            self.server = server
        }
        serving = camera
        batteryTask?.cancel()
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.serving === camera else { return }
                self.battery = await self.readBattery(camera)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        DebugLog.write("usb: serving \(files.count) files at \(server!.base)")
        return server!.base
    }

    func close() {
        batteryTask?.cancel()
        battery = nil
        server?.stop()
        server = nil
        if let serving, serving.hasOpenSession { serving.requestCloseSession() }
        serving = nil
        files = [:]
        recent = []
    }

    /// ImageCaptureCore reports no battery for the GR (batteryLevelAvailable is false), but
    /// the standard PTP property BatteryLevel (0x5001) answers 0–100 (GR IV HDF fw 1.20).
    /// PTP has nothing for charging; the camera offers no other power property over USB.
    private func readBattery(_ camera: ICCameraDevice) async -> Int? {
        transactionID += 1
        var command = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { command.append(contentsOf: $0) } }
        // Container: length, type 1 (command), GetDevicePropValue 0x1015, transaction, property.
        append(UInt32(16)); append(UInt16(1)); append(UInt16(0x1015)); append(transactionID); append(UInt32(0x5001))
        return await withCheckedContinuation { continuation in
            camera.requestSendPTPCommand(command, outData: nil) { data, response, error in
                // Response code 0x2001 (OK) at bytes 6–7.
                let ok = error == nil && response.count >= 8 && response[6] == 0x01 && response[7] == 0x20
                continuation.resume(returning: ok && data.count == 1 ? Int(data[0]) : nil)
            }
        }
    }

    private func index(_ camera: ICCameraDevice) {
        files = [:]
        for case let file as ICCameraFile in camera.mediaFiles ?? [] {
            files[Self.id(file)] = file
        }
    }

    /// Largest single PTP read; bigger requests stall the camera.
    static let chunk: Int64 = 4 * 1024 * 1024

    private static func isVideo(_ file: ICCameraFile) -> Bool {
        ["MOV", "MP4"].contains(((file.name ?? "") as NSString).pathExtension.uppercased())
    }

    private static func dir(_ file: ICCameraFile) -> String { file.parentFolder?.name ?? "100RICOH" }
    private static func id(_ file: ICCameraFile) -> String { "\(dir(file))/\(file.name ?? "")" }

    private func withTimeout(_ seconds: Double, _ message: String, _ body: @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw USBError(message: message)
            }
            defer {
                group.cancelAll()
                Task { @MainActor in
                    self.opened?.resume(throwing: CancellationError()); self.opened = nil
                    self.ready?.resume(throwing: CancellationError()); self.ready = nil
                }
            }
            try await group.next()
        }
    }

    // MARK: Camera API over the local server

    private func answer(_ request: LocalServer.Request) async -> LocalServer.Response {
        let parts = request.path.split(separator: "/").map(String.init)   // ["v1", "photos", dir, name, "info"]
        guard parts.first == "v1", request.method == "GET" else {
            return .error(501, "USB 연결에서는 지원하지 않는 기능이에요.")
        }
        switch Array(parts.dropFirst()) {
        case ["ping"]:
            return .json(["errCode": 200, "errMsg": "OK"])
        case ["props"]:
            return .json(props())
        case ["photos"]:
            return .json(photoList())
        case let p where p.count == 4 && p[0] == "photos" && p[3] == "info":
            guard let file = files["\(p[1])/\(p[2])"] else { return .error(404, "Not Found") }
            return .json(info(file))
        case let p where p.count == 3 && p[0] == "photos":
            guard let file = files["\(p[1])/\(p[2])"] else { return .error(404, "Not Found") }
            do {
                switch request.query["size"] {
                case "thumb": return .data(try await thumbnail(file), type: "image/jpeg")
                case "xs", "view": return .data(try await preview(file, maxPixels: 1920), type: "image/jpeg")
                default: return original(file, range: request.range)
                }
            } catch {
                return .error(500, error.localizedDescription)
            }
        default:
            return .error(501, "USB 연결에서는 지원하지 않는 기능이에요.")
        }
    }

    private func props() -> [String: Any] {
        var props: [String: Any] = ["errCode": 200, "errMsg": "OK", "model": serving?.name ?? "RICOH GR"]
        #if os(macOS)
        if let serial = serving?.serialNumberString { props["serialNo"] = serial }
        #endif
        if let battery { props["battery"] = battery }
        props["storages"] = [["name": "in", "equipped": true, "numOfPhotos": files.count]]
        return props
    }

    private func photoList() -> [String: Any] {
        var dirs: [String: [String]] = [:]
        for file in files.values { dirs[Self.dir(file), default: []].append(file.name ?? "") }
        return ["errCode": 200, "errMsg": "OK",
                "dirs": dirs.keys.sorted().map { ["name": $0, "files": dirs[$0]!.sorted()] }]
    }

    private func info(_ file: ICCameraFile) -> [String: Any] {
        var json: [String: Any] = ["errCode": 200, "errMsg": "OK",
                                   "orientation": file.orientation.rawValue, "size": file.fileSize]
        if let date = file.exifCreationDate ?? file.creationDate {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            json["datetime"] = f.string(from: date)
        }
        return json
    }

    /// The camera's own small thumbnail, stored unrotated like the Wi-Fi thumbs.
    private func thumbnail(_ file: ICCameraFile) async throws -> Data {
        let data: Data? = await withCheckedContinuation { c in
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 320]) { data, _ in c.resume(returning: data) }
        }
        if let data, !data.isEmpty { return data }
        // Never pull a whole video for a thumbnail: reading 239 MB in one PTP request
        // made the camera drop off USB.
        guard !Self.isVideo(file) else { return try await videoFrame(file) }
        return try await preview(file, maxPixels: 320)
    }

    /// First frame of a video, read through this server so AVFoundation fetches only the
    /// byte ranges it needs.
    private func videoFrame(_ file: ICCameraFile) async throws -> Data {
        guard let base = server?.base else { throw USBError(message: "closed") }
        let asset = AVURLAsset(url: base.appendingPathComponent("v1/photos/\(Self.id(file))"))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.appliesPreferredTrackTransform = true
        let (image, _) = try await generator.image(at: .zero)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            throw USBError(message: "영상 썸네일을 만들 수 없어요.")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// A downscaled JPEG of the original, unrotated (the app applies the EXIF orientation).
    private func preview(_ file: ICCameraFile, maxPixels: Int) async throws -> Data {
        guard !Self.isVideo(file) else { throw USBError(message: "영상은 미리보기가 없어요.") }
        let original = try await whole(file)
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: false,
              ] as CFDictionary) else { throw USBError(message: "미리보기를 만들 수 없어요.") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            throw USBError(message: "미리보기를 만들 수 없어요.")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func whole(_ file: ICCameraFile) async throws -> Data {
        let id = Self.id(file)
        if let hit = recent.first(where: { $0.id == id }) { return hit.data }
        var data = Data(capacity: Int(file.fileSize))
        while Int64(data.count) < file.fileSize {
            let piece = try await read(file, offset: Int64(data.count), length: min(Self.chunk, file.fileSize - Int64(data.count)))
            guard !piece.isEmpty else { throw USBError(message: "USB 읽기 실패") }
            data.append(piece)
        }
        recent.insert((id, data), at: 0)
        if recent.count > 6 { recent.removeLast() }
        return data
    }

    private func read(_ file: ICCameraFile, offset: Int64, length: Int64) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            file.requestReadData(atOffset: offset, length: length) { data, error in
                if let data { c.resume(returning: data) } else {
                    c.resume(throwing: error ?? USBError(message: "USB 읽기 실패"))
                }
            }
        }
    }

    /// The original file, streamed in pieces (videos can be hundreds of MB), honouring
    /// a byte range so the video player can seek.
    private func original(_ file: ICCameraFile, range: ClosedRange<Int64>?) -> LocalServer.Response {
        let size = file.fileSize
        let span = range.map { $0.lowerBound...min($0.upperBound, size - 1) } ?? 0...(size - 1)
        let type = (file.name as NSString?)?.pathExtension.uppercased() == "MOV" ? "video/quicktime" : "application/octet-stream"
        return .stream(total: size, span: span, partial: range != nil, type: type) { [weak self] offset, length in
            guard let self else { throw USBError(message: "closed") }
            return try await self.read(file, offset: offset, length: length)
        }
    }
}

extension USBCamera: ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        MainActor.assumeIsolated {
            DebugLog.write("usb: device '\(device.name ?? "?")' type \(device.type.rawValue) transport \(device.transportType ?? "nil") camera \(device is ICCameraDevice)")
            guard let camera = device as? ICCameraDevice else { return }
            #if os(macOS)
            guard device.transportType == ICDeviceTransport.transportTypeUSB.rawValue,
                  (camera.name ?? "").uppercased().contains("GR") else { return }
            #else
            // iOS lists only cameras on the Lightning/USB-C port, and may name the GR
            // differently; take any, but keep a GR already found over another camera.
            if let detected, (detected.name ?? "").uppercased().contains("GR"),
               !(camera.name ?? "").uppercased().contains("GR") { return }
            #endif
            DebugLog.write("usb: found \(camera.name ?? "?")")
            camera.delegate = self
            detected = camera
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated {
            guard device === detected else { return }
            DebugLog.write("usb: removed \(device.name ?? "?")")
            detected = nil
            if serving === device {
                close()
                onRemoved?()
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        MainActor.assumeIsolated {
            if let error { opened?.resume(throwing: error) } else { opened?.resume() }
            opened = nil
        }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        MainActor.assumeIsolated {
            if serving === device { index(device) }
            // Some cameras report the catalog before the session-open callback.
            opened?.resume(); opened = nil
            ready?.resume(); ready = nil
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        MainActor.assumeIsolated { if serving === camera { index(camera) } }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        MainActor.assumeIsolated { if serving === camera { index(camera) } }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    nonisolated func didRemove(_ device: ICDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

/// Minimal HTTP/1.1 server on 127.0.0.1: one request per connection, GET only.
final class LocalServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let range: ClosedRange<Int64>?
    }

    enum Response {
        case json([String: Any])
        case data(Data, type: String)
        case stream(total: Int64, span: ClosedRange<Int64>, partial: Bool, type: String,
                    read: (Int64, Int64) async throws -> Data)
        case error(Int, String)
    }

    private let handler: @MainActor (Request) async -> Response
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "grlink.usb.server")
    private(set) var base = URL(string: "http://127.0.0.1")!

    init(handler: @escaping @MainActor (Request) async -> Response) {
        self.handler = handler
    }

    func start() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        self.listener = listener
        let port: UInt16 = try await withCheckedThrowingContinuation { c in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; c.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): resumed = true; c.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection, buffer: Data())
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                Task { await self.respond(connection, to: Self.parse(head)) }
            } else if done || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveHeader(connection, buffer: buffer)
            }
        }
    }

    private static func parse(_ head: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2, let url = URLComponents(string: String(first[1])) else { return nil }
        var query: [String: String] = [:]
        url.queryItems?.forEach { query[$0.name] = $0.value }
        var range: ClosedRange<Int64>?
        if let line = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let spec = line.split(separator: "=").last {
            let ends = spec.split(separator: "-", omittingEmptySubsequences: false).map { Int64($0.trimmingCharacters(in: .whitespaces)) }
            if ends.count == 2, let lower = ends[0] { range = lower...(ends[1] ?? Int64.max - 1) }
        }
        return Request(method: String(first[0]), path: url.percentEncodedPath.removingPercentEncoding ?? url.path,
                       query: query, range: range)
    }

    private func respond(_ connection: NWConnection, to request: Request?) async {
        guard let request else { return finish(connection, header(400, length: 0, type: "text/plain")) }
        let response = await handler(request)
        switch response {
        case .json(let object):
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            await send(connection, header(200, length: Int64(body.count), type: "application/json") + body)
            connection.cancel()
        case .data(let body, let type):
            await send(connection, header(200, length: Int64(body.count), type: type) + body)
            connection.cancel()
        case .error(let status, let message):
            let body = (try? JSONSerialization.data(withJSONObject: ["errCode": status, "errMsg": message])) ?? Data()
            await send(connection, header(status, length: Int64(body.count), type: "application/json") + body)
            connection.cancel()
        case .stream(let total, let span, let partial, let type, let read):
            var extra = ""
            if partial { extra = "Content-Range: bytes \(span.lowerBound)-\(span.upperBound)/\(total)\r\n" }
            let length = span.upperBound - span.lowerBound + 1
            guard await send(connection, header(partial ? 206 : 200, length: length, type: type, extra: extra)) else {
                return connection.cancel()
            }
            var offset = span.lowerBound
            let chunk = USBCamera.chunk
            while offset <= span.upperBound {
                let n = min(chunk, span.upperBound - offset + 1)
                guard let data = try? await read(offset, n), !data.isEmpty,
                      await send(connection, data) else { break }
                offset += Int64(data.count)
            }
            connection.cancel()
        }
    }

    private func header(_ status: Int, length: Int64, type: String, extra: String = "") -> Data {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found",
                      500: "Internal Server Error", 501: "Not Implemented", 503: "Service Unavailable"][status] ?? "Error"
        return Data(("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\n"
                     + "Accept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n").utf8)
    }

    @discardableResult
    private func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { c in
            connection.send(content: data, completion: .contentProcessed { error in c.resume(returning: error == nil) })
        }
    }

    private func finish(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
