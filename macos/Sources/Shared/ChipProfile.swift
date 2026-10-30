// What the loaded firmware offers, and which firmware to load.
//
// librc8650 runs any of RC Systems' firmware images — the five RC8650 v2.60
// builds RCStudio ships, the RC8660 v3.44, and later revisions — and describes
// the one it is running with rc8650_get_profile: the voices and their presets,
// read back out of the firmware with its Interrogate command, the formant and
// speed ranges found the same way, and the rate ladder.  Everything in this app
// that depends on the chip reads it through `RC8650Chip.profile`, which the
// engine sets when it boots.  Until it has, the built-in RC8650 profile stands
// in, so the editor always has something to show.
//
// Images live in the shared container's Firmware folder, each one identified by
// its own header (rc8650_image_info), and the chosen one is named in
// settings.json — the file the app writes and the extension reads — so the
// extension follows the app's choice on its next utterance.

import Foundation
import CRC8650

public struct ChipProfile: Sendable {
    /// 8650, 8660, or 0 for a family this library does not know.
    public let chip: Int
    /// "2.60", from the image header.
    public let version: String
    public let model: Int
    public let voices: [RC8650Chip.Voice]
    public let formantRange: ClosedRange<Int>
    public let speedRange: ClosedRange<Int>
    public let rateLadder: [(por: Int, speed: Int)]
    /// Length of one fixed sentence per rung, or 0 where it was not measured.
    public let rateDuration: [Int]
    public let defaultRateRung: Int
    public let interrogateLength: Int
    public let maxIndexMark: Int
    /// The Protocol Options Register as the chip powers up: 128 on the RC8650,
    /// 144 on the RC8660, whose bit 4 (R50) is what keeps it an RC8660.  See
    /// `RC8650Chip.protocolOptions`.
    public let porDefault: Int

    /// "RC8650", "RC8660" — what the voices are called after.
    public var chipName: String { chip == 0 ? "RC86x0" : "RC\(chip)" }

    /// The RC8650 v2.60, as this app always described it: what stands in until
    /// a firmware image has booted.  Its ladder is the measured interleave of
    /// both speed scales (re-measured 2026-08-01), and its presets were read
    /// with 12? after each nO — the same numbers librc8650 now probes for.
    public static let builtIn = ChipProfile(
        chip: 8650, version: "2.60", model: 4,
        voices: [
            .init(id: 0, name: "Perfect Paul", chipName: "RC8650",
                  preset: .init(pitch: 50, articulation: 5, formant: 5, tone: 1, expression: 5, reverb: 0, wordDelay: 0)),
            .init(id: 1, name: "Vader", chipName: "RC8650",
                  preset: .init(pitch: 10, articulation: 4, formant: 0, tone: 1, expression: 6, reverb: 3, wordDelay: 0)),
            .init(id: 2, name: "Big Bob", chipName: "RC8650",
                  preset: .init(pitch: 40, articulation: 5, formant: 3, tone: 0, expression: 5, reverb: 0, wordDelay: 0)),
            .init(id: 3, name: "Precise Pete", chipName: "RC8650",
                  preset: .init(pitch: 60, articulation: 6, formant: 6, tone: 2, expression: 4, reverb: 0, wordDelay: 0)),
            .init(id: 4, name: "Ricochet Randy", chipName: "RC8650",
                  preset: .init(pitch: 40, articulation: 5, formant: 5, tone: 1, expression: 5, reverb: 9, wordDelay: 0)),
            .init(id: 5, name: "Biff", chipName: "RC8650",
                  preset: .init(pitch: 50, articulation: 6, formant: 0, tone: 0, expression: 7, reverb: 0, wordDelay: 0)),
            .init(id: 6, name: "Skip", chipName: "RC8650",
                  preset: .init(pitch: 15, articulation: 6, formant: 9, tone: 0, expression: 7, reverb: 0, wordDelay: 0)),
            .init(id: 7, name: "Robo Robert", chipName: "RC8650",
                  preset: .init(pitch: 80, articulation: 5, formant: 7, tone: 1, expression: 0, reverb: 6, wordDelay: 1)),
        ],
        formantRange: 0...9, speedRange: 0...9,
        rateLadder: [
            (0, 0), (0, 1), (0, 2), (0, 3), (0, 4),
            (0, 5), (128, 0), (0, 6), (0, 7), (128, 1),
            (128, 2), (128, 3), (0, 8), (128, 4), (0, 9),
            (128, 5), (128, 6), (128, 7), (128, 8), (128, 9),
        ],
        rateDuration: [
            26572, 24686, 22036, 20890, 18529,
            17131, 16773, 16422, 15504, 15375,
            14695, 13777, 13582, 13198, 12617,
            12233, 9443, 9199, 8493, 7653,
        ],
        defaultRateRung: 9, interrogateLength: 23, maxIndexMark: 99, porDefault: 128)

