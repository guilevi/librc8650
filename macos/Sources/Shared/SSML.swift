// Reading the request the host actually sent.
//
// A speech synthesis provider is handed SSML, and the obvious way to read it —
// AVSpeechUtterance(ssmlRepresentation:) — throws away everything that makes it
// SSML.  Measured against the real thing:
//
//   in  <speak><prosody pitch="+50.0%" rate="340.0%">Hello.</prosody></speak>
//   out speechString "Hello.", rate 0.5, pitchMultiplier 1.0, volume 1.0
//
//   in  <speak>First phrase.<break time="400ms"/>Second phrase.</speak>
//   out speechString "First phrase.Second phrase."
//
// Every prosody attribute comes back at its default whatever the markup says,
// and a break is dropped so completely that the text either side is run
// together without even a space.  That is why the voices ignored VoiceOver's
// rate — VoiceOver sets it, AVSpeechSynthesizer duly writes it into the SSML,
// and the parser drops it on the floor.
//
// So the markup is read here instead.  AVSpeechSynthesizer's own rate scale,
// measured end to end through this extension:
//
//   utterance.rate  0.0    0.1   0.2   0.3   0.4   0.5   0.6   0.7   0.8   0.9  1.0
//   SSML rate      12.5%   30%  47.5%  65%  82.5%   -    160%  220%  280%  340% 400%
//
// 100% is neutral and is expressed by leaving the attribute off entirely, which
// is the plain SSML reading: the percentage scales the voice's normal rate.
// Nothing here depends on that table — it is the specified meaning that is
// implemented — but it is what the table confirms.

import Foundation

/// One run of text, with the prosody in force where it appears.  The scales are
/// multipliers on whatever the user has configured for the voice, so a request
/// with no prosody at all comes through as exactly the container app's settings.
public struct SpeechSpan: Equatable, Sendable {
    public var text: String
    public var rateScale: Double = 1
    public var pitchScale: Double = 1
    public var volumeScale: Double = 1
    /// `<say-as interpret-as="characters">`, which is the chip's own character
    /// mode (nC) rather than anything this has to spell out itself.
    public var spellOut: Bool = false
}

public enum SpeechItem: Equatable, Sendable {
    case speech(SpeechSpan)
    case silence(seconds: Double)
}

public enum SSML {

    /// Parse a request into spans and pauses.  Never fails: markup this does not
    /// understand contributes its text and nothing else, and input that is not
    /// XML at all is treated as plain text, because a user who asked for
    /// something spoken should hear it either way.
    public static func parse(_ ssml: String) -> [SpeechItem] {
        guard let data = ssml.data(using: .utf8) else {
            return [.speech(SpeechSpan(text: ssml))]
        }
        let parser = XMLParser(data: data)
        let delegate = Builder()
        parser.delegate = delegate
        guard parser.parse() else {
            // Not well-formed. Strip the tags and speak the words.
            let stripped = ssml.replacingOccurrences(of: "<[^>]*>", with: " ",
                                                     options: .regularExpression)
            return [.speech(SpeechSpan(text: stripped))]
        }
        delegate.closeSpan()
        return delegate.items
    }

    // MARK: - Attribute values

    /// SSML rate: a percentage, a bare multiplier, or one of the named steps.
    public static func rate(_ value: String) -> Double? {
        switch value.lowercased() {
        case "x-slow":  return 0.5
        case "slow":    return 0.75
        case "medium", "default", "normal": return 1
        case "fast":    return 1.25
        case "x-fast":  return 1.5
        default: break
        }
        if value.hasSuffix("%"), let n = Double(value.dropLast()) { return n / 100 }
        return Double(value)
    }

    /// SSML pitch: a signed percentage, semitones, or a named step.  Returned as
    /// a multiplier on the current pitch.
    public static func pitch(_ value: String) -> Double? {
        switch value.lowercased() {
        case "x-low":   return 0.7
        case "low":     return 0.85
        case "medium", "default", "normal": return 1
        case "high":    return 1.2
        case "x-high":  return 1.4
        default: break
        }
        if value.hasSuffix("%"), let n = Double(value.dropLast()) { return 1 + n / 100 }
        if value.lowercased().hasSuffix("st"), let n = Double(value.dropLast(2)) {
            return pow(2, n / 12)
        }
        if value.hasSuffix("Hz") || value.hasSuffix("hz") { return nil }  // absolute; not ours to map
        return Double(value)
    }

    /// SSML volume: decibels, a percentage, or a named step.
    public static func volume(_ value: String) -> Double? {
        switch value.lowercased() {
        case "silent":  return 0
        case "x-soft":  return 0.25
        case "soft":    return 0.5
        case "medium", "default", "normal": return 1
        case "loud":    return 1.5
        case "x-loud":  return 2
        default: break
        }
        if value.lowercased().hasSuffix("db"), let n = Double(value.dropLast(2)) {
            return pow(10, n / 20)
        }
        if value.hasSuffix("%"), let n = Double(value.dropLast()) { return n / 100 }
        return Double(value)
    }

    /// `<break>`: an explicit time, or a strength to translate into one.
    public static func breakDuration(time: String?, strength: String?) -> Double {
        if let time {
            let lower = time.lowercased()
            if lower.hasSuffix("ms"), let n = Double(lower.dropLast(2)) { return n / 1000 }
            if lower.hasSuffix("s"), let n = Double(lower.dropLast()) { return n }
            if let n = Double(lower) { return n }
        }
        switch (strength ?? "medium").lowercased() {
        case "none":     return 0
        case "x-weak":   return 0.05
        case "weak":     return 0.1
        case "strong":   return 0.4
        case "x-strong": return 0.8
        default:         return 0.2      // medium
        }
    }

    // MARK: - The parse itself

    private final class Builder: NSObject, XMLParserDelegate {
        var items: [SpeechItem] = []
        private var text = ""
        private var stack: [SpeechSpan] = [SpeechSpan(text: "")]

        private var current: SpeechSpan { stack[stack.count - 1] }

        /// Flush the text accumulated under the current prosody.
        func closeSpan() {
            guard !text.isEmpty else { return }
            var span = current
            span.text = text
            items.append(.speech(span))
            text = ""
        }

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            switch name.lowercased() {
            case "break":
                closeSpan()
                let seconds = SSML.breakDuration(time: attributes["time"],
                                                 strength: attributes["strength"])
                if seconds > 0 { items.append(.silence(seconds: seconds)) }
                // A break is a phrase boundary; do not push a prosody frame.
                return
            case "prosody":
                closeSpan()
                var span = current
                if let v = attributes["rate"], let s = SSML.rate(v) { span.rateScale *= s }
                if let v = attributes["pitch"], let s = SSML.pitch(v) { span.pitchScale *= s }
                if let v = attributes["volume"], let s = SSML.volume(v) { span.volumeScale *= s }
                stack.append(span)
            case "say-as":
                closeSpan()
                var span = current
                let how = (attributes["interpret-as"] ?? "").lowercased()
                span.spellOut = (how == "characters" || how == "spell-out" || how == "verbatim")
                stack.append(span)
            case "s", "p":
                // Sentence and paragraph: a boundary, and the chip's own
                // punctuation handling does the rest.
                closeSpan()
                stack.append(current)
            default:
                stack.append(current)
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            if name.lowercased() == "break" { return }
            closeSpan()
            if stack.count > 1 { stack.removeLast() }
            // A paragraph break is worth a real pause; a sentence one is not,
            // since the text usually carries its own full stop.
            if name.lowercased() == "p" { items.append(.silence(seconds: 0.3)) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }
    }
}
