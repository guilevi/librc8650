// Playing the emulator's output in this app, without going through the system.
//
// The audio unit extension is the real product; this is the bench.  It runs the
// same output stage the extension does, at the same rate, so what you hear from
// the Speak button and what you hear from Speak Through macOS are the same
// signal — which is the only way the two are worth comparing.

import AVFoundation
import Foundation

final class LocalPlayer: @unchecked Sendable {

    /// Matches the extension's output bus.  High enough that the D/A's
    /// staircase, and the imaging that goes with it, survive to the speakers
    /// rather than folding: the first image sits around 10 kHz and the second
    /// around 20 kHz, both inside 24 kHz.
    static let sampleRate: Double = 48000

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: LocalPlayer.sampleRate,
                                       channels: 1)!
    private let cancelFlag = AtomicFlag()
    private let lock = NSLock()

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Render and play, returning once the last sample has been scheduled.
    @discardableResult
    func play(parameters: Parameters, text: String) async -> AppModel.RenderReport? {
        cancelFlag.value = false
        let started = Date()

        return await withCheckedContinuation { (continuation: CheckedContinuation<AppModel.RenderReport?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock()
                defer { lock.unlock() }
                do {
                    if !engine.isRunning { try engine.start() }
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                node.play()

                var stage = OutputStage(outputRate: Self.sampleRate,
                                        cornerHz: parameters.lowpassHz,
                                        resampling: parameters.resampling)
                var frames = 0
                var pending = [Float]()
                pending.reserveCapacity(4096)

                func schedule() {
                    guard !pending.isEmpty,
                          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                        frameCapacity: AVAudioFrameCount(pending.count)),
                          let channel = buffer.floatChannelData?[0] else { return }
                    pending.withUnsafeBufferPointer {
                        channel.update(from: $0.baseAddress!, count: $0.count)
                    }
                    buffer.frameLength = AVAudioFrameCount(pending.count)
                    frames += pending.count
                    pending.removeAll(keepingCapacity: true)
                    node.scheduleBuffer(buffer, completionHandler: nil)
                }

                // The same path the extension takes, so the bench and the
                // system voice are the same signal: a plain-text bench utterance
                // is just one span with no prosody on it.
                let items = SpeechStream.renderItems(
                    parameters: parameters,
                    items: [.speech(SpeechSpan(text: text))])
                RC8650Engine.shared.render(
                    items: items,
                    isCancelled: { self.cancelFlag.value },
                    sink: { samples in
                        stage.process(samples) { pending.append($0) }
                        schedule()
                    })
                stage.flush { pending.append($0) }
                schedule()

                let report = AppModel.RenderReport(
                    frames: frames,
                    seconds: Double(frames) / Self.sampleRate,
                    wallClock: Date().timeIntervalSince(started))
                continuation.resume(returning: report)
            }
        }
    }

    func stop() {
        cancelFlag.value = true
        node.stop()
    }
}
