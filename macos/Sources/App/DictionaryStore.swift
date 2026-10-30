// The pronunciation dictionaries the extension speaks with: what is in the
// folder, and everything the app does to it.
//
// WHY THE FILES ARE COPIED IN AND NOT LINKED.  The obvious design is to leave a
// dictionary where the user keeps it and put a symlink in the folder, so that
// the file they edit is the file the synthesizer reads.  That is what the NVDA
// add-ons do — they store a path and never copy — and it cannot be done here.
//
// Both halves of this project are sandboxed: macOS refuses to load an app
// extension that is not ("plug-ins must be sandboxed", from pkd), and the
// extension's entitlements carry the App Group and nothing else.  The sandbox
// authorizes by path AFTER resolving symlinks, so a link in the group container
// pointing at ~/Documents/spanish.dict asks the extension to read
// ~/Documents/spanish.dict, which it may not do.  The link would resolve, the
// open would fail, and the dictionary would simply not apply — silently, since
// a dictionary that cannot be read is not allowed to stop speech.
//
// Nor do the near-misses work.  `com.apple.security.files.user-selected` is the
// app's, not the extension's, and covers only what the user picked in this
// launch; a security-scoped bookmark is scoped to the bundle identifier that
// made it, so the app cannot hand one to the extension.  A hard link would
// survive the sandbox — same inode, no path to authorize — but not the first
// edit: almost every editor saves atomically by writing a temporary file and
// renaming it over the original, which leaves the hard link pointing at the old
// inode and the user editing a file the synthesizer no longer reads.
//
// So the copy is forced, and the cost of a copy is that it goes stale the
// moment someone edits the original.  That is what the built-in editor is for:
// it edits the copy, in place, which makes the copy the document rather than a
// snapshot of one.

import Foundation
import Observation
import CRC8650

/// One `.dict` file, with what parsing it had to say about it.
struct DictionaryFile: Identifiable, Hashable {

    var url: URL
    var size: Int
    var modified: Date
    /// How many rules loaded.  Not the number of lines: comments, directives
    /// and anything that did not parse are not rules.
    var ruleCount: Int
    var problems: [Problem]

    var id: String { url.lastPathComponent }
    var name: String { url.lastPathComponent }

    struct Problem: Hashable, Identifiable {
        var line: Int?
        var message: String
        var id: String { "\(line ?? -1):\(message)" }

        var display: String {
            if let line { return "Line \(line): \(message)" }
            return message
        }
    }
}

/// rcdict's diagnostic callback.  At file scope because a C function pointer
/// cannot be formed from anything that captures, and a closure written inside
/// the type would capture it just by naming one of its members.
private let dictionaryReport: rcdict_report = { context, _, message in
    guard let context, let message else { return }
    let collector = Unmanaged<DictionaryValidator.Collector>
        .fromOpaque(context).takeUnretainedValue()
    collector.problems.append(DictionaryValidator.problem(String(cString: message)))
}

/// Parsing a dictionary without speaking with it, so that the editor and the
/// list can both say what a file is worth before anything tries to use it.
enum DictionaryValidator {

    struct Result {
        var ruleCount: Int
        var problems: [DictionaryFile.Problem]
    }

    /// Collects the diagnostics rcdict reports.  A class because the callback
    /// is a C function pointer, which cannot capture, so the only way through
    /// is the void * context rcdict passes back.
    final class Collector {
        var problems: [DictionaryFile.Problem] = []
    }

    static func validate(text: String, name: String) -> Result {
        guard let dict = rcdict_new(rc8650_dict_profile()) else {
            return Result(ruleCount: 0, problems: [])
        }
        defer { rcdict_free(dict) }

        let collector = Collector()
        let rules = withExtendedLifetime(collector) { () -> Int32 in
            let context = Unmanaged.passUnretained(collector).toOpaque()
            return text.withCString { source in
                name.withCString { name in
                    rcdict_add_text(dict, source, strlen(source), name,
                                    dictionaryReport, context)
                }
            }
        }
        return Result(ruleCount: Int(rules), problems: collector.problems)
    }