    public init(chip: Int, version: String, model: Int, voices: [RC8650Chip.Voice],
                formantRange: ClosedRange<Int>, speedRange: ClosedRange<Int>,
                rateLadder: [(por: Int, speed: Int)], rateDuration: [Int],
                defaultRateRung: Int, interrogateLength: Int, maxIndexMark: Int,
                porDefault: Int) {
        self.chip = chip
        self.version = version
        self.model = model
        self.voices = voices
        self.formantRange = formantRange
        self.speedRange = speedRange
        self.rateLadder = rateLadder
        self.rateDuration = rateDuration
        self.defaultRateRung = defaultRateRung
        self.interrogateLength = interrogateLength
        self.maxIndexMark = maxIndexMark
        self.porDefault = porDefault
    }

    /// From librc8650's own description of the firmware it is running.
    public init(_ p: rc8650_profile) {
        var p = p
        chip = Int(p.chip)
        version = ChipProfile.versionString(p.version)
        model = Int(p.model)
        let name = chip == 0 ? "RC86x0" : "RC\(chip)"
        // Copied out first: the closures below borrow p's arrays, and reading
        // another field of p inside one would be an overlapping access.
        let voiceCount = Int(min(p.voices, 32))
        let rungCount = Int(min(p.rungs, 64))

        // The fixed-size C arrays arrive as tuples; read them as the memory
        // they are.
        let presets: [rc8650_preset] = withUnsafeBytes(of: &p.preset) { raw in
            (0..<voiceCount).map {
                raw.load(fromByteOffset: $0 * MemoryLayout<rc8650_preset>.stride,
                         as: rc8650_preset.self)
            }
        }
        let names: [String] = withUnsafeBytes(of: &p.voice_name) { raw in
            (0..<voiceCount).map { i in
                let pointer = raw.load(
                    fromByteOffset: i * MemoryLayout<UnsafePointer<CChar>?>.stride,
                    as: UnsafePointer<CChar>?.self)
                return pointer.map { String(cString: $0) } ?? "Voice \(i)"
            }
        }
        voices = presets.enumerated().map { i, q in
            RC8650Chip.Voice(id: i, name: names[i], chipName: name,
                             preset: .init(pitch: Int(q.pitch), articulation: Int(q.articulation),
                                           formant: Int(q.formant), tone: Int(q.tone),
                                           expression: Int(q.expression), reverb: Int(q.reverb),
                                           wordDelay: Int(q.word_delay)))
        }
        let rungs: [rc8650_rung] = withUnsafeBytes(of: &p.rate) { raw in
            (0..<rungCount).map {
                raw.load(fromByteOffset: $0 * MemoryLayout<rc8650_rung>.stride,
                         as: rc8650_rung.self)
            }
        }
        rateLadder = rungs.map { (Int($0.v86), Int($0.speed)) }
        rateDuration = rungs.map { Int($0.samples) }
        defaultRateRung = Int(p.rate_default)
        formantRange = 0...Int(p.formant_max)
        speedRange = 0...Int(max(p.speed_max_v86, p.speed_max_v8600))
        interrogateLength = Int(p.interrogate_len)
        maxIndexMark = Int(p.max_index_mark)
        porDefault = Int(p.por_default)
    }

