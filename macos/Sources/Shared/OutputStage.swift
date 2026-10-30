// From the chip's 10017 Hz to whatever the host asked for, plus the modeled
// reconstruction filter.
//
// The reference for how this should sound is `rc8650say -o out.wav` played with
// afplay: librc8650's bare 8-bit D/A path written at 10017 Hz and reconstructed
// by the system's own converter, which is bandlimited.  So this is bandlimited
// too — a windowed-sinc interpolator — and the whole job is to match that
// reference and add nothing of its own.
//
// Two wrong answers were tried first, and the measurements are worth keeping
// because they say what each one costs.  Band energy over one utterance, as a
// share of the total:
//
//                                0-1k   1-3k  3-4.2k  4.2-5k  5-8k  8-14k 14-24k
//   REFERENCE unfiltered @10017  88.66%  9.38%  1.94%  0.02%  0.00%  0.00%  0.00%
//     Catmull-Rom to 48k         90.97%  7.71%  1.20%  0.02%  0.07%  0.02%  0.01%
//     sample-and-hold to 48k     90.11%  7.23%  1.16%  0.03%  0.47%  0.61%  0.38%
//     windowed sinc to 48k       90.31%  7.91%  1.72%  0.02%  0.02%  0.01%  0.01%
//
// Catmull-Rom is a smoothing interpolator: it took nearly 40% out of the
// 3-4.2 kHz band, which is exactly the band the reconstruction filter is there
// to control, so switching the filter on and off barely changed what you heard.
//
// A zero-order hold is what the D/A pin really does, and modelling it faithfully
// was tempting — it puts the converter's imaging back, which is a real part of
// what unfiltered hardware sounds like.  But it is not what the reference sounds
// like, and it is not free either: the hold's own sinc rolloff took the same 40%
// out of 3-4.2 kHz while adding 1.5% of energy above 5 kHz that afplay would
// never have produced.
//
// Getting the kernel long enough took a second pass — see `taps`.  Where it
// ended up, against the same utterance through rc8650say, normalised on the
// 0-3 kHz band and with the analysis bandwidth matched at both rates:
//
//                          300   1000   2000   3000   4000   5008   6000   8000
//   rc8650say @10017      -2.8   -4.1  -13.1  -14.1  -17.3  -36.5      .      .
//   this, 16 taps @48000  -2.9   -4.0  -12.7  -14.3  -17.0  -37.6  -55.2  -99.9
//   this, 96 taps @48000  -2.9   -4.0  -12.7  -14.3  -17.0  -37.6      .      .
//
// Every band the chip actually occupies agrees within 0.4 dB.  The only thing
// that ever differed was that -55 dB in 5-6 kHz, which is imaging, and which is
// now gone.  (Matching the analysis bandwidth matters: with a fixed frame length
// at both rates, the difference in resolution alone fakes a 2 dB tilt across the
// consonant bands, which is a good way to spend an afternoon chasing nothing.)

import Foundation

public struct OutputStage {

    public let inputRate: Double
    public let outputRate: Double

    /// Half-width of the interpolation kernel, in input samples.
    ///
    /// Long enough that the kernel reaches its stopband before the first image.
    /// A resampler's anti-imaging filter has to get from passband to stopband
    /// between the highest frequency worth keeping and the bottom of the first
    /// image — here, between about 4.6 kHz and 5009 Hz — and how narrow that
    /// transition can be is set by the kernel's length.
    ///
    /// The first version used 16 taps at a 0.49 cutoff, which is far too short
    /// for a transition that narrow.  Measured by sweeping single tones through
    /// it: a 4600 Hz tone came through 1.37 dB down with its image only **29 dB**
    /// below it, landing at 5417 Hz.  The reference has nothing at all above
    /// 5008 Hz, because 10017 Hz material cannot — so that image sat in a band
    /// that is otherwise perfectly empty, which is exactly where added hiss gets
    /// noticed.  It measured -55 dB in the real output, and it was the only
    /// difference between the two paths that measurement could find.
    ///
    /// 96 taps at 0.475 is flat to 0.00 dB right up to 4600 Hz — a *wider*
    /// passband than the short kernel managed, which rolled off from 4200 — with
    /// the image 48 dB down instead of 29.
    private static let taps = 96

    /// Where the kernel rolls off, as a fraction of the input sample rate.
    private static let cutoff = 0.475

