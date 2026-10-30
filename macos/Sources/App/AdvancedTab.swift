import SwiftUI

/// The registers and the odds and ends: everything the firmware will accept
/// that has no obvious home on another tab.
///
/// Which command letter moves which field was established by sending
/// <CTRL+A>n<letter> for every letter A-Z to the emulated firmware and diffing
/// the 23-byte Interrogate reply before and after.  Six letters — H, L, M, U, W
/// and Z — move nothing in that reply; they are the dictionary, recording and
/// programming commands, which have state of their own, and the raw console at
/// the bottom of this tab is how to reach them.
struct AdvancedTab: View {

    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                Text("Protocol Options Register — nG")
                    .font(.headline)
                Text("""
                     Bit 4 is not writable: sending 255G reads back as 239. Bit 7 is not \
                     yours to set here either — the rate ladder on the Voice tab owns it, \
                     since it is what selects which of the chip's two speed scales nS \
                     indexes into. Bit 0 is forced on, because the status messages it \
                     enables are how librc8650 knows an utterance has ended.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                BitRow(title: "Bit 0 — status messages (STM)",
                       bit: 0, register: .constant(1),
                       caption: "Always on. The chip transmits one byte when its output starts and another when it stops, and the stop lands 64 instructions after the final sample.")
                    .disabled(true)
                BitRow(title: "Bit 1", bit: 1, register: $model.parameters.por)
                BitRow(title: "Bit 2", bit: 2, register: $model.parameters.por)
                BitRow(title: "Bit 3", bit: 3, register: $model.parameters.por)
                BitRow(title: "Bit 5", bit: 5, register: $model.parameters.por)
                BitRow(title: "Bit 6", bit: 6, register: $model.parameters.por)

                LabeledContent("Register value") {
                    Text(String(format: "%dG — 0x%02x",
                                effectivePOR, effectivePOR))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("Audio Control Register — nN")
                    .font(.headline)
                Text("A whole byte: 255N reads back as 255. The datasheet's own account of the bits is the authority; this is the raw value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                IntSliderRow(title: "ACR", value: $model.parameters.acr, range: RC8650Chip.acrRange,
                             display: { String(format: "%d (0x%02x)", $0, $0) })

                Divider()

                Text("Power and timing")
                    .font(.headline)

                IntSliderRow(
                    title: "Sleep", value: $model.parameters.sleep, range: RC8650Chip.sleepRange,
                    caption: "nQ 0-31; 255Q reads back as 31. 0 disables it.")
                IntSliderRow(
                    title: "Timeout", value: $model.parameters.timeout, range: RC8650Chip.timeoutRange,
                    caption: "nY 0-15; 255Y reads back as 15. 0 disables it.")

                ChoiceRow(
                    title: "TS pin", value: $model.parameters.tsPin, options: RC8650Chip.tsPinModes,
                    caption: "nK, Table 16. The talk-status output pin — P9 bit 2 on the M16C. It drives nothing here, but it is a chip setting and librc8650 reads it to know when an utterance has really ended, so pinning it forces that off.")

                Divider()

                Text("The commands these compile to")
                    .font(.headline)
                Text(prefixDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .accessibilityLabel("Command prefix")
                    .accessibilityValue(prefixDisplay)

                Text("""
                     Sent in this order for a reason. The register goes first: in the other \
                     order this firmware emits a 23 ms burst at 5% of full scale — an \
                     audible blip — before it settles and speaks. The voice goes next, \
                     because selecting one reloads seven parameters from its firmware \
                     preset and anything sent before it would be clobbered. A parameter \
                     sitting at its preset is not sent at all.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Reset All Settings") { model.resetEverything() }
                    Spacer()
                }
            }
            .padding(16)
        }
    }

    private var effectivePOR: Int {
        let rung = RC8650Chip.rateLadder[min(model.parameters.rateRung, RC8650Chip.rateLadder.count - 1)]
        var por = (model.parameters.por & RC8650Chip.POR.writableMask) & ~RC8650Chip.POR.v86Rate
        por |= rung.por & RC8650Chip.POR.v86Rate
        por |= RC8650Chip.POR.statusMessages
        return por
    }

    private var prefixDisplay: String {
        model.parameters.commandPrefix
            .replacingOccurrences(of: "\u{01}", with: "\n^A")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
