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

    /// Province digits of a "TR xx" header sighted anywhere during the most
    /// recent readTag call, even when that frame's serial read failed — the
    /// round merge pools these so one frame's header can complete another
    /// frame's serial.
    private(set) var lastSeenHeader: String?

    /// Records the first header sighting of the current readTag call.
    private func noteHeader(in text: String) {
        if lastSeenHeader == nil { lastSeenHeader = Self.extractHeader(from: text) }
    }

    /// Cheap live-preview probe (~1ms): size (in downscale pixels) and padded
    /// normalized region of the ear-tag blob in frame, nil when none. Size
    /// gates the frame-grab trigger — a tag too small to read should prompt
    /// "get closer", not burn a doomed read round. The region scopes the
    /// sharpness check to the tag itself. NO OCR runs on live frames.
    func tagBlobProbe(in pixelBuffer: CVPixelBuffer) -> (pixels: Int, rect: CGRect)? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let blob = yellowBlobRegion(in: ci) ?? yellowBlobRegion(in: ci, relaxed: true) else {
            return nil
        }
        return (blob.count, blob.rect)
    }

    /// Variance of the 4-neighbor Laplacian over the (optionally cropped)
    /// image, on a ~256px grayscale downscale: a motion-blurred tag scores
    /// near zero, a readable one scores tens-to-hundreds. Used to skip
    /// smeared frames at grab time and to read the sharpest frames first.
    func sharpness(of cgImage: CGImage, in normalizedRect: CGRect? = nil) -> Double {
        var ci = CIImage(cgImage: cgImage)
        if let r = normalizedRect {
            let rect = CGRect(
                x: r.minX * ci.extent.width, y: r.minY * ci.extent.height,
                width: r.width * ci.extent.width, height: r.height * ci.extent.height
            ).integral
            if rect.width >= 16, rect.height >= 16 { ci = ci.cropped(to: rect) }
        }
        let down = Self.downscaled(ci, maxDimension: 256)
        guard let cg = ciContext.createCGImage(down, from: down.extent) else { return 0 }
        let w = cg.width, h = cg.height
        guard w >= 3, h >= 3 else { return 0 }
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var sum = 0.0, sumSq = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = 4.0 * Double(gray[i])
                    - Double(gray[i - 1]) - Double(gray[i + 1])
                    - Double(gray[i - w]) - Double(gray[i + w])
                sum += lap
                sumSq += lap * lap
            }
        }
        let n = Double((w - 2) * (h - 2))
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    /// Copies a camera frame out of the capture pool so it can be processed
    /// after the farmer has moved on (~10ms).
    func snapshot(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    /// Reads a grabbed frame. `thorough` keeps hunting the small "TR xx"
    /// header after a serial-only read (extra bounded passes, ~0.5s) — used
    /// as a follow-up on the best frame, never in the fast loop.
    func readTag(in cgImage: CGImage, thorough: Bool = false) -> EarTagRead? {
        readTag(ci: CIImage(cgImage: cgImage), thorough: thorough)
    }

    /// Runs OCR and returns the first text matching the ear-tag pattern,
    /// normalized (e.g. "TR201755219"). Escalating passes: full-image OCR,
    /// then a crop-enlarge-rotate re-read of the yellow blob, then of the
    /// digit region — a software zoom that rescues small/angled tags without
    /// any extra model.
    private func readTag(ci image: CIImage, thorough: Bool) -> EarTagRead? {
        // CROP FIRST: the still was only captured because a tag blob was
        // visible, so find the yellow plastic, cut it out, and OCR the
        // enlarged crop (leveled, with flip retry). Focused, fast, and free
        // of background noise. A serial-only read (no TR header) never ends
        // the search early — it's kept as the fallback while later passes
        // try to recover the full number.
        var fallback: EarTagRead?
        lastDiagnostic = ""
        lastSeenHeader = nil

        if let blob = yellowBlobRegion(in: image) ?? yellowBlobRegion(in: image, relaxed: true) {
            lastDiagnostic = "b\(Int(blob.angle * 180 / .pi))°"
            if let read = zoomRead(image, normalizedRect: blob.rect, levelBy: blob.angle) {
                // Fast path: return even a serial-only read immediately — the
                // caller decides whether to spend a thorough follow-up on it.
                if read.tag.hasPrefix("TR") || !thorough { return read }
                fallback = read
            }
        } else {
            lastDiagnostic = "b:none"
        }

        // Fallback (only when the blob path found nothing): whole-image OCR
        // on a bounded downscale — catches faded/bleached tags the color
        // detector misses. NEVER run on the raw still; 12MP accurate OCR is
        // a multi-second stall. Barcode gets first crack here too.
        let bounded = Self.downscaled(image, maxDimension: 1600)
        if let payload = barcodePayload(in: VNImageRequestHandler(ciImage: bounded, options: [:])),
           let tag = Self.extractTag(from: payload) {
            lastDiagnostic += " bc'\(payload.suffix(10))'"
            return EarTagRead(tag: tag, crop: nil)
        }
        let handler = VNImageRequestHandler(ciImage: bounded, options: [:])
        let observations = Self.recognize(with: handler, minimumTextHeight: 0.02)
        let pass1Text = Self.joinedText(of: observations)
        noteHeader(in: pass1Text)
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

        // Barcode FIRST: the tag prints its number as a 1D barcode, and a
        // decoded barcode is exact — no OCR ambiguity, no country assumptions.
        // Only resolves when the farmer is close, so OCR stays the fallback.
        if let payload = barcodePayload(in: VNImageRequestHandler(cgImage: baseCrop, orientation: .up, options: [:])),
           let tag = Self.extractTag(from: payload) {
            lastDiagnostic += " bc'\(payload.suffix(10))'"
            return EarTagRead(tag: tag, crop: UIImage(cgImage: baseCrop))
        }

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
            noteHeader(in: zoomText)
            if rotation == attempts.first { lastDiagnostic += " z'\(zoomText.suffix(10))'" }
            if let tag = Self.extractTag(from: zoomText) {
                let read = EarTagRead(tag: tag, crop: UIImage(cgImage: crop))
                if tag.hasPrefix("TR") { return read }
                if fallback == nil { fallback = read }
            }

            // Perspective pass (unrotated attempt only): when the digit line
            // sits skewed in the crop, warp it level and frontal off the text
            // observation's own quad, and read once more. One resample — the
            // same garbling risk as the rotation attempts, so it's outranked
            // by a clean unrotated read but still beats the blind rotations:
            // the quad also corrects foreshortening, which rotation can't.
            if rotation == 0,
               let obs = Self.digitObservation(of: zoomed),
               let warped = rectifiedCrop(from: crop, observation: obs) {
                let wHandler = VNImageRequestHandler(cgImage: warped, orientation: .up, options: [:])
                let wText = Self.joinedText(of: Self.recognize(with: wHandler, minimumTextHeight: 0))
                noteHeader(in: wText)
                lastDiagnostic += " r'\(wText.suffix(10))'"
                if let tag = Self.extractTag(from: wText) {
                    let read = EarTagRead(tag: tag, crop: UIImage(cgImage: warped))
                    if tag.hasPrefix("TR") { return read }
                    if fallback == nil { fallback = read }
                }
            }
        }
        return fallback
    }

    /// Perspective-corrects the crop so the digit line reads level and
    /// frontal, using the recognized text's quad corners. Returns nil when
    /// the quad is already effectively axis-aligned and rectangular — a warp
    /// there is pure resampling risk with nothing to gain.
    private func rectifiedCrop(from cgImage: CGImage, observation: VNRectangleObservation) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)
        let w = ci.extent.width, h = ci.extent.height
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }
        var tl = px(observation.topLeft), tr = px(observation.topRight)
        var bl = px(observation.bottomLeft), br = px(observation.bottomRight)

        // Worth warping only when tilted beyond ~4° or one side edge is
        // noticeably foreshortened (oblique view).
        let tilt = abs(atan2(tr.y - tl.y, tr.x - tl.x))
        let leftLen = hypot(tl.x - bl.x, tl.y - bl.y)
        let rightLen = hypot(tr.x - br.x, tr.y - br.y)
        guard leftLen > 4, rightLen > 4 else { return nil }
        let foreshortening = abs(leftLen - rightLen) / max(leftLen, rightLen)
        guard tilt > .pi / 45 || foreshortening > 0.12 else { return nil }

        // Pad the quad in its own frame: 30% wider each side so no digit is
        // clipped, 120% above the digit line so the small "TR xx" header
        // stays in view (mirrors digitRegion's padding), 40% below.
        func add(_ p: CGPoint, _ v: CGPoint, _ s: CGFloat) -> CGPoint {
            CGPoint(x: p.x + v.x * s, y: p.y + v.y * s)
        }
        let base = CGPoint(x: tr.x - tl.x, y: tr.y - tl.y)
        let upL = CGPoint(x: tl.x - bl.x, y: tl.y - bl.y)
        let upR = CGPoint(x: tr.x - br.x, y: tr.y - br.y)
        tl = add(add(tl, base, -0.3), upL, 1.2)
        tr = add(add(tr, base, 0.3), upR, 1.2)
        bl = add(add(bl, base, -0.3), upL, -0.4)
        br = add(add(br, base, 0.3), upR, -0.4)

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: tl), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: tr), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bl), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: br), forKey: "inputBottomRight")
        guard var out = filter.outputImage,
              out.extent.width > 24, out.extent.height > 12 else { return nil }

        // Same size normalization as enlargedCrop: big text for the
        // recognizer, bounded cost.
        let scale = min(4, 1000 / max(out.extent.width, out.extent.height))
        if abs(scale - 1) > 0.01 {
            out = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return ciContext.createCGImage(out, from: out.extent)
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

    /// Decodes the first digit-bearing 1D barcode in view (livestock tags
    /// print Code 128 / ITF / Code 39 style stripes). Nil when none resolves —
    /// the common case at a distance; barcodes need more pixels than digits.
    private func barcodePayload(in handler: VNImageRequestHandler) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.code128, .code39, .i2of5, .itf14, .ean13]
        guard (try? handler.perform([request])) != nil else { return nil }
        return (request.results ?? [])
            .compactMap(\.payloadStringValue)
            .first { $0.filter(\.isNumber).count >= 7 }
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

    /// The single observation carrying the longest contiguous digit run —
    /// the serial line. Nil when no observation has a 3+ digit run.
    private static func digitObservation(of observations: [VNRecognizedTextObservation]) -> VNRecognizedTextObservation? {
        func longestRun(_ obs: VNRecognizedTextObservation) -> Int {
            let text = obs.topCandidates(1).first?.string ?? ""
            var best = 0, current = 0
            for ch in text {
                current = ch.isNumber ? current + 1 : 0
                best = max(best, current)
            }
            return best
        }
        guard let best = observations.max(by: { longestRun($0) < longestRun($1) }),
              longestRun(best) >= 3 else { return nil }
        return best
    }

    /// Box of the serial-line observation — a union of everything digit-ish
    /// can lasso half the scene into the crop. Padded extra vertically so
    /// the "TR xx" header above the serial stays in frame. Normalized Vision
    /// coordinates.
    private static func digitRegion(of observations: [VNRecognizedTextObservation]) -> CGRect? {
        guard let best = digitObservation(of: observations) else { return nil }
        let box = best.boundingBox
        let padded = box.insetBy(dx: -(box.width * 0.6 + 0.02), dy: -(box.height * 1.2 + 0.02))
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
    private func yellowBlobRegion(in source: CIImage, relaxed: Bool = false) -> (rect: CGRect, angle: CGFloat, count: Int)? {
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
            let r = Double(pixels[i * 4]) / 255
            let g = Double(pixels[i * 4 + 1]) / 255
            let b = Double(pixels[i * 4 + 2]) / 255
            mask[i] = relaxed ? Self.isTagYellowRelaxed(r: r, g: g, b: b)
                              : Self.isTagYellow(r: r, g: g, b: b)
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
        return (clamped, angle, blob.count)
    }

    /// Second-tier classifier for sun-bleached / dirty tags whose plastic has
    /// faded toward olive: wider hue band, much lower saturation/brightness
    /// floors. Only consulted when the strict tier finds nothing, so straw
    /// false-positives are confined to scenes with no proper tag — and a
    /// false blob merely wastes one read round.
    static func isTagYellowRelaxed(r: Double, g: Double, b: Double) -> Bool {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        guard maxC > 0.22, delta > 0, delta / maxC > 0.22 else { return false }
        var hue: Double
        if maxC == r {
            hue = 60 * ((g - b) / delta)
        } else if maxC == g {
            hue = 60 * (2 + (b - r) / delta)
        } else {
            hue = 60 * (4 + (r - g) / delta)
        }
        if hue < 0 { hue += 360 }
        return (30...85).contains(hue)
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
        // Header and serial as separate finds: the tag prints a barcode
        // stripe between the "TR xx" header and the serial, and Vision often
        // OCRs it as junk letters ("TR 43 ıIıIı 1608816") — which breaks the
        // contiguous pattern above and used to coin-flip reads down to
        // serial-only. The province must still sit right after "TR", and the
        // serial stays the longest-contiguous-run rule, so stray numbers
        // can't fuse in; only the junk BETWEEN the parts stops mattering.
        if let province = extractHeader(from: text),
           let serial = allMatches(of: "[0-9]{7,12}", in: text).max(by: { $0.count < $1.count }) {
            return "TR\(province)\(serial)"
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

    /// The 2-digit province from a standalone "TR xx" header anywhere in the
    /// text, or nil. Tolerates the same stray separator letters as the full
    /// pattern; refuses when a third digit follows (that's a number, not the
    /// header). Also the per-frame evidence for cross-frame header pooling —
    /// a frame can surface the header even when its serial read fails.
    static func extractHeader(from text: String) -> String? {
        firstDigitGroup(matching: "TR[\\s\\-]*[A-Z]{0,2}[\\s\\-]*([0-9]{2})(?![0-9])", in: text)
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

    /// Vote policy across one round's reads (in read order). Returns the
    /// winning serial key, or nil when the round is too contradictory to
    /// trust — a wrong lock is worse than a rescan.
    ///
    /// - Two frames agreeing on a serial confirm it (misreads are random and
    ///   don't repeat; the true number does).
    /// - A lone read with no contradiction is accepted — most rounds yield
    ///   one usable frame and failing them all would tank scan success.
    /// - Conflicting serials with no majority fall to structure: exactly one
    ///   candidate backed by a TR-full read (validated "TR"+8-14-digit shape)
    ///   wins; otherwise the round fails.
    static func winningKey(for tags: [String]) -> String? {
        var counts: [String: Int] = [:]
        for tag in tags { counts[serialKey(tag), default: 0] += 1 }
        guard !counts.isEmpty else { return nil }
        if counts.count == 1 { return counts.keys.first }
        let top = counts.values.max() ?? 0
        let leaders = counts.filter { $0.value == top }.keys
        if leaders.count == 1, top >= 2 { return leaders.first }
        let trKeys = Set(tags.filter { $0.hasPrefix("TR") }.map(serialKey))
        let trLeaders = leaders.filter(trKeys.contains)
        return trLeaders.count == 1 ? trLeaders.first : nil
    }

    /// Completes a serial-only read with a province header pooled from other
    /// frames of the same round. Only a bare 7-8 digit serial qualifies — a
    /// 9+ digit read already contains the province (its "TR" was restored by
    /// extractTag), and prefixing anything else would fabricate a number.
    static func completed(tag: String, pooledHeader: String?) -> String {
        guard let header = pooledHeader,
              !tag.hasPrefix("TR"),
              (7...8).contains(tag.count),
              tag.allSatisfy(\.isNumber)
        else { return tag }
        return "TR\(header)\(tag)"
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

    /// The single stored tag within one edit of an unmatched read's serial —
    /// the "Did you mean?" suggestion. One edit covers the dominant OCR
    /// failure (a substituted digit: 6↔8, 1↔7); requiring a UNIQUE candidate
    /// makes a wrong suggestion rarer than no suggestion. Comparison is on
    /// the trailing-7 serial key, so header presence doesn't matter.
    static func nearMatch(read: String, in storedTags: [String]) -> String? {
        let r = serialKey(read)
        guard r.count >= 6 else { return nil }
        var candidate: String?
        for stored in storedTags {
            let s = serialKey(stored)
            guard s != r, withinOneEdit(r, s) else { continue }
            if candidate != nil { return nil }  // ambiguous — offer nothing
            candidate = stored
        }
        return candidate
    }

    /// Levenshtein distance ≤ 1: equal length with at most one substitution,
    /// or off-by-one length with one insertion/deletion.
    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if x.count == y.count {
            return zip(x, y).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) } <= 1
        }
        let (short, long) = x.count < y.count ? (x, y) : (y, x)
        guard long.count - short.count == 1 else { return false }
        var i = 0, j = 0, skipped = false
        while i < short.count && j < long.count {
            if short[i] == long[j] {
                i += 1; j += 1
            } else if skipped {
                return false
            } else {
                skipped = true; j += 1
            }
        }
        return true
    }
}
