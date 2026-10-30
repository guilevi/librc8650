import SwiftUI

/// The eight voice parameters the chip reloads whenever a voice is selected,
/// plus the speech rate.
///
/// Every setting here is per voice, because that is how the chip works:
/// sending nO reloads formant, pitch, tone, expression, articulation, reverb
/// and word delay from that voice's firmware preset, so "the pitch" is not one
/// number carried across voices.  A parameter left at its preset is not sent at
/// all, which lets the firmware preset show through exactly rather than being
/// re-flattened to a global default.
struct VoiceTab: View {

    @Bindable var model: AppModel

    private var preset: RC8650Chip.Preset {
        RC8650Chip.voice(id: model.parameters.voice).preset
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                IntSliderRow(
                    title: "Rate",
                    value: $model.parameters.rateRung,
                    range: 0...(RC8650Chip.rateLadder.count - 1),
                    caption: rateCaption,
                    display: { rung in
                        "\(RC8650Chip.rateWPM[min(rung, RC8650Chip.rateWPM.count - 1)]) wpm"
                    })

                IntSliderRow(
                    title: "Pitch",
                    value: $model.parameters.pitch,
                    range: RC8650Chip.pitchRange,
                    caption: "nP 0-99. This voice's preset is \(preset.pitch).")

                IntSliderRow(
                    title: "Volume",
                    value: $model.parameters.volume,
                    range: RC8650Chip.volumeRange,
                    caption: "nV 0-9. Not reloaded by a voice change; always sent.")

                IntSliderRow(
                    title: "Expression",
                    value: $model.parameters.expression,
                    range: RC8650Chip.expressionRange,
                    caption: "nE 0-9: 0 is a monotone, 9 very animated. Preset \(preset.expression).")

                IntSliderRow(
                    title: "Articulation",
                    value: $model.parameters.articulation,
                    range: RC8650Chip.articulationRange,
                    caption: "nA 0-9. Low values slur the voice, high values make it choppy. Preset \(preset.articulation).")

                IntSliderRow(
                    title: "Formant frequency",
                    value: $model.parameters.formant,
                    range: RC8650Chip.formantRange,
                    caption: "nF 0-9: the vocal-tract formant frequencies. Retunes the voice type rather than its speed. Preset \(preset.formant).")

                IntSliderRow(
                    title: "Reverb",
                    value: $model.parameters.reverb,
                    range: RC8650Chip.reverbRange,
                    caption: "nR 0-9: 0 is dry, higher values lengthen the reverb. Preset \(preset.reverb).")

                ChoiceRow(
                    title: "Tone",
                    value: $model.parameters.tone,
                    options: RC8650Chip.tones,
                    caption: "nX. The datasheet likens it to a stereo's bass and treble controls. Preset \(RC8650Chip.tones[preset.tone].name).")

                Divider()

                Picker("Speech mode", selection: $model.parameters.mode) {
                    ForEach(RC8650Chip.SpeechMode.allCases, id: \.self) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                if model.parameters.mode == .text {
                    IntSliderRow(
                        title: "Word delay",
                        value: $model.parameters.wordDelay,
                        range: RC8650Chip.delayRange,
                        caption: "nT 0-15: extra pause between words. The datasheet offers it as an intelligibility aid for listeners new to synthetic speech. Preset \(preset.wordDelay).")
                } else {
                    IntSliderRow(
                        title: "Character delay",
                        value: $model.parameters.charDelay,
                        range: RC8650Chip.delayRange,
                        caption: "nC 0-15: pause between spelled characters.")
                }

                HStack {
                    Button("Reset This Voice to Its Firmware Preset") { model.resetToPreset() }
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
    }

    private var rateCaption: String {
        let rung = RC8650Chip.rateLadder[min(model.parameters.rateRung, RC8650Chip.rateLadder.count - 1)]
        let scale = (rung.por & RC8650Chip.POR.v86Rate) != 0 ? "RC8650 scale" : "V8600 scale"
        return "Rung \(model.parameters.rateRung) of 19 — \(scale), nS \(rung.speed). "
             + "The chip has two ten-step rate scales that overlap; this ladder is their union, sorted by measured utterance length."
    }
}
