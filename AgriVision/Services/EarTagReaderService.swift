import CoreImage
import UIKit
import Vision

/// One successful tag read: the number plus the image region it was read from,
/// shown on the result card so the farmer can verify the digits by eye.
struct EarTagRead {
    let tag: String
    let crop: UIImage?
}

/// Reads cattle ear-tag numbers off live camera frames with on-device OCR
/// (Vision's text recognizer — offline, no model to bundle). Turkish tags are
/// black digits on yellow plastic in the fixed "TR + digits" format, so the
/// raw OCR output is filtered through that pattern to reject barn noise.
final class EarTagReaderService {
    private let ciContext = CIContext()

    /// Debug trail of the most recent readTag call — what pass 1 saw, whether
    /// a blob was found (pixel count @ tilt), and the zoom pass's raw text.
    /// Shown in the camera's debug capsule when no tag extracts, so field
    /// failures pinpoint the failing stage from a screenshot.
    private(set) var lastDiagnostic = ""

    /// Cheap live-preview probe (~1ms): is a plausible ear-tag blob in frame?
    /// Drives the green brackets and the auto-capture gate — NO OCR runs on
    /// live frames; reading happens on a captured full-res still.
    func hasTagBlob(in pixelBuffer: CVPixelBuffer) -> Bool {
        yellowBlobRegion(in: CIImage(cvPixelBuffer: pixelBuffer)) != nil
    }

    /// Reads a captured still. Stills are ~6x the pixels of a video frame with
    /// proper autofocus, so this is where OCR actually happens.
    func readTag(in cgImage: CGImage) -> EarTagRead? {
        readTag(ci: CIImage(cgImage: cgImage))
    }

    /// Runs OCR and returns the first text matching the ear-tag pattern,
    /// normalized (e.g. "TR201755219"). Escalating passes: full-image OCR,
    /// then a crop-enlarge-rotate re-read of the yellow blob, then of the
    /// digit region — a software zoom that rescues small/angled tags without
    /// any extra model.
    private func readTag(ci image: CIImage) -> EarTagRead? {
        // CROP FIRST: the still was only captured because a tag blob was
        // visible, so find the yellow plastic, cut it out, and OCR the
        // enlarged crop (leveled, with flip retry). Focused, fast, and free
        // of background noise. A serial-only read (no TR header) never ends
        // the search early — it's kept as the fallback while later passes
        // try to recover the full number.
        var fallback: EarTagRead?
        lastDiagnostic = ""

        if let blob = yellowBlobRegion(in: image) {
            lastDiagnostic = "b\(Int(blob.angle * 180 / .pi))°"
            // Any successful crop read returns immediately — even serial-only.
            // Hunting the missing "TR" header cost a full-image OCR pass over
            // a 12MP still (seconds of "analyzing" hang); a partial-but-right
            // number now beats a complete one later.
            if let read = zoomRead(image, normalizedRect: blob.rect, levelBy: blob.angle) {
                return read
            }
        } else {
            lastDiagnostic = "b:none"
        }

        // Fallback (only when the blob path found nothing): whole-image OCR
        // on a bounded downscale — catches faded/bleached tags the color
        // detector misses. NEVER run on the raw still; 12MP accurate OCR is
        // a multi-second stall.
        let bounded = Self.downscaled(image, maxDimension: 1600)
        let handler = VNImageRequestHandler(ciImage: bounded, options: [:])
        let observations = Self.recognize(with: handler, minimumTextHeight: 0.02)
        let pass1Text = Self.joinedText(of: observations)
        lastDiagnostic += " p1'\(pass1Text.suffix(10))'"
        if let tag = Self.extractTag(from: pass1Text) {
            let crop = Self.digitRegion(of: observations)
                .flatMap { enlargedCrop(from: image, normalizedRect: $0) }
            return EarTagRead(tag: tag, crop: crop.map { UIImage(cgImage: $0) })
        }

        // Last resort: zoom into wherever the whole-image pass saw digits.
        if let region = Self.digitRegion(of: observations),
           let read = zoomRead(image, normalizedRect: region) {
            fallback = read
        }
        return fallback
    }

