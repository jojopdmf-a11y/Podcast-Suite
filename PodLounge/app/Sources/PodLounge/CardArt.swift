import AppKit

enum CardArt {
    static func image(named name: String) -> NSImage? {
        for url in candidateURLs(named: name) {
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }

    /// Looks in the app bundle and, for `swift run`, the SwiftPM resource bundle
    /// next to the executable. Does not trap when a bundle is absent.
    private static func candidateURLs(named name: String) -> [URL] {
        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            urls.append(url)
        }
        let bundleName = "PodLounge_PodLounge.bundle"
        func appendBundle(_ root: URL) {
            let bundle = root.appendingPathComponent(bundleName)
            urls.append(bundle.appendingPathComponent("Contents/Resources/\(name).png"))
            urls.append(bundle.appendingPathComponent("\(name).png"))
        }
        if let resources = Bundle.main.resourceURL {
            urls.append(resources.appendingPathComponent("\(name).png"))
            appendBundle(resources)
        }
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(executableDirectory.appendingPathComponent("\(name).png"))
            appendBundle(executableDirectory)
            let contents = executableDirectory.deletingLastPathComponent()
            urls.append(contents.appendingPathComponent("Resources/\(name).png"))
            appendBundle(contents.appendingPathComponent("Resources"))
        }
        return urls
    }
}
