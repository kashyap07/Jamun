import AppKit
import UniformTypeIdentifiers
import WebKit

/// Serves everything the web view loads, all from local disk:
///   jamun://app/...       the built web app
///   spec://localhost/...  Fig completion specs
///   fig://symbol/<name>   an SF Symbol as an alpha mask
///   fig://icon?type=...   bundled icons, file type icons
///   fig://path/<file>     the Finder icon of a file
///   fig://template?...    a flat colored tile
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let schemes = ["jamun", "spec", "fig"]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let scheme = url.scheme else {
            fail(task, code: 400)
            return
        }
        switch scheme {
        case "jamun":
            guard url.host == "app" else { fail(task, code: 403); return }
            let path = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
            serveFile(task, url: url, root: Paths.web, relativePath: path)
        case "spec":
            guard url.host == "localhost" else { fail(task, code: 403); return }
            serveFile(task, url: url, root: Paths.specs, relativePath: url.path)
        case "fig":
            serveIcon(task, url: url)
        default:
            fail(task, code: 404)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    // MARK: files

    private func serveFile(_ task: WKURLSchemeTask, url: URL, root: URL, relativePath: String) {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = URL(fileURLWithPath: rootPath + "/" + relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(rootPath + "/"),
              let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 8_000_000,
              let data = try? Data(contentsOf: candidate)
        else {
            fail(task, code: 404, url: url)
            return
        }
        respond(task, url: url, data: data, mime: Self.mimeType(for: candidate.pathExtension))
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    // MARK: icons

    private func serveIcon(_ task: WKURLSchemeTask, url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let host = url.host ?? ""
        var image: NSImage?

        if host == "symbol" {
            let name = url.lastPathComponent
            guard let data = Self.symbolMask(name) else {
                fail(task, code: 404, url: url)
                return
            }
            respond(task, url: url, data: data, mime: "image/png")
            return
        }

        if host == "icon", let type = query["type"], !type.isEmpty {
            let safe = type.replacingOccurrences(of: "/", with: "")
            let bundled = Paths.icons.appendingPathComponent("\(safe).png")
            if let data = try? Data(contentsOf: bundled) {
                respond(task, url: url, data: data, mime: "image/png")
                return
            }
            image = Self.fileTypeIcon(safe)
        } else if host == "template" {
            image = Self.tile(hex: query["color"] ?? "")
        } else {
            // fig://path/<absolute path>, or the older fig:///<absolute path>.
            let path = Paths.expandTilde(url.path.removingPercentEncoding ?? url.path)
            if !path.isEmpty {
                image = NSWorkspace.shared.icon(forFile: path)
            }
        }

        guard let image, let data = Self.png(image, side: 32) else {
            fail(task, code: 404, url: url)
            return
        }
        respond(task, url: url, data: data, mime: "image/png")
    }

    private static var symbolCache: [String: Data] = [:]

    /// An SF Symbol as a black PNG with alpha. The web app uses it as a CSS
    /// mask, so the color comes from the text around it.
    private static func symbolMask(_ name: String) -> Data? {
        if let cached = symbolCache[name] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }

        let side: CGFloat = 32
        let canvas = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            // Fit inside the canvas with a small margin, keeping proportions.
            let available = rect.insetBy(dx: 3, dy: 3)
            let scale = min(available.width / symbol.size.width, available.height / symbol.size.height, 1)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            symbol.draw(in: NSRect(origin: origin, size: size))
            // Template symbols draw in an unspecified color: force solid black.
            NSColor.black.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        guard let data = png(canvas, side: side) else { return nil }
        if symbolCache.count >= 256 { symbolCache.removeAll(keepingCapacity: true) }
        symbolCache[name] = data
        return data
    }

    private static func fileTypeIcon(_ type: String) -> NSImage {
        if type == "folder" {
            return NSWorkspace.shared.icon(for: .folder)
        }
        if let utType = UTType(filenameExtension: type) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private static func tile(hex: String) -> NSImage {
        let color = NSColor(hex: hex) ?? NSColor(calibratedRed: 0.36, green: 0.16, blue: 0.53, alpha: 1)
        return NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
            return true
        }
    }

    private static func png(_ image: NSImage, side: CGFloat) -> Data? {
        let size = NSSize(width: side, height: side)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: responses

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            // Specs are imported as modules from a different scheme than the app.
            // Custom WKWebView schemes can have opaque origins. These are public bundled assets.
            "Access-Control-Allow-Origin": "*",
            "Content-Security-Policy": "default-src 'none'; script-src jamun: spec: blob:; style-src 'unsafe-inline' jamun:; img-src fig: jamun: data: https:; font-src jamun: data:; connect-src spec: jamun: https:; frame-src 'none'; object-src 'none'; base-uri 'none'",
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-cache",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            fail(task, code: 500, url: url)
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, code: Int, url: URL? = nil) {
        if let url, code != 404 || url.scheme == "jamun" {
            Log.write("scheme: \(code) for \(url.absoluteString)")
        }
        task.didFailWithError(NSError(domain: "dev.jamun.scheme", code: code))
    }
}

extension NSColor {
    /// Parses "rrggbb" or "#rrggbb".
    convenience init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
