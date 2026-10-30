// Settings shared between the container app, which edits them, and the speech
// synthesis extension, which speaks with them.
//
// The two are separate processes, so this is a file both can see:
// ~/Library/Application Support/RC8650/settings.json, written atomically by the
// app and re-read by the extension whenever its modification date moves.  A
// plain file rather than an App Group container because neither side is
// sandboxed — see README.md, which also says what to change if you sign this
// with a team and want to sandbox it.
//
// Settings are per voice.  Selecting a voice on the real chip reloads seven of
// its parameters from that voice's firmware preset, so "the pitch" is not one
// number the user holds across voices; it belongs to whichever voice is
// selected, and Skip tuned to taste should still be there after a detour
// through Vader.

import Foundation

public struct RC8650Settings: Codable, Sendable {

    /// The voice the container app is editing.  The extension does not use it:
    /// there, the voice comes from the speech request.
    public var editingVoice: Int = 0

    /// Per-voice parameters, keyed by the nO voice number as a string (JSON
    /// object keys are strings).  A voice missing from here has never been
    /// touched and gets its firmware preset.
    public var voices: [String: Parameters] = [:]

    /// Whether an utterance's own rate / pitch / volume — what the calling app
    /// passes through AVSpeechUtterance — are allowed to move the settings
    /// below, or are ignored in favour of them.
    public var honorUtteranceRate: Bool = true
    public var honorUtterancePitch: Bool = true
    public var honorUtteranceVolume: Bool = true

    /// Text prepended to and appended to every utterance the extension speaks,
    /// after sanitizing.  Empty by default; here because the chip has features
    /// with no UI of their own (the phoneme mode of nD, say) and this is the
    /// escape hatch that reaches them.
    public var preamble: String = ""
    public var postamble: String = ""

    public init() {}

    /// Field by field with defaults as fallbacks, for the same reason as
    /// `Parameters.init(from:)`: a settings file written by a build with a
    /// different set of settings should still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RC8650Settings()
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        editingVoice = get(.editingVoice, d.editingVoice)
        voices = get(.voices, d.voices)
        honorUtteranceRate = get(.honorUtteranceRate, d.honorUtteranceRate)
        honorUtterancePitch = get(.honorUtterancePitch, d.honorUtterancePitch)
        honorUtteranceVolume = get(.honorUtteranceVolume, d.honorUtteranceVolume)
        preamble = get(.preamble, d.preamble)
        postamble = get(.postamble, d.postamble)
    }

    public func parameters(for voiceID: Int) -> Parameters {
        voices[String(voiceID)] ?? Parameters.preset(for: voiceID)
    }

    public mutating func setParameters(_ p: Parameters, for voiceID: Int) {
        voices[String(voiceID)] = p
    }
}

public enum RC8650Storage {

    /// The App Group both sides share.  macOS will not load an app extension
    /// that is not sandboxed, and a sandboxed extension cannot see
    /// ~/Library/Application Support, so this is the one directory the app can
    /// write and the extension can read.
    ///
    /// Taken from Info.plist (set from the RC8650_APP_GROUP build setting) so
    /// there is one place to change it, the team identifier in it not being
    /// portable between developers.
    public static let appGroup: String =
        (Bundle.main.object(forInfoDictionaryKey: "RC8650AppGroup") as? String)
            ?? "EC7L97XK6C.com.guilevi.rc8650"

    /// The group container, or — for a build without the entitlement — the
    /// user's real home directory, so an unsandboxed build still works.
    public static var supportDirectory: URL {
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        var home = NSHomeDirectory()
        if let pw = getpwuid(getuid()) {
            home = String(cString: pw.pointee.pw_dir)
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/RC8650", isDirectory: true)
    }

    public static var settingsURL: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    /// Where the container app installs the firmware image for the extension to
    /// find.  RC Systems' copyrighted code: not shipped, supplied by the user.
    public static var firmwareURL: URL {
        supportDirectory.appendingPathComponent("firmware.srec")
    }

    /// Where the user's pronunciation dictionaries live.  Every `.dict` file in
    /// it is loaded, in sorted order — and load order matters, because rcdict
    /// matches first-match-wins in it, so `00-mine.dict` beats
    /// `50-shared.dict` and a later file can only add to an earlier one, never
    /// override it.  Format and a worked example: `librc8650/rcdict/rcdict.h`
    /// and `librc8650/rcdict/example.dict`.
    ///
    /// In the group container along with everything else, so the extension —
    /// which is sandboxed and cannot see ~/Library/Application Support — can
    /// read what the app writes.
    public static var dictionariesDirectory: URL {
        supportDirectory.appendingPathComponent("Dictionaries", isDirectory: true)
    }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory,
                                                withIntermediateDirectories: true)
    }
}

/// Loads and saves the shared settings file.  Cheap enough to consult on every
/// utterance: it stats the file and only re-parses when it has changed.
public final class SettingsStore: @unchecked Sendable {

    public static let shared = SettingsStore()

    private let lock = NSLock()
    private var cached = RC8650Settings()
    private var cachedStamp: Date?
    private var everLoaded = false

    public init() {}

    /// The current settings, re-read from disk if the file has changed.
    public var current: RC8650Settings {
        lock.lock()
        defer { lock.unlock() }
        let url = RC8650Storage.settingsURL
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if everLoaded && stamp == cachedStamp {
            return cached
        }
        everLoaded = true
        cachedStamp = stamp
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(RC8650Settings.self, from: data) {
            cached = decoded
        }
        return cached
    }

    public func save(_ settings: RC8650Settings) throws {
        lock.lock()
        defer { lock.unlock() }
        try RC8650Storage.ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: RC8650Storage.settingsURL, options: .atomic)
        cached = settings
        everLoaded = true
        cachedStamp = (try? FileManager.default
            .attributesOfItem(atPath: RC8650Storage.settingsURL.path)[.modificationDate]) as? Date
    }
}
