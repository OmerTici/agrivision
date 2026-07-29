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

        // Tags print the number split across lines ("TR 12" / "345 678…"),
        // so join all recognized lines before matching.
        let joined = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        return Self.extractTag(from: joined)
    }

    /// Pulls a plausible Turkish ear-tag number out of raw OCR text:
    /// "TR" followed by 8–14 digits, tolerating spaces/dashes between groups.
    /// Returns it normalized to "TR" + digits, or nil.
    static func extractTag(from text: String) -> String? {
        let pattern = "TR[\\s\\-]*((?:[0-9][\\s\\-]*){8,14})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let digitsRange = Range(match.range(at: 1), in: text)
        else { return nil }

        let digits = text[digitsRange].filter(\.isNumber)
        guard (8...14).contains(digits.count) else { return nil }
        return "TR\(digits)"
    }

    /// Canonical form for comparing a read tag against a farmer-entered one:
    /// uppercase alphanumerics only ("tr-0412 " == "TR0412").
    static func normalize(_ tag: String) -> String {
        String(tag.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
