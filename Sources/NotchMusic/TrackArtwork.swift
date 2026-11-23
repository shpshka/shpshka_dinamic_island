import AppKit
import Combine
import ImageIO

enum ArtworkSource: Equatable {
    case data(Data)
    case url(URL)
    case thumbnail(CGImage)

    // Player metadata may carry full-resolution original files. Keep just the
    // small version in the track cache when an original is large.
    static func embedded(_ bytes: Data) -> ArtworkSource? {
        guard !bytes.isEmpty else { return nil }
        guard bytes.count > CoverDecoder.thumbnailBytes else { return .data(bytes) }
        guard let source = CoverDecoder.source(bytes), let image = CoverDecoder.thumbnail(source) else { return nil }
        return .thumbnail(image)
    }
}

private enum CoverDecoder {
    // The expanded cover occupies 62 points on a 2× Retina display.
    static let thumbnailSide = 128
    static let thumbnailBytes = thumbnailSide * thumbnailSide * 4

    static func source(_ data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    static func thumbnail(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSide,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    struct Swatch {
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
    }

    static func color(in image: CGImage) -> NSColor {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return .lightGray }
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            let layout = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                      bitmapInfo: layout) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return .lightGray }

        // Group similar pixels so complementary colors don't average to grey.
        var swatches = [Swatch](repeating: Swatch(), count: 512)
        for p in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[p + 3])
            guard alpha > 32 else { continue }
            let r = min(1, Double(pixels[p]) / alpha)
            let g = min(1, Double(pixels[p + 1]) / alpha)
            let b = min(1, Double(pixels[p + 2]) / alpha)
            let chroma = max(r, g, b) - min(r, g, b)
            let weight = (0.20 + chroma) * alpha / 255
            let key = (Int(r * 7) * 8 + Int(g * 7)) * 8 + Int(b * 7)
            swatches[key].red += r * weight
            swatches[key].green += g * weight
            swatches[key].blue += b * weight
            swatches[key].weight += weight
        }
        guard let sample = swatches.max(by: { $0.weight < $1.weight }), sample.weight > 0 else { return .lightGray }
        let r = sample.red / sample.weight, g = sample.green / sample.weight, b = sample.blue / sample.weight
        let base = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        // Preserve the cover's hue and lift dark accents until legible on black.
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        for step in 0...8 {
            let mix = Double(step) * 0.08
            let red = r + (1 - r) * mix, green = g + (1 - g) * mix, blue = b + (1 - b) * mix
            if 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) >= 0.25 {
                return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            }
        }
        return base
    }

    static func decode(_ input: ArtworkSource) -> (CGImage, NSColor)? {
        let source: CGImageSource?
        switch input {
        case let .thumbnail(image):
            return (image, color(in: image))
        case let .data(bytes):
            source = self.source(bytes)
        case let .url(file):
            guard file.isFileURL else { return nil }
            source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let source, let image = thumbnail(source) else { return nil }
        return (image, color(in: image))
    }
}

@MainActor
final class TrackArtwork: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var accent: NSColor = .lightGray

    private final class CachedCover {
        let image: NSImage
        let accent: NSColor
        init(image: NSImage, accent: NSColor) {
            self.image = image
            self.accent = accent
        }
    }

    private lazy var cache: NSCache<NSURL, CachedCover> = {
        let cache = NSCache<NSURL, CachedCover>()
        cache.countLimit = 2
        cache.totalCostLimit = 2 * CoverDecoder.thumbnailBytes
        return cache
    }()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 18
        return URLSession(configuration: config)
    }()
    private var revision = 0
    private var displayedSource: ArtworkSource?

    func clear() {
        revision += 1
        displayedSource = nil
        if image != nil {
            image = nil
            accent = .lightGray
        }
    }

    func load(_ source: ArtworkSource?) async {
        guard !Task.isCancelled else { return }
        guard let source else { clear(); return }
        revision += 1
        let request = revision
        if image != nil, source == displayedSource { return }
        displayedSource = nil
        if case let .url(url) = source, let cached = cache.object(forKey: url as NSURL) {
            image = cached.image
            accent = cached.accent
            displayedSource = source
            return
        }
        if image != nil { image = nil; accent = .lightGray }
        var input = source
        var temporaryFile: URL?
        defer { if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) } }

        if case let .url(url) = source, !url.isFileURL {
            guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  let (file, response) = try? await session.download(from: url) else { return }
            temporaryFile = file
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 16 * 1024 * 1024 else { return }
            input = .url(file)
        }
        guard request == revision, !Task.isCancelled else { return }
        let bytes = input
        let result = await Task.detached(priority: .utility) { CoverDecoder.decode(bytes) }.value
        guard request == revision, !Task.isCancelled, let (thumbnail, color) = result else { return }
        let cover = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cover.cacheMode = .never
        if case let .url(url) = source {
            cache.setObject(CachedCover(image: cover, accent: color), forKey: url as NSURL,
                            cost: thumbnail.bytesPerRow * thumbnail.height)
        }
        displayedSource = source
        image = cover
        accent = color
    }
}
