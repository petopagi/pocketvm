import AppKit
import CoreImage
import IOSurface
import ScreenCaptureKit
import Virtualization
import Vision

/// A capture of a machine's display: native pixels plus the point size agents work in.
struct ScreenFrame {
    let image: CGImage
    let points: CGSize

    var pixelsPerPoint: CGFloat { CGFloat(image.width) / points.width }
}

/// One piece of text found on screen, in points (origin top-left).
struct TextHit {
    let text: String
    let frame: CGRect
    let confidence: Float

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    var json: [String: Any] {
        [
            "text": text,
            "x": Int(center.x.rounded()), "y": Int(center.y.rounded()),
            "box": [Int(frame.minX), Int(frame.minY), Int(frame.width.rounded()), Int(frame.height.rounded())],
            "confidence": AgentTools.decimal(Double(confidence), places: 2),
        ]
    }
}

@MainActor
enum ScreenGrab {
    static func frame(of view: VZVirtualMachineView) async throws -> ScreenFrame {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { throw PocketError("The machine’s display isn’t visible yet.") }
        // A window that just opened has no frame yet; give the display a moment before
        // falling back to ScreenCaptureKit (which needs Screen Recording permission).
        if ProcessInfo.processInfo.environment["POCKETVM_DEBUG_LAYERS"] != nil { dumpLayers(view.layer, depth: 0) }
        for attempt in 0..<20 {
            if let image = surfaceImage(in: view.layer) { return ScreenFrame(image: image, points: size) }
            if attempt < 19 { try await Task.sleep(for: .milliseconds(100)) }
        }
        if let image = try await windowImage(of: view) { return ScreenFrame(image: image, points: size) }
        throw PocketError("Couldn’t capture the machine’s screen.")
    }

    /// PNG of the whole screen at 1 pixel per point, or of `region` at full resolution (for reading small text).
    static func png(_ frame: ScreenFrame, region: CGRect? = nil) throws -> (data: Data, width: Int, height: Int) {
        var source = frame.image
        var outputSize = frame.points
        if let region {
            let bounds = CGRect(origin: .zero, size: frame.points)
            let clipped = region.intersection(bounds)
            guard !clipped.isNull, clipped.width >= 4, clipped.height >= 4 else {
                throw PocketError("That region is outside the \(Int(frame.points.width))×\(Int(frame.points.height)) screen.")
            }
            let scale = frame.pixelsPerPoint
            let pixels = CGRect(x: clipped.minX * scale, y: clipped.minY * scale, width: clipped.width * scale, height: clipped.height * scale).integral
            guard let cropped = frame.image.cropping(to: pixels) else { throw PocketError("Couldn’t crop the screenshot.") }
            source = cropped
            // Zoomed regions keep native detail, capped so the image stays a sensible size.
            let factor = min(scale, 1600 / max(clipped.width, clipped.height))
            outputSize = CGSize(width: clipped.width * max(1, factor), height: clipped.height * max(1, factor))
        }
        let width = Int(outputSize.width.rounded()), height = Int(outputSize.height.rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw PocketError("Couldn’t scale the screenshot.") }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
        else { throw PocketError("Couldn’t encode the screenshot.") }
        return (png, width, height)
    }

