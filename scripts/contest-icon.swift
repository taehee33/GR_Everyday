#!/usr/bin/env swift
// Makes a month's 이달의 사진관 winner into an iOS app icon, for the next app update.
//
//   swift scripts/contest-icon.swift 2026-11
//
// Reads contests (winner, icon_crop) from Supabase with the app's publishable key, downloads
// the winner's display.jpg, cuts the square (icon_crop, or the middle) and writes:
//   iOSApp/Assets.xcassets/AppIcon-2026-11.appiconset      the alternate icon (1024 px)
//   iOSApp/Assets.xcassets/AppIconPreview-2026-11.imageset  the picture 설정 › 앱 로고 shows
//   Sources/iOS/AppIconCatalog.swift                        every month that has an icon
// Run it from the repository root after announce_contest. Design: PLAN-contest.md

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let supabaseURL = "https://rqnwgvfirkfxfawnawzf.supabase.co"   // MomentBackend.url
let publishableKey = "sb_publishable_cojeybLAeRjdBFHpVxQtRA_Rz3BYm8_" // MomentBackend.publishableKey

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("contest-icon: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2,
      let match = CommandLine.arguments[1].wholeMatch(of: #/(\d{4})-(\d{2})/#) else {
    fail("usage: swift scripts/contest-icon.swift YYYY-MM")
}
let month = "\(match.1)-\(match.2)"
let assets = URL(filePath: "iOSApp/Assets.xcassets")
guard FileManager.default.fileExists(atPath: assets.path) else { fail("run this from the repository root") }

func get(_ url: URL, rest: Bool) throws -> Data {
    var request = URLRequest(url: url)
    if rest { request.setValue(publishableKey, forHTTPHeaderField: "apikey") }
    var result: Result<Data, Error>!
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { result = .failure(error) }
        else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(NSError(domain: "http", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "\(url) → HTTP \(http.statusCode)"]))
        } else { result = .success(data ?? Data()) }
        done.signal()
    }.resume()
    done.wait()
    return try result.get()
}

func rest(_ path: String) throws -> Any {
    try JSONSerialization.jsonObject(with: get(URL(string: "\(supabaseURL)/rest/v1/\(path)")!, rest: true))
}

do {
    // The winner and its crop.
    guard let rows = try rest("contests?month=eq.\(month)-01&select=winner,icon_crop,announced_at") as? [[String: Any]],
          let row = rows.first else { fail("no contest for \(month)") }
    guard row["announced_at"] is String, let winner = row["winner"] as? String else {
        fail("\(month) has no announced winner yet (announce_contest)")
    }
    let crop = row["icon_crop"] as? [String: Double]

    // The photo.
    guard let config = try rest("app_config?key=eq.image_base_url&select=value") as? [[String: Any]],
          let base = config.first?["value"] as? String else { fail("no image_base_url") }
    let jpeg = try get(URL(string: "\(base)/p/\(winner.lowercased())/display.jpg")!, rest: false)
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let photo = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("could not read the photo") }

    // The square, in pixels (CoreGraphics' origin is the bottom-left corner).
    let w = Double(photo.width), h = Double(photo.height)
    let side = min(w, h) * min(max(crop?["size"] ?? 1, 0.01), 1)
    let x = crop?["x"].map { $0 * w } ?? (w - side) / 2
    let y = crop?["y"].map { $0 * h } ?? (h - side) / 2
    let square = CGRect(x: min(max(x, 0), w - side), y: min(max(y, 0), h - side), width: side, height: side)

    func render(_ size: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // Opaque: iOS icons may not have transparency.
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .high
        let scale = Double(size) / side
        context.draw(photo, in: CGRect(x: -square.minX * scale, y: -(h - square.maxY) * scale,
                                       width: w * scale, height: h * scale))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func write(_ folder: String, _ contents: String, _ png: Data) throws {
        let dir = assets.appending(path: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appending(path: "icon.png"))
        try Data(contents.utf8).write(to: dir.appending(path: "Contents.json"))
    }
    try write("AppIcon-\(month).appiconset", """
    {
      "images" : [
        { "filename" : "icon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """, render(1024))
    try write("AppIconPreview-\(month).imageset", """
    {
      "images" : [
        { "filename" : "icon.png", "idiom" : "universal" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """, render(240))

    // Every month with an icon, newest first.
    let months = try FileManager.default.contentsOfDirectory(atPath: assets.path)
        .compactMap { $0.wholeMatch(of: #/AppIcon-(\d{4}-\d{2})\.appiconset/#).map { String($0.1) } }
        .sorted(by: >)
    let catalog = """
    // Written by scripts/contest-icon.swift — do not edit by hand.
    // The 이달의 사진관 winners whose icons are in this build, newest first ("2026-11").
    // Each has iOSApp/Assets.xcassets/AppIcon-<month>.appiconset and AppIconPreview-<month>.imageset.
    enum AppIconCatalog {
        static let months: [String] = [
    \(months.map { "        \"\($0)\",\n" }.joined())    ]
    }

    """
    try Data(catalog.utf8).write(to: URL(filePath: "Sources/iOS/AppIconCatalog.swift"))
    print("contest-icon: \(month) → AppIcon-\(month) (icons in this build: \(months.joined(separator: ", ")))")
} catch {
    fail(error.localizedDescription)
}
