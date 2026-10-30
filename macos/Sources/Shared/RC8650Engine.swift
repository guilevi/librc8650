// The one RC8650 in this process.
//
// librc8650 runs the chip's real firmware on an emulated Renesas M16C, and its
// emulator core keeps file-scope state, so a second rc8650_new() in the same
// process fails by design.  Hence a singleton — and hence a lock, because the
// library is not thread-safe and both the container app (preview button, live
// interrogation) and the extension (one render thread per audio unit instance,
// and there can be more than one) will reach for it from more than one thread.
//
// Everything that talks to the chip does it inside `perform`, which holds the
// lock for the whole of an operation.  Rendering an utterance is one such
// operation, so a second caller waits: there is one chip, and it can say one
// thing at a time.

import Foundation
import os
import CRC8650

public final class RC8650Engine: @unchecked Sendable {

    public static let shared = RC8650Engine()

    private static let log = Logger(subsystem: "com.guilevi.rc8650", category: "engine")

    public enum Failure: Error, LocalizedError {
        case noFirmware(searched: [String])
        case libraryRefused(String)
        case noAnswer(String)

        public var errorDescription: String? {
            switch self {
            case .noFirmware(let searched):
                return "No firmware image. Looked in:\n" + searched.joined(separator: "\n")
            case .libraryRefused(let message):
                return "librc8650 refused the firmware: \(message)"
            case .noAnswer(let path):
                return "The firmware in \(path) booted but did not answer."
            }
        }
    }

    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?

    /// The pronunciation dictionary attached to the chip, and a fingerprint of
    /// the files it was built from.  nil stamp means the folder has never been
    /// looked at; an empty dictionary is a folder with nothing in it, which is
    /// the ordinary case and costs one `readdir` an utterance.
    private var dictionary: OpaquePointer?
    private var dictionaryStamp: [String]?

    /// Set once boot has been attempted; nil means it worked.
    public private(set) var bootFailure: Failure?
    public private(set) var firmwarePath: String?

    /// The settings' firmware choice the running chip was booted for.  When
    /// settings.json names a different one, the next `start` reboots on it —
    /// which is how the extension follows a switch made in the app.
    private var bootedChoice: String?

    private init() {}

    // MARK: - Firmware

    /// Where a firmware image might be.  See `FirmwareCatalog`.
    public static func firmwareSearchPaths() -> [String] {
        [FirmwareCatalog.folder.path] + FirmwareCatalog.legacyURLs.map(\.path)
    }

    public static func installedFirmwareURL() -> URL? {
        FirmwareCatalog.chosenURL()
    }

    // MARK: - Lifecycle

    /// Boot the chip if it is not already up.  Safe to call repeatedly; the
    /// failure is remembered so a missing image is not re-diagnosed on every
    /// utterance.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let choice = SettingsStore.shared.current.firmware
        if handle != nil {
            if choice == bootedChoice { return true }
            // A different image has been chosen: one engine per process, so the
            // running one goes before the new one can boot.
            shutDown()
        }

        let searched = Self.firmwareSearchPaths()
        guard let url = Self.installedFirmwareURL() else {
            bootFailure = .noFirmware(searched: searched)
            return false
        }
        guard let srec = try? SRecordImage.load(from: url) else {
            bootFailure = .noFirmware(searched: searched)
            return false
        }

        var err: UnsafeMutablePointer<CChar>?
        let h = srec.withUnsafeBytes { raw -> OpaquePointer? in
            rc8650_new_from_memory(raw.baseAddress, raw.count, &err)
        }
        guard let h else {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            err.map { free($0) }
            bootFailure = .libraryRefused(message)
            return false
        }
        // Every prefix this app builds sets STM, so the chip reports the start
        // and end of its own output and the library never has to infer the end
        // of an utterance from silence.
        rc8650_set_status_messages(h, 1)
        // The library's own reconstruction filter is switched off and stays
        // off: this app models the output stage itself, after the staircase,
        // where the analog one was. See OutputStage.
        rc8650_set_lowpass_hz(h, 0)

        // What this firmware offers: voices, presets, ranges, rate ladder.
        // Probed once here, and the chip is left at its power-on settings.
        var profile = rc8650_profile()
        guard rc8650_get_profile(h, &profile) == 0 else {
            rc8650_free(h)
            bootFailure = .noAnswer(url.path)
            return false
        }
        RC8650Chip.profile = ChipProfile(profile)