    /// On-device text recognition, returned in screen points. Large areas are read in overlapping
    /// tiles: Vision downsamples big images, which loses small or faint interface text.
    static func text(in frame: ScreenFrame, region: CGRect? = nil) async throws -> [TextHit] {
        let screen = CGRect(origin: .zero, size: frame.points)
        let area = (region ?? screen).intersection(screen)
        guard !area.isNull, area.width >= 4, area.height >= 4 else {
            throw PocketError("That region is outside the \(Int(frame.points.width))×\(Int(frame.points.height)) screen.")
        }
        let tile: CGFloat = 520, overlap: CGFloat = 48
        let columns = max(1, Int(ceil((area.width - overlap) / (tile - overlap))))
        let rows = max(1, Int(ceil((area.height - overlap) / (tile - overlap))))
        let width = columns == 1 ? area.width : (area.width + overlap * CGFloat(columns - 1)) / CGFloat(columns)
        let height = rows == 1 ? area.height : (area.height + overlap * CGFloat(rows - 1)) / CGFloat(rows)

        var tiles: [(CGImage, CGRect)] = []
        let scale = frame.pixelsPerPoint
        for row in 0..<rows {
            for column in 0..<columns {
                let rect = CGRect(
                    x: area.minX + CGFloat(column) * (width - overlap),
                    y: area.minY + CGFloat(row) * (height - overlap),
                    width: width, height: height).intersection(area)
                let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
                if let image = frame.image.cropping(to: pixels) { tiles.append((image, rect)) }
            }
        }

        // Vision blocks its calling thread and caps concurrent recognitions, so it runs on its own
        // serial queue: never on Swift's cooperative pool, where blocked threads starve every task.
        let found: [TextHit] = try await withCheckedThrowingContinuation { continuation in
            ocrQueue.async {
                do {
                    var all: [TextHit] = []
                    for (image, rect) in tiles { all += try recognize(image, placedIn: rect) }
                    continuation.resume(returning: all)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return merge(found)
    }

    private nonisolated static let ocrQueue = DispatchQueue(label: "app.pocketvm.ocr", qos: .userInitiated)

    private nonisolated static func recognize(_ image: CGImage, placedIn rect: CGRect) throws -> [TextHit] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision boxes are normalized with a bottom-left origin.
            let box = observation.boundingBox
            return TextHit(
                text: candidate.string,
                frame: CGRect(
                    x: rect.minX + box.minX * rect.width,
                    y: rect.minY + (1 - box.maxY) * rect.height,
                    width: box.width * rect.width,
                    height: box.height * rect.height),
                confidence: candidate.confidence)
        }
    }

    /// Drops duplicates from overlapping tiles, keeping the more complete reading, then sorts into reading order.
    private static func merge(_ hits: [TextHit]) -> [TextHit] {
        var kept: [TextHit] = []
        for hit in hits.sorted(by: { ($0.text.count, $0.confidence) > ($1.text.count, $1.confidence) }) {
            let duplicate = kept.contains { other in
                let overlap = hit.frame.intersection(other.frame)
                guard !overlap.isNull else { return false }
                return overlap.width * overlap.height > 0.5 * min(hit.frame.width * hit.frame.height, other.frame.width * other.frame.height)
            }
            if !duplicate { kept.append(hit) }
        }
        return kept.sorted { abs($0.frame.minY - $1.frame.minY) > 6 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
    }

    /// Text matches for `query`, best first: whole-line matches, then whole-word matches,
    /// then (unless `wholeWords`) matches inside longer words. Each match's center is where to click.
    static func find(_ query: String, in hits: [TextHit], wholeWords: Bool = false) -> [TextHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        let wordPattern = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: needle) + "(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive])
        var exact: [TextHit] = [], words: [TextHit] = [], partial: [TextHit] = []
        for hit in hits {
            if hit.text.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(needle) == .orderedSame {
                exact.append(hit)
                continue
            }
            let ns = hit.text as NSString
            if let match = wordPattern?.firstMatch(in: hit.text, range: NSRange(location: 0, length: ns.length)) {
                words.append(narrow(hit, to: match.range, length: ns.length))
            } else if !wholeWords {
                let range = ns.range(of: needle, options: .caseInsensitive)
                if range.location != NSNotFound { partial.append(narrow(hit, to: range, length: ns.length)) }
            }
        }
        // Short labels (buttons, menu items) beat long lines that merely contain the words.
        let tighter: (TextHit, TextHit) -> Bool = { $0.text.count < $1.text.count }
        let matches = exact + words.sorted(by: tighter) + partial.sorted(by: tighter)
        if !matches.isEmpty || needle.count < 4 { return matches }

        // Last resort: OCR misreads ("Vour name"), matched by edit distance on same-length word runs.
        let target = needle.lowercased()
        let wordCount = target.split(separator: " ").count
        var fuzzy: [(TextHit, Double)] = []
        for hit in hits {
            let tokens = hit.text.lowercased().split(separator: " ")
            guard tokens.count >= wordCount else { continue }
            var best = 0.0
            for start in 0...(tokens.count - wordCount) {
                best = max(best, similarity(tokens[start..<start + wordCount].joined(separator: " "), target))
            }
            if best >= 0.75 { fuzzy.append((hit, best)) }
        }
        return fuzzy.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.text.count < $1.0.text.count }.map(\.0)
    }