    /// Fractional positions the kernel is precomputed at.
    ///
    /// Quantising the phase to the nearest row is timing jitter, and jitter is
    /// broadband noise: 512 rows on their own put a flat floor at about -77 dB
    /// across the whole spectrum, which is a poor trade for the 28 dB of imaging
    /// the longer kernel just removed.  So the two rows either side are blended
    /// instead, which costs one extra multiply-add per tap and takes the floor
    /// back below -100 dB where it was when the kernel was evaluated exactly.
    ///
    /// The table is `phases + 1` rows so the blend can always read `row + 1`.
    private static let phases = 512

    /// `kernelTable[phase * 2 * taps + tap]`, each row normalised to unity gain
    /// so the passband stays flat as the phase walks across the kernel.
    private static let kernelTable: [Float] = {
        var table = [Float](repeating: 0, count: (phases + 1) * 2 * taps)
        let half = Double(taps)
        for phase in 0...phases {
            let frac = Double(phase) / Double(phases)
            var row = [Double](repeating: 0, count: 2 * taps)
            var sum = 0.0
            for i in 0..<(2 * taps) {
                let k = Double(i - taps + 1)
                let t = k - frac
                guard abs(t) < half else { continue }
                let x = 2 * cutoff * t
                let sinc = abs(x) < 1e-12 ? 1 : sin(.pi * x) / (.pi * x)
                let w = (t + half) / (2 * half)
                let window = 0.42 - 0.5 * cos(2 * .pi * w) + 0.08 * cos(4 * .pi * w)
                row[i] = sinc * window
                sum += row[i]
            }
            let scale = sum.magnitude > 1e-12 ? 1 / sum : 0
            for i in 0..<(2 * taps) {
                table[phase * 2 * taps + i] = Float(row[i] * scale)
            }
        }
        return table
    }()

    /// Input samples consumed per output sample.
    private let step: Double
    /// Where the next output sample falls, in input samples into `history`.
    private var position: Double
    /// Input history, with `taps` samples of run-up in front of `position`.
    private var history: [Float]
    private var filter: Biquad?

    /// `cornerHz` of nil, or zero, leaves the reconstruction filter out.
    public init(inputRate: Double = RC8650Chip.sampleRate,
                outputRate: Double,
                cornerHz: Int?) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        step = inputRate / outputRate
        history = [Float](repeating: 0, count: Self.taps)
        position = Double(Self.taps)
        if let cornerHz, cornerHz > 0 {
            let corner = min(Double(cornerHz), outputRate * 0.45)
            filter = Biquad(lowpassAt: corner, rate: outputRate)
        }
    }

    public mutating func process(_ input: UnsafeBufferPointer<Int16>, emit: (Float) -> Void) {
        guard !input.isEmpty else { return }
        history.reserveCapacity(history.count + input.count)
        for sample in input { history.append(Float(sample) / 32768) }

        let taps = Self.taps
        let width = 2 * taps
        let limit = Double(history.count - taps)

        history.withUnsafeBufferPointer { buf in
            Self.kernelTable.withUnsafeBufferPointer { table in
                while position < limit {
                    let center = Int(position)
                    let frac = position - Double(center)
                    let scaled = frac * Double(Self.phases)
                    let row = min(Self.phases - 1, Int(scaled))
                    let blend = Float(scaled - Double(row))
                    let k0 = table.baseAddress! + row * width
                    let k1 = k0 + width
                    let x = buf.baseAddress! + (center - taps + 1)
                    var acc: Float = 0
                    for i in 0..<width {
                        acc += x[i] * (k0[i] + blend * (k1[i] - k0[i]))
                    }
                    emit(filter?.process(acc) ?? acc)
                    position += step
                }
            }
        }

        // Drop the history that is now behind the kernel's run-up.
        let consumed = Int(position) - taps
        if consumed > 0 {
            history.removeFirst(consumed)
            position -= Double(consumed)
        }
    }

    /// Run the tail of the utterance out, so its last samples are not left
    /// inside the kernel or the filter's delay line.
    public mutating func flush(emit: (Float) -> Void) {
        let pad = [Int16](repeating: 0, count: Self.taps + 1)
        pad.withUnsafeBufferPointer { process($0, emit: emit) }
    }
}

/// A direct-form-I biquad, designed the way Robert Bristow-Johnson's cookbook
/// does it.  Butterworth Q, which is the flattest passband a second order has
/// and close enough to what a two-pole filter and an op-amp would do.
struct Biquad {
    private let b0, b1, b2, a1, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(lowpassAt corner: Double, rate: Double) {
        let w = 2 * Double.pi * corner / rate
        let alpha = sin(w) / (2 * (1 / 2.0.squareRoot()))
        let cosw = cos(w)
        let a0 = 1 + alpha
        b0 = Float((1 - cosw) / 2 / a0)
        b1 = Float((1 - cosw) / a0)
        b2 = b0
        a1 = Float(-2 * cosw / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}
