// The RC8650's own settings, and how they are turned into its command stream.
//
// Everything here is the chip's, not this app's: the ranges, the defaults and
// the per-voice presets are what the firmware itself reports through the
// Interrogate command (12?, datasheet Table 19).  The command letters and the
// value each one clamps to were established the same way, by sending
// <CTRL+A>n<letter> to the emulated firmware and diffing the 23-byte
// interrogation before and after, so nothing in this file is inferred from
// prose.
//
// Command format (datasheet, "The Command Character"): every command is
// <CTRL+A><number string><command character>, and the chip executes nothing
// and speaks nothing until a CR or a NUL arrives.

import Foundation

public enum RC8650Chip {

    /// D/A sample rate: 7.3728 MHz crystal / 8 (timer B2's f8 source) / 92.
    public static let sampleRate: Double = 10017

    public static let ctrlA = "\u{01}"

    // MARK: - Voices (nO)

    public struct Voice: Identifiable, Hashable, Sendable {
        public let id: Int          // the nO argument
        public let name: String     // datasheet Table 7, or the RC8660's
        public let chipName: String // "RC8650", "RC8660"
        public let preset: Preset

        public init(id: Int, name: String, chipName: String = "RC8650", preset: Preset) {
            self.id = id
            self.name = name
            self.chipName = chipName
            self.preset = preset
        }

        /// What the voice is called to the rest of macOS.
        public var systemName: String { "\(chipName) \(name)" }
        /// Not chip-specific, on purpose: a voice the user picked in System
        /// Settings stays picked when the firmware is switched underneath it.
        public var identifier: String { "com.guilevi.rc8650.voice.\(id)" }
    }

    /// The seven settings that selecting a voice reloads from firmware, in the
    /// chip's own units.  Read back out of the emulated chip with 12? after
    /// each nO, not guessed: this is what gives each voice its character.
    public struct Preset: Hashable, Sendable {
        public let pitch: Int        // 0...99
        public let articulation: Int // 0...9
        public let formant: Int      // 0...9
        public let tone: Int         // 0...2
        public let expression: Int   // 0...9
        public let reverb: Int       // 0...9
        public let wordDelay: Int    // 0...15
    }

    /// The voices of the firmware the engine is running: eight on the RC8650,
    /// eleven on the RC8660.  See `ChipProfile`.
    public static var voices: [Voice] { profile.voices }

    public static func voice(id: Int) -> Voice {
        let all = voices
        return all[max(0, min(all.count - 1, id))]
    }

    // MARK: - The rate ladder

    /// (Protocol Options Register value, nS speed), slowest to fastest.
    ///
    /// The chip has two speech-rate scales, selected by POR bit 7 (V86).  With
    /// V86 set — the power-on default — nS 0-9 runs about 173 to 395 wpm; with
    /// it clear the chip emulates RC Systems' earlier V8600 module and the same
    /// nS 0-9 runs about 116 to 242 wpm.  The two overlap, so this table is the
    /// union of both sorted by measured utterance length: one monotonic
    /// twenty-step scale covering 116-395 wpm, both slower and finer than
    /// either alone.
    ///
    /// Interleaving them is safe because V86 changes nothing else used here:
    /// interrogating all eight voices under 0G and under 128G returns identical
    /// presets.
    /// Re-measured 2026-08-01, after the librc8650 end-of-utterance fix. The two
    /// scales interleave slightly differently than the original timings said:
    /// (0,5) is marginally slower than (128,0), and (0,7) than (128,1). Those
    /// two pairs are swapped from the order this table used to have — the old
    /// measurements were taken through the truncation bug, which occasionally
    /// timed a fragment rather than an utterance.
    ///
    /// That is the RC8650's ladder.  The firmware's own comes from
    /// `ChipProfile`: the RC8660's is its own scale alone, 0S-13S, because
    /// clearing V86 there switches it into V8600 compatibility, which also
    /// narrows the formant setting to 0-9.
    public static var rateLadder: [(por: Int, speed: Int)] { profile.rateLadder }

    /// Length of one fixed sentence at each rung, in samples at 10017 Hz.
    /// Measured, three consecutive utterances per rung, all three identical.
    /// This is what the rate ladder is sorted by and what scales it: a caller
    /// asking for "150% of normal" is asking for a rung whose duration is two
    /// thirds of the current one, which is a ratio these numbers can answer and
    /// a words-per-minute label cannot.
    public static var rateDuration: [Int] { profile.rateDuration }