        handle = h
        firmwarePath = url.path
        bootedChoice = choice
        bootFailure = nil
        prime(h)
        Self.log.info("booted \(url.lastPathComponent, privacy: .public): \(RC8650Chip.profile.chipName, privacy: .public) \(RC8650Chip.profile.version, privacy: .public), \(RC8650Chip.profile.voices.count) voices")
        return true
    }

    /// Say something short and throw it away, so the chip's first real
    /// utterance is not also the one that pays for waking it up.
    ///
    /// Measured on this firmware: the utterance immediately following a boot
    /// produces 233 samples — the opening burst — and stops, and every one after
    /// it is whole and identical sample for sample across twenty repetitions.
    /// The retry in `render` would recover that, but only after a wasted round
    /// trip on whatever the user actually asked for; spending it here costs
    /// about a millisecond and nobody is listening.
    ///
    /// It is drained rather than stopped: reading to zero means the chip has
    /// nothing left, and a Stop would cost the utterance after it.
    private func prime(_ h: OpaquePointer) {
        var bytes = Array("\u{01}0Va".utf8)
        bytes.append(0)
        bytes.withUnsafeBufferPointer { rc8650_write(h, $0.baseAddress, $0.count) }
        var scratch = [Int16](repeating: 0, count: 512)
        for _ in 0..<128 {
            let n = scratch.withUnsafeMutableBufferPointer {
                rc8650_read_s16(h, $0.baseAddress, $0.count, nil)
            }
            if n == 0 { break }
        }
    }

    public func shutDown() {
        lock.lock()
        defer { lock.unlock() }
        if let h = handle {
            // The engine BORROWS the dictionary, so detach it before it is
            // freed — and before the engine it is attached to goes away.
            rc8650_set_dictionary(h, nil, 0)
            rc8650_free(h)
        }
        if let d = dictionary { rcdict_free(d) }
        dictionary = nil
        dictionaryStamp = nil
        handle = nil
        bootedChoice = nil
    }

    /// Cold-boot the chip again, discarding queued input and undrained audio.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        if let h = handle {
            rc8650_reset(h)
            rc8650_set_lowpass_hz(h, 0)
            prime(h)
        }
    }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle != nil
    }

    public var version: String {
        String(cString: rc8650_version())
    }

    public static let sampleRate = Double(rc8650_sample_rate())

    // MARK: - Pronunciation dictionary

    /// The dictionary files, in load order, each with a fingerprint that
    /// changes whenever the file does.
    ///
    /// Sorted, because rcdict matches first-match-wins in LOAD order: a rule in
    /// a later file cannot override an earlier one, only add to it, so
    /// `00-mine.dict` beats `50-shared.dict` and the sort is the whole of the
    /// user's control over priority.
    private static func dictionaryFiles() -> [(url: URL, stamp: String)] {
        let folder = RC8650Storage.dictionariesDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            // No folder is the normal case for someone who has never written a
            // dictionary, not a condition worth reporting.
            return []
        }
        return names
            .filter { $0.lowercased().hasSuffix(".dict") }
            .sorted()
            .map { name in
                let url = folder.appendingPathComponent(name)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let modified = (attributes?[.modificationDate] as? Date)?
                    .timeIntervalSinceReferenceDate ?? 0
                let size = (attributes?[.size] as? Int) ?? 0
                // Size as well as mtime: an editor that preserves the timestamp
                // is rare but a filesystem with one-second resolution is not,
                // and two saves inside the same second are not.
                return (url, "\(name)|\(modified)|\(size)")
            }
    }

    /// Re-read the dictionary folder if anything in it has changed.
    ///
    /// Called once per render rather than watched, for the same reason
    /// `SettingsStore` re-stats its file per utterance: a handful of `stat`
    /// calls is nothing next to synthesising speech, and it means saving a
    /// `.dict` file is all it takes for the next thing spoken to use it — no
    /// restart, no reload command, and nothing to forget.
    private func refreshDictionary(_ h: OpaquePointer) {
        let files = Self.dictionaryFiles()
        let stamp = files.map(\.stamp)
        if stamp == dictionaryStamp { return }
        dictionaryStamp = stamp

        var built: OpaquePointer?
        if !files.isEmpty {
            built = rcdict_new(rc8650_dict_profile())
            if let built {
                var rules: Int32 = 0
                for file in files {
                    // Reported, never fatal: a rule that does not parse costs
                    // that rule and the rest of the file still loads, and a
                    // file that will not open at all costs that file. A
                    // dictionary must not be able to make speech stop.
                    rules += file.url.path.withCString { rcdict_add_file(built, $0, nil, nil) }
                }
                Self.log.info("dictionary: \(rules) rules from \(files.count) file(s)")
            }
        }
        // Attach the new one BEFORE freeing the old: the engine borrows it, and
        // for the moment between the two it would otherwise be holding a
        // pointer to freed memory.
        rc8650_set_dictionary(h, built, 0)
        if let old = dictionary { rcdict_free(old) }
        dictionary = built
    }

    /// Run the dictionary over a run of text.
    ///
    /// Returns it unchanged when nothing is loaded, which is the common case,
    /// and on any failure.  Must happen BEFORE `RC8650Chip.split`: one word can
    /// become forty characters of phonemes plus the two mode switches, so a
    /// piece that fitted the chip's 2 KB input buffer before expansion may not
    /// afterwards, and the overflow is dropped by the input ring without a
    /// word.
    private func expanded(_ text: String, _ h: OpaquePointer) -> String {
        guard dictionary != nil, !text.isEmpty else { return text }
        let input = Array(text.utf8CString)     // NUL-terminated; length excludes it
        let length = input.count - 1
        let need = input.withUnsafeBufferPointer {
            rc8650_expand(h, $0.baseAddress, length, nil, 0)
        }
        if need == 0 { return text }
        var out = [CChar](repeating: 0, count: need + 1)
        input.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { destination in
                _ = rc8650_expand(h, source.baseAddress, length,
                                  destination.baseAddress, need + 1)
            }
        }
        // String(cString:) repairs ill-formed UTF-8 rather than trapping, which
        // is what is wanted here: a substring rule can in principle cut a
        // multi-byte character in half, and losing one character is a great
        // deal better than a crash in a screen reader's voice.
        return String(cString: out)
    }

    // MARK: - Speaking

    /// One item of an utterance: a run of text with the commands that set it
    /// up, or a stretch of silence a `<break>` asked for.
    public enum Item: Sendable {
        case speech(commands: String, text: String)
        case silence(samples: Int)
    }

    /// Render an utterance, handing each chunk of signed 16-bit mono PCM to
    /// `sink` as the chip produces it.
    ///
    /// `isCancelled` is polled between chunks and before each item; when it goes
    /// true the chip is sent its own Stop (CTRL+X), which clears its input
    /// buffer and drops pending audio, and rendering returns.  Short reads are
    /// normal and must not be papered over: a read returns as soon as the chip
    /// stops producing rather than running the CPU on to fill the buffer, and
    /// the end of an utterance is a read of zero, not a short one.
    ///
    /// There used to be a retry here, holding the first 100 ms back and saying
    /// the utterance again if it died inside that window, because librc8650
    /// sometimes returned nothing but the chip's opening burst.  That bug is
    /// fixed at the source now, and the retry is gone with it — re-sending text
    /// the chip may still be holding is exactly how an utterance could come out
    /// twice, which is what it sounded like when a screen reader cancelled and
    /// spoke again in quick succession.
    ///
    /// Returns true if it ran to completion, false if it was cancelled or the
    /// chip is not up.
    @discardableResult
    public func render(items: [Item],
                       chunkFrames: Int = 512,
                       isCancelled: () -> Bool,
                       sink: (UnsafeBufferPointer<Int16>) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard start(), let h = handle else { return false }
        refreshDictionary(h)

        var buffer = [Int16](repeating: 0, count: chunkFrames)

        for item in items {
            if isCancelled() { rc8650_stop(h); return false }

            switch item {
            case .silence(let samples):
                // The chip has no pause command, so a break is silence in the
                // stream rather than anything the firmware does.
                var left = samples
                for i in 0..<buffer.count { buffer[i] = 0 }
                while left > 0 {
                    if isCancelled() { return false }
                    let n = min(left, buffer.count)
                    buffer.withUnsafeBufferPointer {
                        sink(UnsafeBufferPointer(rebasing: $0[0..<n]))
                    }
                    left -= n
                }

            case .speech(let commands, let text):
                // Expand, THEN split. See `expanded`.
                for piece in RC8650Chip.split(expanded(text, h)) {
                    if isCancelled() { rc8650_stop(h); return false }
                    // Nothing is spoken until a CR or a NUL arrives; this uses
                    // NUL. The two are interchangeable as terminators, but with
                    // the punctuation filter set to "All" the chip speaks CR, LF
                    // and space — including the CR that ends the utterance,
                    // which is half a second of unwanted speech on every one.
                    // NUL is not in that set.
                    var bytes = Array((commands + piece).utf8)
                    bytes.append(0)
                    bytes.withUnsafeBufferPointer { rc8650_write(h, $0.baseAddress, $0.count) }

                    while true {
                        if isCancelled() { rc8650_stop(h); return false }
                        var done: Int32 = 0
                        let n = buffer.withUnsafeMutableBufferPointer { out -> Int in
                            rc8650_read_s16(h, out.baseAddress, out.count, &done)
                        }
                        if n == 0 { break }
                        buffer.withUnsafeBufferPointer {
                            sink(UnsafeBufferPointer(rebasing: $0[0..<n]))
                        }
                    }
                }
            }
        }
        return true
    }

    /// Stop the chip now, outside any render.  librc8650 delivers the stop to
    /// the chip before returning rather than merely queuing it, which is what
    /// makes cancel-then-speak safe.
    public func stopNow() {
        lock.lock()
        defer { lock.unlock() }
        if let h = handle { rc8650_stop(h) }
    }

    // MARK: - Queries

    /// The 8-byte chipset identification returned by 6?.
    public func chipID() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard start(), let h = handle else { return nil }
        var buf = [UInt8](repeating: 0, count: 8)
        let ok = buf.withUnsafeMutableBufferPointer { rc8650_chip_id(h, $0.baseAddress) }
        return ok == 0 ? buf : nil
    }

    /// The Interrogate reply (12?, datasheet Table 19) — 23 bytes, or 27 on the
    /// RC8660 — the chip's own
    /// account of every setting it is holding.  Nothing here is inferred; this
    /// is how the presets and ranges in RC8650Chip were established, and the
    /// container app shows it live so a user can check the same way.
    public func interrogate() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard start(), let h = handle else { return nil }

        let query = "\u{01}12?\r"
        query.withCString { rc8650_write(h, $0, strlen($0)) }

        var reply = [UInt8]()
        var pcm = [Int16](repeating: 0, count: 256)
        for _ in 0..<64 {
            var chunk = [UInt8](repeating: 0, count: 32)
            let n = chunk.withUnsafeMutableBufferPointer { rc8650_read_serial(h, $0.baseAddress, $0.count) }
            if n > 0 {
                reply.append(contentsOf: chunk[0..<n])
                // All of it: stopping at 23 on an RC8660 would leave its last
                // four bytes queued in front of the next reply.
                if reply.count >= RC8650Chip.profile.interrogateLength { break }
            } else {
                // Nothing waiting: let the CPU run a little by pulling audio.
                let got = pcm.withUnsafeMutableBufferPointer { rc8650_read_s16(h, $0.baseAddress, $0.count, nil) }
                if got == 0 { break }
            }
        }
        let length = RC8650Chip.profile.interrogateLength
        return reply.count >= 23 ? Array(reply.prefix(length)) : nil
    }

    /// Send a raw command as <CTRL+A>cmd<CR> and return whatever the chip says
    /// back.  The escape hatch for the commands with no control of their own.
    public func sendRawCommand(_ command: String) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        guard start(), let h = handle else { return [] }
        let message = "\u{01}\(command)\r"
        message.withCString { rc8650_write(h, $0, strlen($0)) }

        var reply = [UInt8]()
        var pcm = [Int16](repeating: 0, count: 512)
        for _ in 0..<32 {
            var chunk = [UInt8](repeating: 0, count: 64)
            let n = chunk.withUnsafeMutableBufferPointer { rc8650_read_serial(h, $0.baseAddress, $0.count) }
            if n > 0 {
                reply.append(contentsOf: chunk[0..<n])
            } else {
                let got = pcm.withUnsafeMutableBufferPointer { rc8650_read_s16(h, $0.baseAddress, $0.count, nil) }
                if got == 0 { break }
            }
        }
        return reply
    }
}
