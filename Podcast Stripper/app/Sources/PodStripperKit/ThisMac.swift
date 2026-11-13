import Darwin
import Foundation

/// Reads this Mac’s chip and RAM, then scales Stripper wait from a timed M4 Mini run.
enum ThisMac {
    /// M4 Mini, 2 speakers, 31:00 episode → 9:23. Seconds of wait per minute of show.
    static let m4SecondsPerEpisodeMinute: Double = (9 * 60 + 23) / 31.0

    struct Snapshot: Equatable {
        var chip: String
        var ramGB: Int
        var osLabel: String
        var isAppleSilicon: Bool
        var isIntel: Bool
        /// 1.0 = same wait as the timed Mac mini M4.
        var waitFactor: Double
        var fitTitle: String
        var fitDetail: String

        func waitSeconds(forEpisodeMinutes minutes: Double) -> Int {
            Int((max(0, minutes) * ThisMac.m4SecondsPerEpisodeMinute * waitFactor).rounded())
        }
    }

    static func snapshot() -> Snapshot {
        let chip = chipName()
        let ramGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0).rounded())
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osLabel = "macOS \(v.majorVersion).\(v.minorVersion)"
        let lower = chip.lowercased()
        let isIntel = lower.contains("intel")
        let isAppleSilicon = !isIntel && (lower.contains("apple") || isArm64())
        let factor = waitFactor(chip: chip, ramGB: ramGB, isIntel: isIntel)
        let (fitTitle, fitDetail) = fit(isIntel: isIntel, isAppleSilicon: isAppleSilicon, ramGB: ramGB)
        return Snapshot(
            chip: chip.isEmpty ? (isArm64() ? "Apple Silicon" : "Unknown CPU") : chip,
            ramGB: ramGB,
            osLabel: osLabel,
            isAppleSilicon: isAppleSilicon,
            isIntel: isIntel,
            waitFactor: factor,
            fitTitle: fitTitle,
            fitDetail: fitDetail
        )
    }

    static func formatWait(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(String(format: "%02d", secs))s"
        }
        if minutes > 0 {
            return "\(minutes)m \(String(format: "%02d", secs))s"
        }
        return "\(secs)s"
    }

    private static func chipName() -> String {
        let brand = sysctlString("machdep.cpu.brand_string")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !brand.isEmpty { return brand }
        return sysctlString("hw.model")
    }

    private static func isArm64() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }

    /// Ballpark vs the timed M4 Mini. Music pull is CPU-bound on Macs.
    private static func waitFactor(chip: String, ramGB: Int, isIntel: Bool) -> Double {
        if isIntel { return 5.0 }
        let lower = chip.lowercased()
        let generation: Double
        if lower.contains("m4") {
            generation = 1.0
        } else if lower.contains("m3") {
            generation = 1.25
        } else if lower.contains("m2") {
            generation = 1.5
        } else if lower.contains("m1") {
            generation = 1.85
        } else {
            generation = 1.6
        }
        let variant: Double
        if lower.contains("ultra") {
            variant = 0.72
        } else if lower.contains("max") {
            variant = 0.82
        } else if lower.contains("pro") {
            variant = 0.90
        } else {
            variant = 1.0
        }
        var factor = generation * variant
        if ramGB > 0, ramGB < 12 {
            factor *= 1.4
        } else if ramGB > 0, ramGB < 16 {
            factor *= 1.12
        }
        return factor
    }

    private static func fit(isIntel: Bool, isAppleSilicon: Bool, ramGB: Int) -> (String, String) {
        if isIntel {
            return (
                "NOT RECOMMENDED",
                "Intel Macs can open the app, but splits are much slower. Apple Silicon is the machine we built this for."
            )
        }
        if ramGB > 0, ramGB < 12 {
            return (
                "TIGHT ON RAM",
                "It should finish, but close other apps. 16 GB is the comfortable size for Stripper."
            )
        }
        if ramGB > 0, ramGB < 16 {
            return (
                "OK — 16 GB IS HAPPIER",
                "This Mac can run it. Long episodes are smoother with 16 GB."
            )
        }
        if isAppleSilicon {
            return (
                "COMFORTABLE MATCH",
                "Apple Silicon with enough RAM. Wait times below are scaled from a Mac mini M4 timing."
            )
        }
        return ("UNKNOWN CHIP", "Estimates are a guess until we know this processor.")
    }
}