    /// Words per minute, derived from those durations against the chip's
    /// power-on rate of about 199 wpm. Labelling only.
    /// Approximate for any chip but the RC8650 the 199 wpm was measured on.
    public static var rateWPM: [Int] {
        let durations = rateDuration
        let base = durations.indices.contains(defaultRateRung) ? durations[defaultRateRung] : 0
        return durations.map { $0 > 0 && base > 0
            ? Int((199.0 * Double(base) / Double($0)).rounded()) : 0 }
    }

    /// The rung holding the chip's own power-on rate: (128, 1) on most RC8650
    /// models, (0, 5) on models 2 and 8, 5S on the RC8660.
    public static var defaultRateRung: Int { profile.defaultRateRung }

    /// The rung closest to `scale` times the speed of `rung` — the mapping an
    /// SSML `<prosody rate="150%">` needs. Speed is the reciprocal of duration.
    public static func rateRung(scaling rung: Int, by scale: Double) -> Int {
        guard scale > 0, scale != 1 else { return rung }
        let rateDuration = self.rateDuration
        let base = rung.clamped(to: 0...(rateDuration.count - 1))
        // A ladder without measured lengths: scale the position instead.
        guard rateDuration[base] > 0 else {
            return (Int((Double(base + 1) * scale).rounded()) - 1)
                .clamped(to: 0...(rateDuration.count - 1))
        }
        let want = Double(rateDuration[base]) / scale
        var best = base
        var bestError = Double.greatestFiniteMagnitude
        for (index, duration) in rateDuration.enumerated() {
            let error = abs(Double(duration) - want)
            if error < bestError { bestError = error; best = index }
        }
        return best
    }

    // MARK: - Registers

    /// Protocol Options Register (nG).  Bit 4 is not settable — 255G reads
    /// back as 239 — so the writable mask is 0xEF.
    public enum POR {
        public static let statusMessages = 0x01   // STM: one byte on output start, one on stop
        public static let v86Rate        = 0x80   // V86: select the faster of the two rate scales
        public static let writableMask   = 0xEF
    }

    /// Punctuation Filter Register (nB, datasheet Table 8).
    public enum PFR {
        public static let filterMask     = 0x03   // 0 all, 1 most, 2 some, 3 none
        public static let numbersAsNumbers = 0x04
        public static let speakLeadingZeros = 0x08 // LZS=1 means do NOT suppress
        public static let notYears       = 0x10   // YM=0 means read 4-digit numbers as years
    }