    static func validate(url: URL) -> Result {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Result(ruleCount: 0, problems: [
                .init(line: nil, message: "The file could not be read as UTF-8 text.")
            ])
        }
        return validate(text: text, name: url.lastPathComponent)
    }

    /// rcdict's loaders prefix a diagnostic with "<file>:<line>: ".  The file is
    /// already the one on screen, so it is taken off and the line is pulled out
    /// to be shown as its own field.
    static func problem(_ message: String) -> DictionaryFile.Problem {
        let parts = message.split(separator: ":", maxSplits: 2,
                                  omittingEmptySubsequences: false)
        if parts.count == 3, let line = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
            return .init(line: line,
                         message: parts[2].trimmingCharacters(in: .whitespaces))
        }
        return .init(line: nil, message: message)
    }
}

/// Runs a dictionary over some text, so the editor can show what it actually
/// does rather than only whether it parses.
enum DictionaryPreview {

    /// The expansion, with the chip's control bytes made visible — a raw 0x01
    /// in a text view is an invisible box, and the whole point of looking is to
    /// see where the phoneme mode switches landed.
    static func expand(text: String, dictionary source: String,
                       name: String) -> String {
        guard let dict = rcdict_new(rc8650_dict_profile()) else { return text }
        defer { rcdict_free(dict) }
        _ = source.withCString { source in
            name.withCString { name in
                rcdict_add_text(dict, source, strlen(source), name, nil, nil)
            }
        }

        var options = rcdict_options()
        rcdict_options_init(&options, rc8650_dict_profile())
        options.dict = dict

        let input = Array(text.utf8CString)
        let length = input.count - 1
        let need = input.withUnsafeBufferPointer {
            rcdict_expand(&options, $0.baseAddress, length, nil, 0, nil, nil)
        }
        guard need > 0 else { return "" }
        var out = [CChar](repeating: 0, count: need + 1)
        input.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { destination in
                _ = rcdict_expand(&options, source.baseAddress, length,
                                  destination.baseAddress, need + 1, nil, nil)
            }
        }
        return readable(String(cString: out))
    }

    static func readable(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\u{01}": out += "⌃A"
            case "\r": out += "⏎"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "<%02X>", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

@Observable
@MainActor
final class DictionaryStore {

    /// In load order, which here IS sorted filename order: the extension loads
    /// every `.dict` in the folder sorted by name, and rcdict matches
    /// first-match-wins, so the first file cannot be overridden by a later one
    /// — only added to.  This is why the list is numbered.
    private(set) var files: [DictionaryFile] = []
    var status = ""

    var folder: URL { RC8650Storage.dictionariesDirectory }

    init() { reload() }

    func reload() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else {
            // Never having written a dictionary is the normal state, not an
            // error worth putting on screen.
            files = []
            return
        }
        files = names
            .filter { $0.lowercased().hasSuffix(".dict") }
            .sorted()
            .map { name in
                let url = folder.appendingPathComponent(name)
                let attributes = try? manager.attributesOfItem(atPath: url.path)
                let result = DictionaryValidator.validate(url: url)
                return DictionaryFile(
                    url: url,
                    size: (attributes?[.size] as? Int) ?? 0,
                    modified: (attributes?[.modificationDate] as? Date) ?? .distantPast,
                    ruleCount: result.ruleCount,
                    problems: result.problems)
            }
    }

    // MARK: - Editing the folder

    func importFiles(from urls: [URL]) {
        do {
            try RC8650Storage.ensureDirectory()
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
            var copied = 0
            for source in urls {
                // The panel's selection is what com.apple.security.files.
                // user-selected covers, and it covers it only while it is being
                // read — hence the copy happening here and now.
                let accessing = source.startAccessingSecurityScopedResource()
                defer { if accessing { source.stopAccessingSecurityScopedResource() } }
                let destination = availableURL(for: source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: destination)
                copied += 1
            }
            reload()
            status = copied == 1
                ? "Imported \(urls[0].lastPathComponent). It is a copy — edit it here, not where it came from."
                : "Imported \(copied) dictionaries. They are copies — edit them here."
        } catch {
            status = "Could not import: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func create(named name: String, contents: String = DictionaryStore.template) -> URL? {
        do {
            try RC8650Storage.ensureDirectory()
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
            let url = availableURL(for: dictName(name))
            try contents.write(to: url, atomically: true, encoding: .utf8)
            reload()
            status = "Created \(url.lastPathComponent)."
            return url
        } catch {
            status = "Could not create it: \(error.localizedDescription)"
            return nil
        }
    }

    func rename(_ file: DictionaryFile, to name: String) {
        let wanted = dictName(name)
        guard wanted != file.name else { return }
        do {
            let destination = folder.appendingPathComponent(wanted)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                status = "There is already a dictionary called \(wanted)."
                return
            }
            try FileManager.default.moveItem(at: file.url, to: destination)
            reload()
            status = "Renamed to \(wanted)."
        } catch {
            status = "Could not rename: \(error.localizedDescription)"
        }
    }

    /// To the Trash rather than unlinked, because this is the user's document
    /// and an undo they already know how to reach is worth more than a
    /// confirmation dialog.
    func delete(_ file: DictionaryFile) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            reload()
            status = "Moved \(file.name) to the Trash."
        } catch {
            status = "Could not delete it: \(error.localizedDescription)"
        }
    }

    func duplicate(_ file: DictionaryFile) {
        do {
            let base = file.url.deletingPathExtension().lastPathComponent
            let destination = availableURL(for: "\(base) copy.dict")
            try FileManager.default.copyItem(at: file.url, to: destination)
            reload()
            status = "Duplicated as \(destination.lastPathComponent)."
        } catch {
            status = "Could not duplicate it: \(error.localizedDescription)"
        }
    }

    func text(of file: DictionaryFile) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }

    func write(_ text: String, to url: URL) throws {
        try RC8650Storage.ensureDirectory()
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    // MARK: - Names

    private func dictName(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = "Untitled" }
        // The extension only loads files ending in .dict, so a name without it
        // would produce a file that silently does nothing.
        if !trimmed.lowercased().hasSuffix(".dict") { trimmed += ".dict" }
        return trimmed.replacingOccurrences(of: "/", with: ":")
    }

    private func availableURL(for name: String) -> URL {
        let name = dictName(name)
        var candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }
        let base = candidate.deletingPathExtension().lastPathComponent
        var n = 2
        repeat {
            candidate = folder.appendingPathComponent("\(base) \(n).dict")
            n += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    /// What a new dictionary starts as.  Enough of the format to work from
    /// without opening the guide, and every line commented out so that a new
    /// file changes nothing until something is written in it.
    nonisolated static let template = """
        ; A pronunciation dictionary for the RC8650.
        ;
        ; COLUMNS ARE SEPARATED BY TABS:  type <TAB> flags <TAB> pattern <TAB> output
        ; The flags column may be empty or left out. Comments start with ';' and
        ; must be on lines of their own.

        #!rcdict 1
        #!case insensitive

        ; Respell a word — the output goes back through the chip's own
        ; letter-to-sound stage, so it keeps all of its intonation.
        ; word\tSean\tShon

        ; Or give phonemes outright, in square brackets.
        ; word\tNVDA\t[EH N V IY D IY EY]

        ; 'text' matches inside words too; 'regex' takes \\1-\\9 from its groups.
        ; text\tMbps\tmegabits per second
        ; regex\t([0-9]+)%\t\\1 percent

        ; 'rule' is the chip's own exception syntax, L(F)R: the fragment in
        ; parentheses is replaced and the contexts around it are only looked at.
        ; This one gives the o of 'icon' the sound in 'cot'.
        ; rule\tC(O)N\t[AA]

        """
}
