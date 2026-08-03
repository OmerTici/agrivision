import CoreImage
import Vision

/// Reads cattle ear-tag numbers off live camera frames with on-device OCR
/// (Vision's text recognizer — offline, no model to bundle). Turkish tags are
/// black digits on yellow plastic in the fixed "TR + digits" format, so the
/// raw OCR output is filtered through that pattern to reject barn noise.
final class EarTagReaderService {
    private let ciContext = CIContext()

    /// Runs OCR on a live camera frame and returns the first text matching the
    /// ear-tag pattern, normalized (e.g. "TR201755219"). Two passes: if the
    /// full-frame read sees digits but no clean tag (small/angled tag in a
    /// head-filling frame), the digit region is cropped, enlarged, and re-read —
    /// a software zoom that rescues most marginal tags without any extra model.
    func readTag(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) -> String? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        let observations = Self.recognize(with: handler, minimumTextHeight: 0.02)
        if let tag = Self.extractTag(from: Self.joinedText(of: observations)) {
            return tag
        }

        guard let region = Self.digitRegion(of: observations),
              let crop = enlargedCrop(from: pixelBuffer, normalizedRect: region)
        else { return nil }
        let cropHandler = VNImageRequestHandler(cgImage: crop, orientation: .up, options: [:])
        let zoomed = Self.recognize(with: cropHandler, minimumTextHeight: 0)
        return Self.extractTag(from: Self.joinedText(of: zoomed))
    }

    private static func recognize(
        with handler: VNImageRequestHandler,
        minimumTextHeight: Float
    ) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Critical for digit strings: language correction would "fix" them.
        request.usesLanguageCorrection = false
        request.minimumTextHeight = minimumTextHeight
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return request.results ?? []
    }

    /// Tags print the number split across lines ("TR 20" / "1755219").
    /// Vision does NOT guarantee observation order, so sort top-to-bottom,
    /// left-to-right (Vision's y origin is bottom-left) before joining —
    /// otherwise the serial line can precede the "TR" line in the text.
    private static func joinedText(of observations: [VNRecognizedTextObservation]) -> String {
        observations
            .sorted { a, b in
                if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.03 {
                    return a.boundingBox.midY > b.boundingBox.midY
                }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    /// Union of the boxes of digit-bearing observations, generously padded so
    /// the crop keeps the "TR xx" header that sits above the serial. Normalized
    /// Vision coordinates (bottom-left origin); nil when no digits were seen.
    private static func digitRegion(of observations: [VNRecognizedTextObservation]) -> CGRect? {
        let digitBoxes = observations
            .filter { ($0.topCandidates(1).first?.string ?? "").filter(\.isNumber).count >= 2 }
            .map(\.boundingBox)
        guard var union = digitBoxes.first else { return nil }
        for box in digitBoxes.dropFirst() {
            union = union.union(box)
        }
        let padded = union.insetBy(dx: -(union.width * 0.6 + 0.02), dy: -(union.height * 0.6 + 0.02))
        return padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Crops the normalized rect out of the frame and upscales it so the
    /// recognizer sees large text instead of a distant tag.
    private func enlargedCrop(from pixelBuffer: CVPixelBuffer, normalizedRect: CGRect) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(
            x: normalizedRect.minX * image.extent.width,
            y: normalizedRect.minY * image.extent.height,
            width: normalizedRect.width * image.extent.width,
            height: normalizedRect.height * image.extent.height
        ).integral
        guard rect.width > 8, rect.height > 8 else { return nil }

        var cropped = image.cropped(to: rect)
        let scale = min(4, max(1, 800 / max(rect.width, rect.height)))
        if scale > 1 {
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return ciContext.createCGImage(cropped, from: cropped.extent)
    }

    /// Pulls a plausible ear-tag number out of raw OCR text.
    /// Preferred: "TR" + 8–14 digits (spaces/dashes between groups tolerated),
    /// normalized to "TR" + digits. Fallback: the LONGEST contiguous run of
    /// 7–14 digits — the big serial line alone, for when OCR misses the small
    /// "TR xx" header. The fallback is contiguous-only on purpose: tolerating
    /// gaps there would merge stray numbers (pen numbers, dates) into fake
    /// serials.
    static func extractTag(from text: String) -> String? {
        if let digits = firstDigitGroup(matching: "TR[\\s\\-]*((?:[0-9][\\s\\-]*){8,14})", in: text),
           (8...14).contains(digits.count) {
            return "TR\(digits)"
        }
        return allMatches(of: "[0-9]{7,14}", in: text).max(by: { $0.count < $1.count })
    }

    private static func firstDigitGroup(matching pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range].filter(\.isNumber))
    }

    private static func allMatches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// The serial digits of a read — the vote key. "TR201755219" and a
    /// header-missed "201755219" (or "1755219") are the SAME physical tag and
    /// must pool their votes, not compete.
    static func serialKey(_ tag: String) -> String {
        let digits = String(tag.filter(\.isNumber))
        // Key on the trailing 7 digits: the serial is always read; the province
        // prefix comes and goes with the small header line.
        return String(digits.suffix(7))
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