    public static let punctuationModes: [(value: Int, name: String)] = [
        (0, "All"),
        (1, "Most (all but CR, LF, space)"),
        (2, #"Some ($%&#@=+*^|\<>)"#),
        (3, "None"),
    ]

    public static let tones: [(value: Int, name: String)] = [
        (0, "Bass"), (1, "Normal"), (2, "Treble"),
    ]

    /// nK, TS Pin Control (Table 16).  Does not affect audio — TS0 is the
    /// chip's talk-status output pin — but it is a chip setting, so it is here.
    public static let tsPinModes: [(value: Int, name: String)] = [
        (0, "Automatic, active high"),
        (1, "Automatic, active low (default)"),
        (2, "Forced low"),
        (3, "Forced high"),
    ]

    /// Speech mode.  nT selects text mode and carries the inter-word delay; nC
    /// selects character (spelling) mode and carries the inter-character delay.
    /// Both are 0...15 and both are reported in the Mode field of 12?.
    public enum SpeechMode: Int, Codable, CaseIterable, Sendable {
        case character = 0
        case text = 2
        public var name: String { self == .text ? "Text" : "Character (spell)" }
        public var letter: String { self == .text ? "T" : "C" }
    }

    // MARK: - Ranges

    public static let pitchRange        = 0...99   // nP, mod 100
    public static var speedRange: ClosedRange<Int> { profile.speedRange }    // nS: 0-9, RC8660 0-13
    public static let volumeRange       = 0...9    // nV
    public static let expressionRange   = 0...9    // nE
    public static let articulationRange = 0...9    // nA
    public static var formantRange: ClosedRange<Int> { profile.formantRange }  // nF: 0-9, RC8660 0-99
    public static let reverbRange       = 0...9    // nR
    public static let toneRange         = 0...2    // nX
    public static let delayRange        = 0...15   // nT / nC, 16 is rejected
    public static let sleepRange        = 0...31   // nQ, 255Q reads back 31
    public static let timeoutRange      = 0...15   // nY, 255Y reads back 15
    public static let acrRange          = 0...255  // nN, full byte
    public static let porRange          = 0...255  // nG, masked to 0xEF
    public static let pfrRange          = 0...31   // nB

    /// Reconstruction low-pass corner of the modeled output stage.  Not a chip
    /// command: AO0/AO1 are unfiltered D/A pins and the datasheet calls an
    /// external low-pass "highly recommended", its own reference circuit
    /// (Figure 7) being a 3 kHz filter/amplifier.  0 is the bare staircase.
    public static let lowpassPresets: [(hz: Int, name: String)] = [
        (1500, "Telephone — 1.5 kHz"),
        (2000, "Muffled — 2 kHz"),
        (2500, "Warm — 2.5 kHz"),
        (3000, "Datasheet — 3 kHz"),
        (3800, "Bright — 3.8 kHz"),
        (4800, "Widest — 4.8 kHz"),
    ]

    /// The corner frequencies the modeled output stage will design a filter for.
    ///
    /// The ceiling is 4800 because the chip has nothing above its own 5008 Hz
    /// Nyquist frequency: a corner up there is indistinguishable from switching
    /// the filter off, which is what the switch is for.
    ///
    /// 0, meaning off, is deliberately outside this range and held separately,
    /// so a slider cannot land between the two and show a number that is not
    /// what the filter is using.
    public static let lowpassRange = 500...4800
    public static let lowpassOff = 0
    public static let lowpassDefault = 3000

    // MARK: - Building the command stream

    /// The command prefix for one utterance, given a full set of parameters.
    ///
    /// Ordering matters twice over:
    ///
    /// * The Protocol Options Register goes FIRST.  In the other order this
    ///   firmware emits a ~23 ms burst at 5% of full scale — an audible blip —
    ///   before it settles and speaks.  Putting nG first is safe: the
    ///   datasheet's "voice before parameters" rule is about the parameters nO
    ///   reloads, and interrogating after an nO shows POR untouched.
    ///
    /// * The voice (nO) goes before the parameter commands, because selecting
    ///   one reloads formant, pitch, tone, expression, articulation, reverb and
    ///   word delay from that voice's firmware preset.  Anything sent before it
    ///   would be clobbered.  nS still lands after both, which is what matters,
    ///   since POR selects the speed scale nS indexes into.
    ///
    /// The seven preset-backed settings are emitted only when they differ from
    /// the selected voice's preset: nO has already loaded the preset, so
    /// omitting them lets it show through exactly rather than being re-flattened
    /// to some global default.  Speed, volume and the registers are emitted
    /// unconditionally, because nO does not reload them — the chip keeps
    /// whatever it was last given, so omitting one would mean "leave it wherever
    /// it happens to be" rather than "set it to the default".
    public static func commandPrefix(_ p: Parameters) -> String {
        let voice = RC8650Chip.voice(id: p.voice)
        let preset = voice.preset
        let rung = rateLadder[max(0, min(rateLadder.count - 1, p.rateRung))]

        var out: [String] = []
        func cmd(_ n: Int, _ letter: String) { out.append("\(ctrlA)\(n)\(letter)") }

        // POR: the caller's own bits, plus the rate scale this rung needs, plus
        // STM. STM makes the chip transmit one byte when its output starts and
        // another when it stops, which is what librc8650 ends an utterance on.
        // Re-timing every rung of the ladder with the bit set changed 19 of the
        // 20 by not one sample and the twentieth by two out of 53875.
        var por = (p.por & POR.writableMask) & ~POR.v86Rate
        por |= rung.por & POR.v86Rate
        por |= POR.statusMessages
        cmd(por, "G")

        cmd(p.voice, "O")
        cmd(rung.speed, "S")
        cmd(p.volume, "V")
        cmd(p.pfr, "B")
        cmd(p.acr, "N")
        cmd(p.tsPin, "K")
        cmd(p.sleep, "Q")
        cmd(p.timeout, "Y")

        if p.pitch != preset.pitch { cmd(p.pitch, "P") }
        if p.tone != preset.tone { cmd(p.tone, "X") }
        if p.articulation != preset.articulation { cmd(p.articulation, "A") }
        if p.expression != preset.expression { cmd(p.expression, "E") }
        if p.formant != preset.formant { cmd(p.formant, "F") }
        if p.reverb != preset.reverb { cmd(p.reverb, "R") }

        // Mode last: nT/nC both set the mode AND the delay that goes with it,
        // and the mode is what the text after this prefix is read in.
        switch p.mode {
        case .text:      cmd(p.wordDelay, "T")
        case .character: cmd(p.charDelay, "C")
        }
        return out.joined()
    }

    /// The parameters a span asks for: the user's settings for the voice, moved
    /// by whatever prosody the request put around that run of text.
    public static func parameters(_ base: Parameters, scaledBy span: SpeechSpan) -> Parameters {
        var p = base
        if span.rateScale != 1 {
            p.rateRung = rateRung(scaling: base.rateRung, by: span.rateScale)
        }
        if span.pitchScale != 1 {
            p.pitch = Int((Double(base.pitch) * span.pitchScale).rounded())
                .clamped(to: pitchRange)
        }
        if span.volumeScale != 1 {
            p.volume = Int((Double(base.volume) * span.volumeScale).rounded())
                .clamped(to: volumeRange)
        }
        if span.spellOut { p.mode = .character }
        return p
    }

    /// What to send to move the chip from one span's settings to the next,
    /// inside a single utterance.  Only the four things a span can change, and
    /// only when they have: re-sending the whole prefix mid-utterance would
    /// reload the voice preset and undo the user's own settings.
    public static func commandDelta(from previous: Parameters, to next: Parameters) -> String {
        var out: [String] = []
        func cmd(_ n: Int, _ letter: String) { out.append("\(ctrlA)\(n)\(letter)") }

        if next.rateRung != previous.rateRung {
            let rung = rateLadder[next.rateRung.clamped(to: 0...(rateLadder.count - 1))]
            var por = (next.por & POR.writableMask) & ~POR.v86Rate
            por |= rung.por & POR.v86Rate
            por |= POR.statusMessages
            cmd(por, "G")
            cmd(rung.speed, "S")
        }
        if next.pitch != previous.pitch { cmd(next.pitch, "P") }
        if next.volume != previous.volume { cmd(next.volume, "V") }
        if next.mode != previous.mode {
            switch next.mode {
            case .text:      cmd(next.wordDelay, "T")
            case .character: cmd(next.charDelay, "C")
            }
        }
        return out.joined()
    }

    /// Text the chip can be handed safely.  The firmware reads control bytes as
    /// commands, so a stray CTRL+A, CR or CTRL+X inside the text would be
    /// executed rather than spoken; anything outside printable ASCII becomes a
    /// space.
    public static func sanitize(_ text: String) -> String {
        String(text.unicodeScalars.map { s -> Character in
            (s.value >= 0x20 && s.value <= 0x7e) ? Character(s) : " "
        })
    }

    /// The chip's input buffer is 2 KB and librc8650's queue drops what does
    /// not fit rather than blocking, so long text is split into several
    /// utterances.  Splits fall on a space where possible, so a word is never
    /// cut in half; the cost is a sentence boundary's worth of prosody at the
    /// seam.
    public static let maxUtteranceBytes = 1900

    public static func split(_ text: String) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.utf8.count > maxUtteranceBytes {
            let hardEnd = rest.index(rest.startIndex, offsetBy: maxUtteranceBytes)
            let softStart = rest.index(rest.startIndex, offsetBy: maxUtteranceBytes / 2)
            let cut = rest[softStart..<hardEnd].lastIndex(of: " ") ?? hardEnd
            pieces.append(String(rest[..<cut]))
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }

    // MARK: - Interrogate (12?)

    /// The 23 fields of the Interrogate reply, in order, decoded 23-for-23
    /// against datasheet Table 19.
    public static let interrogateFields23: [String] = [
        "Mode", "Punctuation filter (PFR)", "Formant", "Pitch", "Speed",
        "Volume", "Tone", "Expression", "Dictionary loaded", "Dictionary status",
        "Input buffer", "Articulation", "Reverb", "TS pin", "Protocol options (POR)",
        "Audio control (ACR)", "Recording memory", "Sleep", "Timeout",
        "Character delay", "Text delay", "Voice", "ADR",
    ]

    /// The RC8660 adds four (its Table 21): free recording memory and the
    /// number of files, each 16 bits.
    public static var interrogateFields: [String] {
        profile.interrogateLength >= 27
            ? interrogateFields23 + ["Free recording memory (high)", "Free recording memory (low)",
                                     "Files (high)", "Files (low)"]
            : interrogateFields23
    }
}

/// One complete set of chip parameters — everything the firmware will let a
/// host set, in the chip's own units.
public struct Parameters: Codable, Hashable, Sendable {
    public var voice: Int = 0
    public var rateRung: Int = RC8650Chip.defaultRateRung
    public var pitch: Int = 50
    public var volume: Int = 5
    public var expression: Int = 5
    public var articulation: Int = 5
    public var formant: Int = 5
    public var tone: Int = 1
    public var reverb: Int = 0
    public var wordDelay: Int = 0
    public var charDelay: Int = 0
    public var mode: RC8650Chip.SpeechMode = .text

