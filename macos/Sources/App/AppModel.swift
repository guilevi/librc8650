import AVFoundation
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppModel {

    // MARK: - Settings

    var settings: RC8650Settings {
        didSet { persist() }
    }

    /// The parameters of the voice currently being edited.  Kept as its own
    /// property so SwiftUI can bind straight to its fields; written back into
    /// `settings` on every change.
    var parameters: Parameters {
        didSet {
            guard parameters != oldValue else { return }
            if parameters.voice != oldValue.voice {
                // A voice change on the real chip reloads seven parameters from
                // that voice's firmware preset, so the editor follows: switching
                // to Skip shows Skip's tuning, not Vader's imposed on it.
                settings.editingVoice = parameters.voice
                parameters = settings.parameters(for: parameters.voice)
                return
            }
            settings.setParameters(parameters, for: parameters.voice)
        }
    }

    // MARK: - Bench state

    var text = "The RC8650 speech synthesizer, emulated. Testing one two three."
    var status = ""
    var isSpeaking = false
    var lastRender: RenderReport?

    var chipIdentification: [UInt8]?
    var interrogation: [UInt8]?
    var rawCommand = "12?"
    var rawReply: [UInt8] = []

    var firmwarePath: String?
    var bootError: String?

    /// Every firmware image found, and what the running one is.  The profile is
    /// kept here as well as in RC8650Chip so that SwiftUI sees it change: a view
    /// that lists voices or sizes a slider reads it, and redraws on a switch.
    var firmwareImages: [FirmwareCatalog.Image] = []
    var chip: ChipProfile = RC8650Chip.profile

    /// The dictionaries the extension speaks with.  Owned here rather than by
    /// the tab so that the editor windows — which are their own scenes — see
    /// the same list, and so that it survives the tab being switched away from.
    let dictionaries = DictionaryStore()

    struct RenderReport: Sendable {
        var frames: Int
        var seconds: Double
        var wallClock: Double
        var realtimeFactor: Double { wallClock > 0 ? seconds / wallClock : 0 }
    }

    private let player = LocalPlayer()
    private let systemSynthesizer = AVSpeechSynthesizer()
    private var renderTask: Task<Void, Never>?

    init() {
        let loaded = SettingsStore.shared.current
        settings = loaded
        parameters = loaded.parameters(for: loaded.editingVoice)
        refreshChipState()
        // Again, now the chip is up: settings are kept per chip, and which chip
        // that is was not known until the chosen image had booted.
        parameters = settings.parameters(for: settings.editingVoice)
    }

    private func persist() {
        try? SettingsStore.shared.save(settings)
    }

    // MARK: - Firmware and chip state

    func refreshChipState() {
        firmwareImages = FirmwareCatalog.images()
        if RC8650Engine.shared.start() {
            bootError = nil
            chipIdentification = RC8650Engine.shared.chipID()
        } else {
            bootError = RC8650Engine.shared.bootFailure?.localizedDescription
            chipIdentification = nil
        }
        firmwarePath = RC8650Engine.shared.firmwarePath
            ?? RC8650Engine.installedFirmwareURL()?.path
        chip = RC8650Chip.profile
    }

    /// The image the chip is running, for the firmware picker.
    var selectedFirmware: String {
        get { firmwarePath ?? "" }
        set {
            guard let image = firmwareImages.first(where: { $0.url.path == newValue }) else { return }
            selectFirmware(image)
        }
    }

    /// Run a different image.  The choice goes in settings.json, which is what
    /// the extension reads, so the system voices follow on their next utterance;
    /// the engine here reboots on it at once.
    func selectFirmware(_ image: FirmwareCatalog.Image) {
        stop()
        let inFolder = image.url.deletingLastPathComponent().standardizedFileURL
            == FirmwareCatalog.folder.standardizedFileURL
        settings.firmware = inFolder ? image.name : image.url.path
        refreshChipState()
        // Settings are kept per chip, so the editor reloads for this one.
        if settings.editingVoice >= chip.voices.count { settings.editingVoice = 0 }
        parameters = settings.parameters(for: settings.editingVoice)
        AVSpeechSynthesisProviderVoice.updateSpeechVoices()
        status = bootError ?? "Running \(image.label): \(chip.voices.count) voices."
    }

    /// Ask for the user's own firmware image and put it where both this app and
    /// the extension look.  RC Systems' copyrighted code: it is not shipped
    /// with any of this, and it is not this app's to distribute.
    func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.title = "Add a firmware image"
        panel.message = "A Motorola S-record image of RC8650 or RC8660 firmware (.srec, or .srec.gz). tools/rcstudio2srec.py in librc8650 makes them from RCStudio's files."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installFirmware(from: url)
    }

    /// Copy an image into the firmware folder, where the extension can read it
    /// too, and switch to it.
    func installFirmware(from url: URL) {
        guard FirmwareCatalog.identify(url) != nil else {
            status = "\(url.lastPathComponent) is not an RC8650 or RC8660 firmware image."
            return
        }
        do {
            let destination = try FirmwareCatalog.install(from: url)
            firmwareImages = FirmwareCatalog.images()
            if let image = FirmwareCatalog.identify(destination) {
                selectFirmware(image)
            }
        } catch {
            status = "Could not install firmware: \(error.localizedDescription)"
        }
    }

    /// Tell the system the set of voices this app provides may have changed —
    /// what makes the voices appear once a firmware image is finally in place.
    func refreshSystemVoices() {
        AVSpeechSynthesisProviderVoice.updateSpeechVoices()
        status = "Asked the system to refresh its voice list."
    }

    var systemVoiceInstalled: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains {
            $0.identifier.contains("com.guilevi.rc8650.voice.")
        }
    }

    // MARK: - Speaking, straight to the emulator

    /// Speak the bench text, or something else instead — the dictionary editor
    /// passes its own sample so that a rule can be heard from the window it was
    /// written in, without disturbing what is in the main text field.
    func speak(_ override: String? = nil) {
        stop()
        guard RC8650Engine.shared.start() else {
            status = RC8650Engine.shared.bootFailure?.localizedDescription ?? "Chip not available."
            return
        }
        isSpeaking = true
        status = ""
        let parameters = self.parameters
        let text = override ?? self.text
        renderTask = Task { [weak self] in
            let report = await self?.player.play(parameters: parameters, text: text)
            await MainActor.run {
                self?.isSpeaking = false
                self?.lastRender = report
            }
        }
    }

    func stop() {
        player.stop()
        renderTask?.cancel()
        renderTask = nil
        isSpeaking = false
    }

    // MARK: - Speaking through macOS, so the extension itself is exercised

    /// The system's own identifier for one of our voices.
    ///
    /// Not the identifier the extension hands out: macOS namespaces a provided
    /// voice under the extension's bundle identifier, so what the extension
    /// calls `com.guilevi.rc8650.voice.3` the system calls
    /// `com.guilevi.rc8650.voices.com.guilevi.rc8650.voice.3`.  Match on the
    /// suffix rather than assuming either spelling.
    static func systemVoice(forVoice id: Int) -> AVSpeechSynthesisVoice? {
        let suffix = RC8650Chip.voice(id: id).identifier
        return AVSpeechSynthesisVoice.speechVoices().first {
            $0.identifier == suffix || $0.identifier.hasSuffix(suffix)
        }
    }

    func speakThroughSystem() {
        systemSynthesizer.stopSpeaking(at: .immediate)
        guard let voice = Self.systemVoice(forVoice: parameters.voice) else {
            status = """
                macOS does not have the RC8650 voices yet. Build and run this app from \
                /Applications, then look in System Settings ▸ Accessibility ▸ Spoken Content \
                ▸ System Voice.
                """
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        systemSynthesizer.speak(utterance)
        status = "Speaking \(voice.name) through AVSpeechSynthesizer."
    }

    func stopSystem() {
        systemSynthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Queries

    /// Ask the chip what it is actually holding.  This is the ground truth for
    /// everything in the editor: the presets and ranges in RC8650Chip were
    /// established by sending a command and diffing this reply.
    func interrogate() {
        guard let reply = RC8650Engine.shared.interrogate() else {
            status = "The chip did not answer 12?."
            return
        }
        interrogation = reply
    }

    /// Send the editor's settings to the chip as the commands they compile to,
    /// then interrogate it — so what the table below shows is the chip's own
    /// account of what the editor asked for, not the editor read back to itself.
    func applyParametersToChip() {
        for command in parameters.commandPrefix.split(separator: "\u{01}") {
            _ = RC8650Engine.shared.sendRawCommand(String(command))
        }
        interrogate()
    }

    func sendRawCommand() {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        rawReply = RC8650Engine.shared.sendRawCommand(command)
        status = rawReply.isEmpty
            ? "Sent <CTRL+A>\(command)<CR>; no reply."
            : "Sent <CTRL+A>\(command)<CR>; \(rawReply.count) bytes back."
    }

    func resetChip() {
        RC8650Engine.shared.reset()
        interrogation = nil
        status = "Chip cold-booted."
    }

    // MARK: - Editing helpers

    func resetToPreset() {
        var p = parameters
        p.applyPreset(of: p.voice)
        parameters = p
        settings.setParameters(p, for: p.voice)
    }

    func resetEverything() {
        settings = RC8650Settings()
        parameters = settings.parameters(for: settings.editingVoice)
    }
}