    static func versionString(_ bcd: UInt32) -> String {
        String(format: "%x.%02x", bcd >> 8, bcd & 0xff)
    }
}

/// The current profile, behind a lock: the engine sets it from whichever
/// thread boots the chip, and every thread that builds a command or a slider
/// reads it.
private final class ProfileBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ChipProfile.builtIn

    var profile: ChipProfile {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

extension RC8650Chip {
    private static let box = ProfileBox()

    /// The firmware the engine is running, or the built-in RC8650 until it has
    /// booted one.
    public static var profile: ChipProfile {
        get { box.profile }
        set { box.profile = newValue }
    }
}

/// The firmware images the app and the extension can run.
public enum FirmwareCatalog {

    public struct Image: Identifiable, Hashable, Sendable {
        public let url: URL
        public let chip: Int
        public let version: String
        public let model: Int
        public var id: String { url.path }
        public var name: String { url.lastPathComponent }
        public var label: String {
            "RC\(chip == 0 ? "86x0" : String(chip)) firmware \(version), model \(model)"
        }
    }

    /// Where images live: in the shared container, beside settings.json, so the
    /// sandboxed extension can read what the app puts there.
    public static var folder: URL {
        RC8650Storage.supportDirectory.appendingPathComponent("Firmware", isDirectory: true)
    }

    /// What the app installed before there was a choice; still found, and still
    /// what runs when nothing has been chosen.
    static var legacyURLs: [URL] {
        var urls: [URL] = []
        if let env = ProcessInfo.processInfo.environment["RC8650_FIRMWARE"] {
            urls.append(URL(fileURLWithPath: env))
        }
        urls.append(RC8650Storage.supportDirectory.appendingPathComponent("firmware.srec"))
        urls.append(RC8650Storage.supportDirectory.appendingPathComponent("firmware.srec.gz"))
        for name in ["rc8650_m4_valid", "rc8650"] {
            for ext in ["srec", "srec.gz"] {
                if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    /// Read an image's header without booting it.
    public static func identify(_ url: URL) -> Image? {
        guard let data = try? SRecordImage.load(from: url) else { return nil }
        var info = rc8650_profile()
        let ok = data.withUnsafeBytes { raw in
            rc8650_image_info(raw.baseAddress, raw.count, &info)
        }
        guard ok == 0 else { return nil }
        return Image(url: url, chip: Int(info.chip),
                     version: ChipProfile.versionString(info.version),
                     model: Int(info.model))
    }

    /// Every image in the folder, then any legacy one, each once.
    public static func images() -> [Image] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var urls = names
            .filter { $0.lowercased().hasSuffix(".srec") || $0.lowercased().hasSuffix(".srec.gz") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { folder.appendingPathComponent($0) }
        urls += legacyURLs.filter { FileManager.default.isReadableFile(atPath: $0.path) }
        var seen = Set<String>()
        return urls.compactMap { url in
            guard seen.insert(url.standardizedFileURL.path).inserted else { return nil }
            return identify(url)
        }
    }

    /// The image to run: the one settings.json names if it is still there,
    /// otherwise the legacy one, otherwise the first image found.  Falling back
    /// rather than failing is deliberate — a system voice whose image was
    /// deleted should still speak.
    public static func chosenURL(_ settings: RC8650Settings = SettingsStore.shared.current) -> URL? {
        if !settings.firmware.isEmpty {
            let named = settings.firmware.hasPrefix("/")
                ? URL(fileURLWithPath: settings.firmware)
                : folder.appendingPathComponent(settings.firmware)
            if FileManager.default.isReadableFile(atPath: named.path) { return named }
        }
        for url in legacyURLs where FileManager.default.isReadableFile(atPath: url.path) {
            return url
        }
        return images().first?.url
    }

    /// Copy an image into the folder, returning where it went.
    public static func install(from source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        if destination.standardizedFileURL != source.standardizedFileURL {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }
}