    /// Uniformly scales an image down so its longer side is at most `maxDimension`.
    private static func downscaled(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > maxDimension else { return image }
        let s = maxDimension / longest
        return image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    /// Crops the region, enlarges it, optionally rotates it level, and runs a
    /// second OCR over it. When a rotation is applied and yields nothing, the
    /// flipped orientation (±180°) is tried too — the principal axis can't
    /// tell up from down.
    private func zoomRead(_ image: CIImage, normalizedRect: CGRect, levelBy angle: CGFloat = 0) -> EarTagRead? {
        guard let baseCrop = enlargedCrop(from: image, normalizedRect: normalizedRect) else { return nil }

        // Unrotated FIRST: rotation resampling can garble digits into other,
        // plausible-looking digits (field case: 2962212 read as 7177967 after
        // a 49° rotation), so a serial read off the untouched crop must
        // outrank one from a rotated attempt. The rotated attempts exist to
        // recover the small TR header — a TR-full read from any attempt still
        // wins outright.
        var attempts: [CGFloat] = [0]
        if abs(angle) > .pi / 15 {
            attempts = [0, -angle, -angle + .pi]
        }
        // A serial-only read doesn't stop the loop: a later rotation may
        // recover the full TR-prefixed number. Attempt order IS fallback
        // priority — the first serial-only read (unrotated) is kept.
        var fallback: EarTagRead?
        for rotation in attempts {
            guard let crop = rotated(baseCrop, by: rotation) else { continue }
            let handler = VNImageRequestHandler(cgImage: crop, orientation: .up, options: [:])
            let zoomed = Self.recognize(with: handler, minimumTextHeight: 0)
            let zoomText = Self.joinedText(of: zoomed)
            if rotation == attempts.first { lastDiagnostic += " z'\(zoomText.suffix(10))'" }
            if let tag = Self.extractTag(from: zoomText) {
                let read = EarTagRead(tag: tag, crop: UIImage(cgImage: crop))
                if tag.hasPrefix("TR") { return read }
                if fallback == nil { fallback = read }
            }
        }
        return fallback
    }

    /// Rotates an image around its center (0 = passthrough).
    private func rotated(_ image: CGImage, by angle: CGFloat) -> CGImage? {
        guard angle != 0 else { return image }
        let ci = CIImage(cgImage: image)
        let center = CGPoint(x: ci.extent.midX, y: ci.extent.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
        let rotatedCI = ci.transformed(by: transform)
        return ciContext.createCGImage(rotatedCI, from: rotatedCI.extent)
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
    private func enlargedCrop(from image: CIImage, normalizedRect: CGRect) -> CGImage? {
        let rect = CGRect(
            x: normalizedRect.minX * image.extent.width,
            y: normalizedRect.minY * image.extent.height,
            width: normalizedRect.width * image.extent.width,
            height: normalizedRect.height * image.extent.height
        ).integral
        guard rect.width > 8, rect.height > 8 else { return nil }

        var cropped = image.cropped(to: rect)
        // Normalize the crop toward ~1000px: upscale distant tags (max 4x) so
        // OCR sees big text, and DOWNSCALE oversized crops from 12MP stills —
        // accurate OCR cost grows fast with input size.
        let scale = min(4, 1000 / max(rect.width, rect.height))
        if abs(scale - 1) > 0.01 {
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return ciContext.createCGImage(cropped, from: cropped.extent)
    }

    /// Finds the largest saturated-yellow blob — ear-tag plastic — and returns
    /// its padded region in normalized Vision coordinates (bottom-left origin)
    /// plus the blob's principal-axis tilt (radians, image coordinates), used
    /// to rotate the crop level before OCR. Runs on a ~160px-wide downscale,
    /// so the scan plus flood fill costs ~a millisecond.
    private func yellowBlobRegion(in source: CIImage) -> (rect: CGRect, angle: CGFloat)? {
        guard source.extent.width > 0 else { return nil }
        let scale = 160 / source.extent.width
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent) else { return nil }

        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var mask = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            mask[i] = Self.isTagYellow(
                r: Double(pixels[i * 4]) / 255,
                g: Double(pixels[i * 4 + 1]) / 255,
                b: Double(pixels[i * 4 + 2]) / 255
            )
        }

        // Largest 4-connected component via flood fill.
        var best: (count: Int, minX: Int, maxX: Int, minY: Int, maxY: Int)?
        var visited = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for start in 0..<(w * h) where mask[start] && !visited[start] {
            var count = 0
            var minX = w, maxX = 0, minY = h, maxY = 0
            stack.append(start)
            visited[start] = true
            while let i = stack.popLast() {
                count += 1
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for n in [i - 1, i + 1, i - w, i + w]
                where n >= 0 && n < w * h && mask[n] && !visited[n]
                    && !(i % w == 0 && n == i - 1) && !(i % w == w - 1 && n == i + 1) {
                    visited[n] = true
                    stack.append(n)
                }
            }
            if count > (best?.count ?? 0) {
                best = (count, minX, maxX, minY, maxY)
            }
        }

        // Plausibility: big enough to hold readable text once zoomed, not a
        // yellow wall, and roughly tag-shaped.
        guard let blob = best, blob.count >= 25, blob.count <= (w * h) / 4 else { return nil }
        let bw = blob.maxX - blob.minX + 1, bh = blob.maxY - blob.minY + 1
        let aspect = Double(bw) / Double(bh)
        guard (0.25...4.0).contains(aspect) else { return nil }

        // Principal-axis tilt from the blob's second moments — the tag's long
        // axis, which the printed number runs along. Bitmap y is top-down;
        // negate the cross term to get the angle in (bottom-up) image coords.
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        for y in blob.minY...blob.maxY {
            for x in blob.minX...blob.maxX where mask[y * w + x] {
                let fx = Double(x), fy = Double(y)
                n += 1; sx += fx; sy += fy
                sxx += fx * fx; syy += fy * fy; sxy += fx * fy
            }
        }
        var angle: CGFloat = 0
        if n > 0 {
            let covXX = sxx / n - (sx / n) * (sx / n)
            let covYY = syy / n - (sy / n) * (sy / n)
            let covXY = -(sxy / n - (sx / n) * (sy / n))
            angle = CGFloat(0.5 * atan2(2 * covXY, covXX - covYY))
        }

        // Bitmap rows are top-down; Vision's normalized origin is bottom-left.
        let rect = CGRect(
            x: Double(blob.minX) / Double(w),
            y: 1.0 - Double(blob.maxY + 1) / Double(h),
            width: Double(bw) / Double(w),
            height: Double(bh) / Double(h)
        )
        let padded = rect.insetBy(dx: -(rect.width * 0.35 + 0.01), dy: -(rect.height * 0.35 + 0.01))
        let clamped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return (clamped, angle)
    }

    /// Saturated tag-plastic yellow: hue in the yellow band with real
    /// saturation and brightness. Straw and hay read as dull/desaturated
    /// yellow and fail the saturation floor.
    static func isTagYellow(r: Double, g: Double, b: Double) -> Bool {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        guard maxC > 0.35, delta > 0, delta / maxC > 0.4 else { return false }
        var hue: Double
        if maxC == r {
            hue = 60 * ((g - b) / delta)
        } else if maxC == g {
            hue = 60 * (2 + (b - r) / delta)
        } else {
            hue = 60 * (4 + (r - g) / delta)
        }
        if hue < 0 { hue += 360 }
        return (35...75).contains(hue)
    }

    /// Pulls a plausible ear-tag number out of raw OCR text.
    /// Preferred: "TR" + 8–14 digits (spaces/dashes between groups tolerated),
    /// normalized to "TR" + digits. Fallback: the LONGEST contiguous run of
    /// 7–14 digits — the big serial line alone, for when OCR misses the small
    /// "TR xx" header. The fallback is contiguous-only on purpose: tolerating
    /// gaps there would merge stray numbers (pen numbers, dates) into fake
    /// serials.
    static func extractTag(from text: String) -> String? {
        // Up to two stray letters are tolerated after "TR": the header prints
        // with a separator glyph that OCR reads as a letter ("TR◦03" → "TRO03").
        // Longer letter runs (TRACTOR…) still fail to the serial fallback.
        if let digits = firstDigitGroup(matching: "TR[\\s\\-]*[A-Z]{0,2}[\\s\\-]*((?:[0-9][\\s\\-]*){8,14})", in: text),
           (8...14).contains(digits.count) {
            return "TR\(digits)"
        }
        guard let run = allMatches(of: "[0-9]{7,14}", in: text).max(by: { $0.count < $1.count }) else {
            return nil
        }
        // Every Turkish tag carries "TR"; a 9+ digit run already includes the
        // province code, so only the letters were missed — restore them for a
        // complete display. A 7-8 digit run is the serial alone and stays bare:
        // prefixing it would wrongly present a partial number as complete.
        return run.count >= 9 ? "TR\(run)" : run
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
