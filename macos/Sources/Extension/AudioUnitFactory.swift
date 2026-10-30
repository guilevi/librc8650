// The extension's principal class: what the system asks for the audio unit.
//
// Named in Info.plist under NSExtensionPrincipalClass, alongside the
// AudioComponents entry that declares this a type 'ausp' — a speech synthesis
// provider — and NSExtensionPointIdentifier com.apple.AudioUnit-Speech.

import AVFoundation
import AudioToolbox
import os

public final class AudioUnitFactory: NSObject, AUAudioUnitFactory {

    private static let log = Logger(subsystem: "com.guilevi.rc8650", category: "factory")

    var audioUnit: AUAudioUnit?

    public func beginRequest(with context: NSExtensionContext) {}

    @objc
    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        // Boot the chip here rather than on the first utterance: a cold boot is
        // about 5 ms, and doing it now means the first thing the user asks for
        // is not also the first thing that has to load 900 KB of S-records.
        if !RC8650Engine.shared.start(), let failure = RC8650Engine.shared.bootFailure {
            Self.log.error("RC8650 not available: \(failure.localizedDescription, privacy: .public)")
        }
        let unit = try RC8650SpeechAudioUnit(componentDescription: componentDescription,
                                             options: [])
        audioUnit = unit
        return unit
    }
}
