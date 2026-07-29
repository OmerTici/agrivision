import CoreImage
import Vision

/// Reads cattle ear-tag numbers off live camera frames with on-device OCR
/// (Vision's text recognizer — offline, no model to bundle). Turkish tags are
/// black digits on yellow plastic in the fixed "TR + digits" format, so the
/// raw OCR output is filtered through that pattern to reject barn noise.
final class EarTagReaderService {
    /// Runs OCR synchronously on a live camera frame and returns the first
    /// text that matches the ear-tag pattern, normalized (e.g. "TR12345678").
    func readTag(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Critical for digit strings: language correction would "fix" them.
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        // Tags print the number split across lines ("TR 20" / "1755219").
        // Vision does NOT guarantee observation order, so sort top-to-bottom,
        // left-to-right (Vision's y origin is bottom-left) before joining —
        // otherwise the serial line can precede the "TR" line in the text.
        let sorted = (request.results ?? []).sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.03 {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        let joined = sorted
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        return Self.extractTag(from: joined)
    }

    /// Pulls a plausible ear-tag number out of raw OCR text.
    /// Preferred: "TR" + 8–14 digits (spaces/dashes between groups tolerated),
    /// normalized to "TR" + digits. Fallback: a bare run of 7–14 digits — the
    /// big serial line alone — because OCR often misses the small "TR xx"
    /// header; nothing else in a barn is a 7+ digit run.
    static func extractTag(from text: String) -> String? {
        if let digits = firstDigitGroup(matching: "TR[\\s\\-]*((?:[0-9][\\s\\-]*){8,14})", in: text),
           (8...14).contains(digits.count) {
            return "TR\(digits)"
        }
        if let digits = firstDigitGroup(matching: "((?:[0-9][\\s\\-]*){7,14})", in: text),
           (7...14).contains(digits.count) {
            return digits
        }
        return nil
    }

    private static func firstDigitGroup(matching pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range].filter(\.isNumber))
    }

    /// Whether a stored (farmer-entered) tag matches an OCR read. Exact match
    /// after normalizing, or — for TR-less reads of the big serial line — the
    /// stored tag ending with the read digits (≥7 digits keeps this safe).
    static func matches(stored: String, read: String) -> Bool {
        let s = normalize(stored)
        let r = normalize(read)
        guard !s.isEmpty, !r.isEmpty else { return false }
        if s == r { return true }
        return !r.hasPrefix("TR") && r.count >= 7 && s.hasSuffix(r)
    }

    /// Canonical form for comparing a read tag against a farmer-entered one:
    /// uppercase alphanumerics only ("tr-0412 " == "TR0412").
    static func normalize(_ tag: String) -> String {
        String(tag.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