    // Punctuation Filter Register, as its four independent fields.
    public var punctuation: Int = 2      // "Some" — what suits a screen reader
    public var numbersAsNumbers: Bool = true
    public var speakLeadingZeros: Bool = true   // "007" is content, not "seven"
    public var readYears: Bool = true

    // Registers and the odds and ends.
    public var por: Int = RC8650Chip.POR.v86Rate
    public var acr: Int = 0
    public var tsPin: Int = 1
    public var sleep: Int = 0
    public var timeout: Int = 0

    /// Whether the modeled output stage's reconstruction filter is in circuit
    /// at all.  Off gives the bare D/A: the 10 kHz sample-and-hold staircase the
    /// AO pins themselves put out, imaging hiss and all.
    public var lowpassEnabled: Bool = true

    /// Its corner frequency in Hz, kept even while the filter is switched off so
    /// that turning it back on restores the setting rather than a default.
    public var lowpassCornerHz: Int = RC8650Chip.lowpassDefault

    /// What the library is actually given.
    public var lowpassHz: Int {
        lowpassEnabled ? lowpassCornerHz.clamped(to: RC8650Chip.lowpassRange) : RC8650Chip.lowpassOff
    }

    public init() {}

    /// Decoded field by field with the defaults above as fallbacks, so a
    /// settings file written by a build with a different set of parameters
    /// still loads.  The alternative — synthesized Decodable, which requires
    /// every key — means one added setting stops the extension speaking at all
    /// until the file is deleted, and the extension has no way to say so.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Parameters()
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        voice = get(.voice, d.voice)
        rateRung = get(.rateRung, d.rateRung)
        pitch = get(.pitch, d.pitch)
        volume = get(.volume, d.volume)
        expression = get(.expression, d.expression)
        articulation = get(.articulation, d.articulation)
        formant = get(.formant, d.formant)
        tone = get(.tone, d.tone)
        reverb = get(.reverb, d.reverb)
        wordDelay = get(.wordDelay, d.wordDelay)
        charDelay = get(.charDelay, d.charDelay)
        mode = get(.mode, d.mode)
        punctuation = get(.punctuation, d.punctuation)
        numbersAsNumbers = get(.numbersAsNumbers, d.numbersAsNumbers)
        speakLeadingZeros = get(.speakLeadingZeros, d.speakLeadingZeros)
        readYears = get(.readYears, d.readYears)
        por = get(.por, d.por)
        acr = get(.acr, d.acr)
        tsPin = get(.tsPin, d.tsPin)
        sleep = get(.sleep, d.sleep)
        timeout = get(.timeout, d.timeout)
        lowpassEnabled = get(.lowpassEnabled, d.lowpassEnabled)
        lowpassCornerHz = get(.lowpassCornerHz, d.lowpassCornerHz)
    }

