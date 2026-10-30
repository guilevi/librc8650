// The RC8650 as a system speech synthesizer.
//
// An AVSpeechSynthesisProviderAudioUnit is how macOS lets a third party add
// voices to AVSpeechSynthesizer, and through it to every app that speaks:
// Spoken Content, Speak Selection, anything calling AVSpeechSynthesizer
// directly.  The host hands over an SSML request and pulls audio out of the
// render block until the unit says it is done.
//
// The division of labour here:
//
//   synthesizeSpeechRequest  works out the chip parameters, starts a
//                            SpeechStream, returns immediately
//   SpeechStream             runs the emulator on its own thread, resamples
//                            10017 Hz to the bus rate, fills a ring
//   internalRenderBlock      copies out of the ring; that is all it does

import AVFoundation
import AudioToolbox
import os

public final class RC8650SpeechAudioUnit: AVSpeechSynthesisProviderAudioUnit {

    private var outputBus: AUAudioUnitBus
    private var busArray: AUAudioUnitBusArray!

    /// Memory to hand back when the host passes a buffer list with null
    /// pointers.  A small class rather than a captured buffer so that the
    /// render block, which is created once, still sees the allocation
    /// allocateRenderResources makes later.
    private final class Scratch {
        private(set) var pointer: UnsafeMutablePointer<Float>?
        private(set) var capacity = 0

        func allocate(frames: Int) {
            release()
            guard frames > 0 else { return }
            pointer = .allocate(capacity: frames)
            pointer?.initialize(repeating: 0, count: frames)
            capacity = frames
        }

        func release() {
            pointer?.deallocate()
            pointer = nil
            capacity = 0
        }

        deinit { release() }
    }

    private let scratch = Scratch()

    /// The utterance being spoken, if any.  Read by the render block, replaced
    /// by the host thread; an unfair lock because the render block cannot take
    /// anything heavier and this is only ever contended at the start and end of
    /// an utterance.
    private let activeStream = OSAllocatedUnfairLock<SpeechStream?>(initialState: nil)

