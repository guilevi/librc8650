import SwiftUI

/// The modeled output stage.
///
/// Not a chip command: AO0 and AO1 are unfiltered D/A pins, and the datasheet
/// calls an external low-pass "highly recommended" — its own reference circuit
/// (Figure 7) being a 3 kHz filter and amplifier.  So the filter is part of what
/// a finished RC8650 product sounded like rather than an effect added on top,
/// and turning it off gives you the bare 10 kHz sample-and-hold staircase the
/// pins themselves put out, imaging hiss and all.
struct OutputTab: View {

    @Bindable var model: AppModel

    /// The corner frequency, snapped to the range a filter is designed for.
    /// A slider allowed below 500 Hz would show a number the filter is not
    /// using; the switch above is how you get to zero.
    private var corner: Binding<Int> {
        Binding(
            get: { model.parameters.lowpassCornerHz.clamped(to: RC8650Chip.lowpassRange) },
            set: { model.parameters.lowpassCornerHz = $0.clamped(to: RC8650Chip.lowpassRange) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Reconstruction filter")
                    .font(.headline)

                Toggle("Filter the output", isOn: $model.parameters.lowpassEnabled)
                Text("""
                     Off is the bare D/A: the unfiltered 10 kHz sample-and-hold staircase \
                     the AO pins themselves put out, imaging hiss and all. The corner \
                     frequency below is kept while it is off, so switching back on \
                     restores it.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Picker("Preset", selection: corner) {
                    ForEach(RC8650Chip.lowpassPresets, id: \.hz) { preset in
                        Text(preset.name).tag(preset.hz)
                    }
                    if !RC8650Chip.lowpassPresets.contains(where: { $0.hz == corner.wrappedValue }) {
                        Text("Custom — \(corner.wrappedValue) Hz").tag(corner.wrappedValue)
                    }
                }
                .disabled(!model.parameters.lowpassEnabled)

                IntSliderRow(
                    title: "Corner frequency",
                    value: corner,
                    range: RC8650Chip.lowpassRange,
                    caption: "500 to 4800 Hz. The chip puts nothing above its own 5008 Hz Nyquist frequency, so the top of this range is barely distinguishable from switching the filter off — which is what the switch above is for.",
                    display: { "\($0) Hz" })
                    .disabled(!model.parameters.lowpassEnabled)

                LabeledContent("In effect") {
                    Text(model.parameters.lowpassHz == 0
                         ? "off — unfiltered D/A"
                         : "\(model.parameters.lowpassHz) Hz low-pass")
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("Sample rate")
                    .font(.headline)
                Text("""
                     The D/A runs at \(Int(RC8650Chip.sampleRate)) Hz — the 7.3728 MHz crystal \
                     divided by 8 (timer B2's f8 source) and by the timer's reload of 92. \
                     Both this app and the speech extension take the chip's bare samples \
                     and interpolate them up to the output rate, then run the filter above. \
                     They use the same code at the same rate, so Speak and Speak Through \
                     macOS are the same signal.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("""
                     The interpolation is a windowed sinc, matched against what \
                     `rc8650say` sounds like played through afplay — which is the same \
                     bare D/A samples reconstructed by the system's own converter. A \
                     smoothing interpolator would take nearly 40% out of the 3 to 4.2 kHz \
                     band, which is exactly the band this filter is here to control, and \
                     the switch above would barely do anything.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}
