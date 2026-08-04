import CoreGraphics
import Foundation
import UIKit

/// On-device capture of failed ear-tag rounds: the sharpest grabbed frame
/// plus the reader's diagnostic line, kept under Documents/ScanFailures so
/// field failures can be exported from Settings and turned into an eval /
/// training set for the OCR pipeline. Local only — nothing uploads.
/// Oldest captures are pruned past `maxCaptures`.
final class ScanDiagnostics {
    static let shared = ScanDiagnostics()
    static let maxCaptures = 60

    /// All file I/O goes through this queue; the record path is
    /// fire-and-forget so the camera pipeline never waits on disk.
    private let queue = DispatchQueue(label: "agrivision.scandiag", qos: .utility)

    private var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScanFailures", isDirectory: true)
    }

    private var logURL: URL { directory.appendingPathComponent("log.txt") }

    /// Records one failed round. The frame is downscaled before writing so a
    /// capture costs ~100-200KB, not a 12MP still.
    func recordFailure(frame: CGImage, diagnostic: String) {
        queue.async { [self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let jpeg = Self.downscaledJPEG(UIImage(cgImage: frame)) else { return }
            // Timestamp names sort chronologically, which prune() relies on.
            let name = "scan_\(Self.stampFormatter.string(from: Date())).jpg"
            try? jpeg.write(to: directory.appendingPathComponent(name))
            appendLog("\(name)\t\(diagnostic)\n")
            prune()
        }
    }

    func captureCount() -> Int {
        queue.sync { captureURLs().count }
    }

    /// Everything worth exporting: the captured frames plus the log that maps
    /// each file to its pipeline diagnostic.
    func exportURLs() -> [URL] {
        queue.sync {
            let jpgs = captureURLs()
            guard !jpgs.isEmpty else { return [] }
            return jpgs + (FileManager.default.fileExists(atPath: logURL.path) ? [logURL] : [])
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Internals (queue only)

    private func captureURLs() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return urls.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func appendLog(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    private func prune() {
        let jpgs = captureURLs()
        guard jpgs.count > Self.maxCaptures else { return }
        for url in jpgs.prefix(jpgs.count - Self.maxCaptures) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return f
    }()

    /// JPEG bounded to ~1024px on the long side — enough detail to re-run the
    /// reader on it later, small enough to keep dozens around.
    private static func downscaledJPEG(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 1024 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