    private static let log = Logger(subsystem: "com.guilevi.rc8650", category: "audiounit")

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        // 48000 rather than the chip's own 10017 Hz, which is not a rate
        // anything else on the system uses — and high enough that the D/A's
        // staircase survives to the output rather than folding: with the
        // reconstruction filter switched off, the first image of the 10017 Hz
        // hold sits around 10 kHz and the second around 20 kHz, and both fit
        // under 24 kHz.  At 22050 the second one would fold back into the
        // audible band as something the hardware never produced.
        //
        // SpeechStream works at whatever this bus ends up running at, so a host
        // that reconfigures it is still fine; it just has less room.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 1
        try super.init(componentDescription: componentDescription, options: options)
        busArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    public override var outputBusses: AUAudioUnitBusArray { busArray }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        scratch.allocate(frames: Int(maximumFramesToRender))
    }

    public override func deallocateRenderResources() {
        activeStream.withLock { stream in
            stream?.cancel()
            stream = nil
        }
        scratch.release()
        super.deallocateRenderResources()
    }

    // MARK: - Voices

    /// The chosen firmware's voices: eight on the RC8650, eleven on the
    /// RC8660.  Booting first is what makes them that firmware's rather than
    /// the built-in RC8650 stand-in; the container app asks the system to
    /// re-read this list when the user switches image.
    private static func providedVoices() -> [AVSpeechSynthesisProviderVoice] {
        RC8650Engine.shared.start()
        let profile = RC8650Chip.profile
        return profile.voices.map { voice in
            let v = AVSpeechSynthesisProviderVoice(name: voice.systemName,
                                                   identifier: voice.identifier,
                                                   primaryLanguages: ["en-US"],
                                                   supportedLanguages: ["en-US"])
            // Gretchen is the RC8660's one female voice.
            v.gender = voice.name == "Gretchen" ? .female : .male
            v.version = profile.version     // the firmware's, from its header
            return v
        }
    }

    public override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get { Self.providedVoices() }
        set { }
    }

    // MARK: - Speaking

    public override func synthesizeSpeechRequest(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        // Before anything reads the chip's profile: the voice count and the
        // per-chip settings key both come from the firmware that is running,
        // and booting here is also what switches image if the app has chosen
        // another since the last request.
        RC8650Engine.shared.start()
        let voiceID = Self.voiceID(from: speechRequest.voice.identifier)
        let settings = SettingsStore.shared.current
        var parameters = settings.parameters(for: voiceID)
        parameters.voice = voiceID

        // Read the markup rather than handing it to
        // AVSpeechUtterance(ssmlRepresentation:), which drops every prosody
        // attribute and every break — see SSML.swift.
        var items = SSML.parse(speechRequest.ssmlRepresentation)
        items = Self.applyPolicy(to: items, settings: settings)

        if !settings.preamble.isEmpty {
            items.insert(.speech(SpeechSpan(text: settings.preamble)), at: 0)
        }
        if !settings.postamble.isEmpty {
            items.append(.speech(SpeechSpan(text: settings.postamble)))
        }

        let stream = SpeechStream(outputSampleRate: outputBus.format.sampleRate)
        activeStream.withLock { current in
            current?.cancel()
            current = stream
        }
        stream.start(parameters: parameters, items: items)

        // One marker covering the whole utterance, at its start.
        //
        // Not word-level highlighting: this synthesizer cannot honestly provide
        // that.  The chip does report index markers where their text really
        // falls — send <CTRL+A>nI between words and the numbers come back in
        // time with the speech — but librc8650's rc8650_read_serial runs the
        // emulated CPU forward when its queue is empty, so a caller cannot say
        // which sample a marker arrived at without a library change.  Estimating
        // per-word positions from character counts would produce highlighting
        // that is confidently wrong, which is worse than none.
        let spoken = items.reduce(into: "") { text, item in
            if case .speech(let span) = item { text += span.text }
        }
        let marker = AVSpeechSynthesisMarker(
            markerType: .sentence,
            forTextRange: NSRange(location: 0, length: (spoken as NSString).length),
            atByteSampleOffset: 0)
        speechSynthesisOutputMetadataBlock?([marker], speechRequest)
    }

    /// Honour — or ignore — what the calling app asked for on top of the user's
    /// settings.  Each of the three can be switched off in the container app,
    /// for callers whose idea of "fast" is not the user's.
    private static func applyPolicy(to items: [SpeechItem],
                                    settings: RC8650Settings) -> [SpeechItem] {
        guard !(settings.honorUtteranceRate
                && settings.honorUtterancePitch
                && settings.honorUtteranceVolume) else { return items }
        return items.map { item in
            guard case .speech(var span) = item else { return item }
            if !settings.honorUtteranceRate { span.rateScale = 1 }
            if !settings.honorUtterancePitch { span.pitchScale = 1 }
            if !settings.honorUtteranceVolume { span.volumeScale = 1 }
            return .speech(span)
        }
    }

    public override func cancelSpeechRequest() {
        activeStream.withLock { stream in
            stream?.cancel()
            stream = nil
        }
    }

    // MARK: - Rendering

    public override var internalRenderBlock: AUInternalRenderBlock {
        let streamBox = activeStream
        let scratch = self.scratch

        return { actionFlags, _, frameCount, _, outputData, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)
            let bytes = frames * MemoryLayout<Float>.size

            // A host may hand over a buffer list with null pointers and expect
            // the unit to supply the memory.
            if buffers[0].mData == nil {
                guard let memory = scratch.pointer, scratch.capacity >= frames else {
                    return kAudioUnitErr_Uninitialized
                }
                buffers[0].mData = UnsafeMutableRawPointer(memory)
            }
            buffers[0].mNumberChannels = 1
            buffers[0].mDataByteSize = UInt32(bytes)
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_InvalidParameter
            }

            guard let stream = streamBox.withLockIfAvailable({ $0 }) ?? nil else {
                // Nothing to say, or the lock is momentarily held by a request
                // starting: silence this cycle rather than wait for it.
                out.update(repeating: 0, count: frames)
                return noErr
            }

            let (_, complete) = stream.render(into: out, frames: frames)
            if complete {
                actionFlags.pointee = .offlineUnitRenderAction_Complete
            }
            return noErr
        }
    }

    // MARK: - Request decoding

    private static func voiceID(from identifier: String) -> Int {
        if let last = identifier.split(separator: ".").last, let n = Int(last),
           n >= 0, n < RC8650Chip.voices.count {
            return n
        }
        return 0
    }

}
