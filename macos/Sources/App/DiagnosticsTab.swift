import SwiftUI

/// What the chip itself says, and where the pieces are.
///
/// The Interrogate table is the ground truth for everything in this app: the
/// per-voice presets, the ranges each command clamps to and the effect of every
/// command letter were all established by sending something and reading this
/// back.  It is here so the same check is available to anyone who doubts a
/// setting.
struct DiagnosticsTab: View {

    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                Text("Firmware")
                    .font(.headline)
                if !model.firmwareImages.isEmpty {
                    // Every image in the firmware folder, each described by its
                    // own header. Choosing one reboots the chip on it here, and
                    // the system voices follow on their next utterance.
                    Picker("Image", selection: $model.selectedFirmware) {
                        ForEach(model.firmwareImages) { image in
                            Text("\(image.label) — \(image.name)").tag(image.url.path)
                        }
                    }
                    LabeledContent("Running") {
                        Text("\(model.chip.chipName) firmware \(model.chip.version), model \(model.chip.model): \(model.chip.voices.count) voices, formant \(model.chip.formantRange.lowerBound)–\(model.chip.formantRange.upperBound), \(model.chip.rateLadder.count) rate steps")
                            .textSelection(.enabled)
                    }
                    if let path = model.firmwarePath {
                        LabeledContent("File") {
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text("""
                         No firmware image installed. RC Systems' firmware is their \
                         copyrighted code and is not distributed with this app: add your \
                         own Motorola S-record image, for the RC8650 or the RC8660. \
                         tools/rcstudio2srec.py in librc8650 makes them from RCStudio's files.
                         """)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.bootError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Add Firmware Image…") { model.chooseFirmware() }
                    Button("Cold-Boot the Chip") { model.resetChip() }
                }

                Divider()

                Text("System voices")
                    .font(.headline)
                if model.systemVoiceInstalled {
                    Label("macOS is offering the RC8650 voices.", systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                } else {
                    Text("""
                         macOS is not offering the RC8650 voices yet. The extension is \
                         registered when the app that carries it is: move RC8650.app to \
                         /Applications and open it once, then look in System Settings ▸ \
                         Accessibility ▸ Spoken Content ▸ System Voice.
                         """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Refresh the System Voice List") { model.refreshSystemVoices() }

                Divider()

                Text("Identification — 6?")
                    .font(.headline)
                if let id = model.chipIdentification {
                    ByteDump(bytes: id)
                    Text(identificationSummary(id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The chip has not answered 6?.").foregroundStyle(.secondary)
                }

                Divider()

                Text("Interrogate — 12?")
                    .font(.headline)
                HStack {
                    Button("Interrogate") { model.interrogate() }
                    Button("Apply These Settings, Then Interrogate") { model.applyParametersToChip() }
                }
                if let reply = model.interrogation {
                    interrogationTable(reply)
                } else {
                    Text("""
                         The chip's own account of all 23 of its settings, decoded 23-for-23 \
                         against datasheet Table 19.
                         """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("Raw command")
                    .font(.headline)
                Text("Sent as <CTRL+A> your text <CR>. Anything the firmware accepts, including the commands with no control of their own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("12?", text: $model.rawCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { model.sendRawCommand() }
                    Button("Send") { model.sendRawCommand() }
                }
                if !model.rawReply.isEmpty {
                    ByteDump(bytes: model.rawReply)
                }

                Divider()

                LabeledContent("Library") {
                    Text(RC8650Engine.shared.version).font(.system(.caption, design: .monospaced))
                }
                LabeledContent("D/A sample rate") {
                    Text("\(Int(RC8650Chip.sampleRate)) Hz").monospacedDigit()
                }
                LabeledContent("Settings file") {
                    Text(RC8650Storage.settingsURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                // The dictionaries folder is inside a group container, which
                // nobody is going to guess at; without this there is no way to
                // find out where to put a .dict file. Every .dict in it is
                // loaded in sorted order and re-read whenever it changes, so
                // saving a file there is the whole of the workflow.
                LabeledContent("Dictionaries") {
                    Text(RC8650Storage.dictionariesDirectory.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        }
    }

    private func interrogationTable(_ reply: [UInt8]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(RC8650Chip.interrogateFields.enumerated()), id: \.offset) { index, name in
                if index < reply.count {
                    HStack {
                        Text(name).frame(width: 220, alignment: .leading)
                        Text("\(reply[index])").monospacedDigit()
                        if let note = note(field: index, value: reply[index]) {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func note(field: Int, value: UInt8) -> String? {
        switch field {
        case 0:  return value == 2 ? "text" : (value == 0 ? "character" : "mode \(value)")
        case 6:  return Int(value) < RC8650Chip.tones.count ? RC8650Chip.tones[Int(value)].name : nil
        // Both sizes are the code times a unit, fixed against the real board's
        // reply: input buffer 8 is its 2048 bytes, recording memory 8 its 512 KB.
        case 10: return "\(Int(value) * 256) bytes"
        case 13: return Int(value) < RC8650Chip.tsPinModes.count ? RC8650Chip.tsPinModes[Int(value)].name : nil
        case 16: return "\(Int(value) * 64) KB"
        case 21: return RC8650Chip.voice(id: Int(value)).name
        default: return nil
        }
    }

    /// The 6? reply, decoded against the fields of the real board's answer.
    private func identificationSummary(_ id: [UInt8]) -> String {
        guard id.count >= 8 else { return "" }
        func bcd(_ hi: UInt8, _ lo: UInt8) -> String {
            String(format: "%x.%02x", lo, hi)
        }
        return "flash id \(String(format: "%02x %02x", id[0], id[1])) · model \(id[2]) · "
             + "family \(id[3]) · BIOS \(bcd(id[4], id[5])) · firmware \(bcd(id[6], id[7]))"
    }
}