    /// The assembled Punctuation Filter Register.  Note the two inversions the
    /// datasheet defines: LZS = 1 means do *not* suppress leading zeroes, and
    /// YM = 0 means read four-digit numbers as years.
    public var pfr: Int {
        (punctuation & RC8650Chip.PFR.filterMask)
            | (numbersAsNumbers ? RC8650Chip.PFR.numbersAsNumbers : 0)
            | (speakLeadingZeros ? RC8650Chip.PFR.speakLeadingZeros : 0)
            | (readYears ? 0 : RC8650Chip.PFR.notYears)
    }

    /// Snap the seven preset-backed settings to a voice's firmware preset, the
    /// way the chip itself does when it is sent nO.
    public mutating func applyPreset(of voiceID: Int) {
        let preset = RC8650Chip.voice(id: voiceID).preset
        voice = voiceID
        pitch = preset.pitch
        articulation = preset.articulation
        formant = preset.formant
        tone = preset.tone
        expression = preset.expression
        reverb = preset.reverb
        wordDelay = preset.wordDelay
    }

    public static func preset(for voiceID: Int) -> Parameters {
        var p = Parameters()
        p.applyPreset(of: voiceID)
        return p
    }

    public var commandPrefix: String { RC8650Chip.commandPrefix(self) }
}

extension Comparable {
    /// Pull a value into range rather than trusting it.  Settings arrive from a
    /// file on disk and from whatever an app puts in an AVSpeechUtterance, and a
    /// value outside the chip's range would become a malformed command.
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
