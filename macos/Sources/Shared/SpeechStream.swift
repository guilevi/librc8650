// One utterance, rendered on a background thread and read from a render block.
//
// Synthesis is faster than real time — roughly 2 to 4x on an M-series Mac, with
// the first sample out in 10 to 25 ms — but it is not free and it is nowhere
// near real-time safe: it runs an emulated CPU, it takes a lock, and it
// allocates.  So it happens on its own thread and reaches the audio unit
// through a ring buffer, which is the only part the render block touches.

import Foundation
import os

public final class SpeechStream: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.guilevi.rc8650", category: "stream")

    /// How much rendered audio may run ahead of playback.  Generous on purpose:
    /// while the producer is blocked on a full ring it is holding the engine
    /// lock, and a second audio unit instance wanting to speak is waiting on
    /// that lock.  Twenty seconds means only genuinely long utterances ever
    /// make anyone wait.
    public static let bufferSeconds: Double = 20

    public let outputSampleRate: Double
    private let ring: AudioRing
    private let cancelFlag = AtomicFlag()
    private let producerDone = AtomicFlag()
    private var thread: Thread?

    /// Total frames the producer has handed to the ring, for reporting.
    public private(set) var renderedFrames: Int = 0

    public init(outputSampleRate: Double) {
        self.outputSampleRate = outputSampleRate
        ring = AudioRing(capacity: max(4096, Int(outputSampleRate * Self.bufferSeconds)))
    }

    public var isFinished: Bool { producerDone.value && ring.available == 0 }
    public var isCancelled: Bool { cancelFlag.value }
    public var framesAvailable: Int { ring.available }

    /// Kick off rendering of a parsed request.  Returns immediately; audio
    /// appears in the ring as the chip produces it.
    public func start(parameters: Parameters, items: [SpeechItem]) {
        let render = Self.renderItems(parameters: parameters, items: items)
        let lowpass = parameters.lowpassHz
        guard !render.isEmpty else {
            producerDone.value = true
            return
        }

        let thread = Thread { [weak self] in
            guard let self else { return }
            self.produce(items: render, lowpassHz: lowpass)
        }
        thread.name = "RC8650 render"
        // Above the default but below a real-time thread: this feeds audio, so
        // it should not lose to ordinary work, but it is not itself audio.
        thread.qualityOfService = .userInitiated
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    /// Turn the request's spans and pauses into what the engine renders: a
    /// command string plus text for each span, and a sample count for each
    /// pause.  The first span carries the full prefix; the rest carry only what
    /// their prosody changed, because re-sending the prefix mid-utterance would
    /// reload the voice preset and undo the user's own settings.
    static func renderItems(parameters: Parameters, items: [SpeechItem]) -> [RC8650Engine.Item] {
        var out: [RC8650Engine.Item] = []
        var previous: Parameters?

        for item in items {
            switch item {
            case .silence(let seconds):
                let samples = Int(seconds * RC8650Chip.sampleRate)
                if samples > 0 { out.append(.silence(samples: samples)) }

            case .speech(let span):
                let text = RC8650Chip.sanitize(span.text)
                guard text.contains(where: { !$0.isWhitespace }) else { continue }
                let p = RC8650Chip.parameters(parameters, scaledBy: span)
                let commands = previous.map { RC8650Chip.commandDelta(from: $0, to: p) }
                    ?? p.commandPrefix
                previous = p
                out.append(.speech(commands: commands, text: text))
            }
        }
        // Nothing but pauses is not worth waking the chip for.
        if !out.contains(where: { if case .speech = $0 { return true } else { return false } }) {
            return []
        }
        return out
    }

    private func produce(items: [RC8650Engine.Item], lowpassHz: Int) {
        // The chip's bare D/A, then the staircase, then the reconstruction
        // filter — see OutputStage for why that order matters and what the
        // previous one cost.
        var stage = OutputStage(outputRate: outputSampleRate,
                                cornerHz: lowpassHz)
        var pending = [Float]()
        pending.reserveCapacity(4096)

        func flushPending() {
            while !pending.isEmpty && !cancelFlag.value {
                let written = pending.withUnsafeBufferPointer { ring.write($0) }
                if written == pending.count {
                    renderedFrames += written
                    pending.removeAll(keepingCapacity: true)
                    return
                }
                if written > 0 {
                    renderedFrames += written
                    pending.removeFirst(written)
                }
                // Ring full: playback has not caught up. 5 ms is a fiftieth of
                // the buffer, so this costs at most a handful of wakeups even
                // on a long utterance.
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        RC8650Engine.shared.render(
            items: items,
            isCancelled: { self.cancelFlag.value },
            sink: { samples in
                stage.process(samples) { pending.append($0) }
                flushPending()
            })

        if !cancelFlag.value {
            stage.flush { pending.append($0) }
            flushPending()
        }
        producerDone.value = true
        Self.log.debug("\(self.renderedFrames) frames from \(items.count) items")
    }

    /// Stop rendering.  The producer notices between chunks and sends the chip
    /// its own Stop, which librc8650 delivers before returning rather than
    /// merely queuing — that is what makes cancel-then-speak safe.
    public func cancel() {
        cancelFlag.value = true
    }

    /// How long a render call will wait for the producer before giving up and
    /// returning silence.  Generous: the alternative to waiting is silence in
    /// the middle of a word.
    private static let renderWaitLimit: Double = 5

    /// Consumer side, called from the render block.  Fills `frames` samples and
    /// reports whether that was the end of the utterance.
    ///
    /// This waits for the producer rather than padding with silence, which
    /// looks wrong for a render block and is not.  The host pulling a speech
    /// synthesis unit is not a device callback running against a wall clock: it
    /// drains the whole utterance as fast as the unit will hand it over, and
    /// then plays what it collected.  Padding a gap with silence there does not
    /// paper over a glitch, it *inserts* silence into the recording — measured,
    /// the first version of this returned about 9.5 seconds of zeroes while a
    /// 1-second utterance was still rendering, and the host duly played all of
    /// it.  Waiting costs the same wall-clock time and produces the utterance.
    public func render(into destination: UnsafeMutablePointer<Float>, frames: Int) -> (filled: Int, complete: Bool) {
        let deadline = Date().addingTimeInterval(Self.renderWaitLimit)
        while ring.available < frames
                && !producerDone.value
                && !cancelFlag.value
                && Date() < deadline {
            usleep(200)
        }
        let got = ring.read(into: destination, count: frames)
        if got < frames {
            (destination + got).update(repeating: 0, count: frames - got)
        }
        let complete = producerDone.value && ring.available == 0
        return (got, complete)
    }
}
