import AppKit

/// Website icons for the login list. Each icon comes from the site itself, never from an icon
/// service, so no third party learns which sites you have logins for. Icons are cached on disk,
/// and a site without one is asked again after a week.
final class SiteIcons: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]

    private var requested: Set<String> = []
    /// Saved icons already read from disk, kept out of `images` so reading one while a row draws
    /// doesn't trigger another redraw.
    private var saved: [String: NSImage] = [:]
    private var notSaved: Set<String> = []
    private let fetches: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "QuickPass")
        .appendingPathComponent("Icons")
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral // no cookies, nothing kept between requests
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) QuickPass"]
        return URLSession(configuration: config)
    }()

    /// The icon to draw right now: one fetched this session, or the saved copy read straight from
    /// disk. Reading it here, as the row is first drawn, means a saved icon never pops in after
    /// the letter.
    func image(for host: String) -> NSImage? {
        if let image = images[host] ?? saved[host] { return image }
        guard !notSaved.contains(host) else { return nil }
        guard let image = NSImage(contentsOf: file(host, "png")) else {
            notSaved.insert(host)
            return nil
        }
        saved[host] = image
        return image
    }

    /// Fetches the icon in the background if it isn't saved yet.
    func request(_ host: String) {
        guard requested.insert(host).inserted, image(for: host) == nil else { return }
        let missing = (try? file(host, "none").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let missing, Date().timeIntervalSince(missing) < 7 * 86_400 { return }
        fetches.addOperation { [self] in
            let png = fetchIcon(for: host)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let png {
                try? png.write(to: file(host, "png"))
                DispatchQueue.main.async { self.images[host] = NSImage(data: png) }
            } else {
                try? Data().write(to: file(host, "none"))
            }
        }
    }

    /// The host to show an icon for: the login's website when known, otherwise its title when the
    /// title is itself a web address, like "accounts.spotify.com". A name like "GitHub" gets no
    /// guess, since a wrong guess would show the wrong logo.
    static func host(website: String?, title: String) -> String? {
        if let website, !website.isEmpty {
            let text = website.contains("://") ? website : "https://" + website
            return URL(string: text)?.host?.lowercased()
        }
        let name = title.lowercased().trimmingCharacters(in: .whitespaces)
        guard name.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$"#, options: .regularExpression) != nil else { return nil }
        return name
    }

    private func file(_ host: String, _ ext: String) -> URL {
        directory.appendingPathComponent(host).appendingPathExtension(ext)
    }

    // MARK: - Fetching

    /// Tries the icons the home page links to, then the usual fixed paths. A subdomain like
    /// auth.example.com often has none of its own, so example.com is tried after it.
    private func fetchIcon(for host: String) -> Data? {
        var hosts = [host]
        let labels = host.split(separator: ".")
        if labels.count > 2 { hosts.append(labels.suffix(2).joined(separator: ".")) }
        for host in hosts {
            guard let home = URL(string: "https://\(host)/") else { continue }
            var candidates: [URL] = []
            if let (data, finalURL) = get(home), let html = String(data: data.prefix(300_000), encoding: .utf8) {
                candidates += Self.linkedIcons(in: html, base: finalURL)
            }
            candidates += ["apple-touch-icon.png", "favicon.ico"].compactMap { URL(string: $0, relativeTo: home)?.absoluteURL }
            for url in candidates {
                if let (data, _) = get(url), let png = Self.squarePNG(from: data) { return png }
            }
        }
        return nil
    }

    private func get(_ url: URL) -> (Data, URL)? {
        var result: (Data, URL)?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: url) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                result = (data, http.url ?? url)
            }
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    /// Icon links from a page's <link> tags, Apple touch icons first since they're the largest.
    static func linkedIcons(in html: String, base: URL) -> [URL] {
        func attribute(_ name: String, in tag: String) -> String? {
            guard let range = tag.range(of: name + #"\s*=\s*["']?([^"'\s>]+)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let match = String(tag[range])
            return match.drop(while: { $0 != "=" }).dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        var touch: [URL] = [], icons: [URL] = []
        var rest = html[...]
        while let range = rest.range(of: #"<link[^>]+>"#, options: [.regularExpression, .caseInsensitive]) {
            let tag = String(rest[range])
            rest = rest[range.upperBound...]
            guard let rel = attribute("rel", in: tag)?.lowercased(), let href = attribute("href", in: tag),
                  !href.hasPrefix("data:"), let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let words = rel.split(separator: " ")
            if words.contains(where: { $0.hasPrefix("apple-touch-icon") }) { touch.append(url) }
            else if words.contains("icon") { icons.append(url) }
        }
        return touch + icons
    }

    /// Scales any image format NSImage reads, .ico included, to a 64-point square PNG. Rejects
    /// anything too small to look sharp.
    static func squarePNG(from data: Data) -> Data? {
        guard let image = NSImage(data: data), let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
              max(rep.pixelsWide, Int(image.size.width)) >= 16 else { return nil }
        let side = 128
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
