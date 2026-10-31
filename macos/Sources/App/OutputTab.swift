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
                Text("Resampling")
                    .font(.headline)

                Picker("Resampling", selection: $model.parameters.resampling) {
                    ForEach(RC8650Chip.Resampling.allCases, id: \.self) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                Text("""
                     Smooth interpolates between the chip's samples and keeps nothing \
                     above 5 kHz. The D/A staircase holds each sample the way the D/A \
                     pin does, keeping the mirror images that puts above 5 kHz for the \
                     filter below to soften. BookPort is one measured unit: its images \
                     sit a little higher than the standard chip's and its gentle filter \
                     leaves much of them in, while the voice keeps its usual pitch. \
                     BookPort replaces the filter settings below. To sound like that \
                     unit, also choose treble tone and a slightly faster rate.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Text("Reconstruction filter")
                    .font(.headline)

                Toggle("Filter the output", isOn: $model.parameters.lowpassEnabled)
                    .disabled(model.parameters.resampling == .bookport)
                Text("""
                     Off with the D/A staircase is the bare D/A: what the AO pins \
                     themselves put out, imaging hiss and all. With smooth resampling the \
                     images are already gone, so off is merely brighter. The corner \
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
                .disabled(!model.parameters.lowpassEnabled || model.parameters.resampling == .bookport)

                IntSliderRow(
                    title: "Corner frequency",
                    value: corner,
                    range: RC8650Chip.lowpassRange,
                    caption: "500 to 4800 Hz. The chip puts nothing above its own 5008 Hz Nyquist frequency, so the top of this range is barely distinguishable from switching the filter off — which is what the switch above is for.",
                    display: { "\($0) Hz" })
                    .disabled(!model.parameters.lowpassEnabled || model.parameters.resampling == .bookport)

                LabeledContent("In effect") {
                    Text(model.parameters.resampling == .bookport
                         ? "BookPort — \(RC8650Chip.bookportCornerHz) Hz first-order low-pass"
                         : model.parameters.lowpassHz == 0
                         ? "off"
                         : "\(model.parameters.lowpassHz) Hz low-pass")
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("Sample rate")
                    .font(.headline)
                Text("""
                     The D/A runs at about \(Int(RC8650Chip.sampleRate)) Hz, paced by the \
                     firmware's timer A3 from the 7.3728 MHz clock; the formant setting \
                     moves it. Both this app and the speech extension take the chip's \
                     bare samples and resample them to the output rate as chosen above, \
                     then run the filter. \
                     They use the same code at the same rate, so Speak and Speak Through \
                     macOS are the same signal.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("""
                     Smooth resampling is a windowed sinc, matched against what \
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
