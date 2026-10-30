import SwiftUI

/// The Punctuation Filter Register (nB, datasheet Table 8), split into the four
/// independent things it actually controls, plus what the extension does with
/// the rate, pitch and volume the calling app asks for.
struct TextTab: View {

    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Punctuation filter")
                    .font(.headline)

                ChoiceRow(
                    title: "Speak punctuation",
                    value: $model.parameters.punctuation,
                    options: RC8650Chip.punctuationModes,
                    caption: "PFR bits 1-0. \"Some\" is the card's own default and what suits a screen reader that does its own symbol processing.")

                ToggleRow(
                    title: "Read numbers as numbers",
                    value: $model.parameters.numbersAsNumbers,
                    caption: "PFR bit 2. Off spells them out digit by digit.")

                ToggleRow(
                    title: "Speak leading zeros",
                    value: $model.parameters.speakLeadingZeros,
                    caption: "PFR bit 3 (LZS), which the datasheet defines inverted: set means do NOT suppress. On by default here rather than the chip's own 6B, because on screen \"007\" is content and saying \"seven\" drops two characters the user can see.")

                ToggleRow(
                    title: "Read four-digit numbers as years",
                    value: $model.parameters.readYears,
                    caption: "PFR bit 4 (YM), also inverted: the bit clear is what selects year reading. 1984 becomes \"nineteen eighty-four\" rather than \"one thousand nine hundred eighty-four\".")

                LabeledContent("Register value") {
                    Text(String(format: "%dB — 0x%02x", model.parameters.pfr, model.parameters.pfr))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("What a calling app is allowed to change")
                    .font(.headline)
                Text("""
                     An app speaking through AVSpeechUtterance sets its own rate, pitch and \
                     volume. Each is applied relative to the settings above, so an app that \
                     leaves the defaults alone gets exactly what this window shows. Turn one \
                     off if some app's idea of "fast" is not yours.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Honour the utterance's rate", isOn: $model.settings.honorUtteranceRate)
                Toggle("Honour the utterance's pitch", isOn: $model.settings.honorUtterancePitch)
                Toggle("Honour the utterance's volume", isOn: $model.settings.honorUtteranceVolume)

                Divider()

                Text("Around every utterance")
                    .font(.headline)
                Text("""
                     Sent before and after the text, inside the same utterance. The escape \
                     hatch for chip features with no control of their own — a leading \
                     \u{01}nD puts the text after it into phoneme mode, for instance.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Preamble") {
                    TextField("", text: $model.settings.preamble)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Postamble") {
                    TextField("", text: $model.settings.postamble)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .padding(16)
        }
    }
}