    /// 1 − normalized Levenshtein distance.
    private static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    /// Shrinks a line's box to the matched characters, assuming even character widths.
    private static func narrow(_ hit: TextHit, to range: NSRange, length: Int) -> TextHit {
        let count = CGFloat(max(1, length))
        let frame = CGRect(
            x: hit.frame.minX + hit.frame.width * CGFloat(range.location) / count, y: hit.frame.minY,
            width: hit.frame.width * CGFloat(range.length) / count, height: hit.frame.height)
        return TextHit(text: hit.text, frame: frame, confidence: hit.confidence)
    }

    private static func dumpLayers(_ layer: CALayer?, depth: Int) {
        guard let layer else { return }
        var kind = "nil"
        if let c = layer.contents {
            let ref = c as CFTypeRef
            if CFGetTypeID(ref) == IOSurfaceGetTypeID() {
                let surface = unsafeBitCast(ref, to: IOSurfaceRef.self)
                kind = "IOSurface \(IOSurfaceGetWidth(surface))x\(IOSurfaceGetHeight(surface)) id \(IOSurfaceGetID(surface)) seed \(IOSurfaceGetSeed(surface)) inUse \(IOSurfaceIsInUse(surface))"
            } else { kind = String(describing: type(of: c)) }
        }
        NSLog("PVM layer %@%@ %@ frame=%@ hidden=%d opacity=%.2f contents=%@", String(repeating: "  ", count: depth), String(describing: type(of: layer)), layer.name ?? "-", NSStringFromRect(layer.frame), layer.isHidden ? 1 : 0, layer.opacity, kind)
        for sub in layer.sublayers ?? [] { dumpLayers(sub, depth: depth + 1) }
    }

    /// The framebuffer, when the display layer exposes it in-process.
    private static func surfaceImage(in layer: CALayer?) -> CGImage? {
        guard let layer else { return nil }
        if let contents = layer.contents {
            let ref = contents as CFTypeRef
            if CFGetTypeID(ref) == IOSurfaceGetTypeID() {
                let surface = unsafeBitCast(ref, to: IOSurfaceRef.self)
                let ci = CIImage(ioSurface: surface)
                if ci.extent.width > 1 { return CIContext().createCGImage(ci, from: ci.extent) }
            } else if CFGetTypeID(ref) == CGImage.typeID {
                return (contents as! CGImage)
            }
        }
        for sublayer in layer.sublayers ?? [] {
            if let image = surfaceImage(in: sublayer) { return image }
        }
        return nil
    }

    /// Falls back to ScreenCaptureKit on the machine's own window (needs Screen Recording).
    private static func windowImage(of view: VZVirtualMachineView) async throws -> CGImage? {
        guard let window = view.window else { throw PocketError("The machine’s window isn’t open.") }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw PocketError("PocketVM needs Screen Recording permission to show agents the screen. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.")
        }
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw PocketError("Couldn’t find the machine’s window.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let inWindow = view.convert(view.bounds, to: nil)
        let crop = CGRect(
            x: inWindow.minX * scale,
            y: (window.frame.height - inWindow.maxY) * scale,
            width: inWindow.width * scale,
            height: inWindow.height * scale)
        return full.cropping(to: crop) ?? full
    }
}
