import AppKit
import Foundation

/// Shown from About and the app menu. The LGPL text itself is LAME's COPYING.
public enum LAMENotice {
    public static let summary = """
    LAME 3.100 (libmp3lame) encodes MP3 files for this app.

    Copyright (c) 1999–2011 The LAME Project and contributors, including Mark Taylor, Michael Cheng, and Michael Hipp (mpglib).

    License: GNU Library General Public License, version 2. The full text ships with this app as LAME-COPYING.txt.

    Website: https://lame.sourceforge.io
    Source code: https://sourceforge.net/projects/lame/files/lame/3.100/lame-3.100.tar.gz

    LAME is a separate library, libmp3lame.0.dylib, loaded at runtime from Contents/Frameworks. It is not built into the app. You can replace that file with your own build of the same library.
    """

    public static let website = URL(string: "https://lame.sourceforge.io")!

    public static func copyingURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "LAME-COPYING", withExtension: "txt") {
            return bundled
        }
        let built = repoRoot().appendingPathComponent("ThirdParty/lame/build/COPYING")
        if FileManager.default.fileExists(atPath: built.path) {
            return built
        }
        return nil
    }

    public static func openCopying() {
        guard let url = copyingURL() else { return }
        NSWorkspace.shared.open(url)
    }

    public static func openWebsite() {
        NSWorkspace.shared.open(website)
    }

    static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // LAMENotice.swift → LilLevelerKit → Sources → app → LilLeveler → repo
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }
}
