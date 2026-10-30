import SwiftUI

/// An integer chip parameter: a slider to sweep it, a stepper to land on a
/// value exactly, and the value itself in the chip's own units.
///
/// The chip's units, not a percentage — the number shown here is the number in
/// the datasheet, so one step of the stepper is one step of the card and the
/// Interrogate readout on the Diagnostics tab can be compared to it directly.
struct IntSliderRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var caption: String? = nil
    var display: (Int) -> String = { "\($0)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(title)
                    .frame(width: 150, alignment: .leading)
                Slider(
                    value: Binding(get: { Double(value) },
                                   set: { value = Int($0.rounded()) }),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1
                )
                .accessibilityLabel(title)
                .accessibilityValue(display(value))
                Text(display(value))
                    .monospacedDigit()
                    .frame(width: 110, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Stepper(title, value: $value, in: range)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityValue(display(value))
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 162)
            }
        }
    }
}

/// A picker over one of the chip's small enumerated fields.
struct ChoiceRow: View {
    let title: String
    @Binding var value: Int
    let options: [(value: Int, name: String)]
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(title, selection: $value) {
                ForEach(options, id: \.value) { option in
                    Text(option.name).tag(option.value)
                }
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A checkbox with an explanation under it, since several of these invert the
/// sense of the register bit they set.
struct ToggleRow: View {
    let title: String
    @Binding var value: Bool
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: $value)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One bit of a register, named where the bit is known and numbered where it
/// is not.
struct BitRow: View {
    let title: String
    let bit: Int
    @Binding var register: Int
    var caption: String? = nil

    var body: some View {
        ToggleRow(
            title: title,
            value: Binding(
                get: { register & (1 << bit) != 0 },
                set: { register = $0 ? register | (1 << bit) : register & ~(1 << bit) }),
            caption: caption)
    }
}

/// Bytes as the chip sent them: hex, and the printable characters beside it.
struct ByteDump: View {
    let bytes: [UInt8]

    var body: some View {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let ascii = String(bytes.map { $0 >= 0x20 && $0 < 0x7f ? Character(UnicodeScalar($0)) : "." })
        VStack(alignment: .leading, spacing: 2) {
            Text(hex).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text(ascii).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reply, \(bytes.count) bytes")
        .accessibilityValue(hex)
    }
}
