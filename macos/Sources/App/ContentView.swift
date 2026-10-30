import SwiftUI

struct ContentView: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView {
                VoiceTab(model: model).tabItem { Text("Voice") }
                TextTab(model: model).tabItem { Text("Text") }
                DictionariesTab(model: model).tabItem { Text("Dictionaries") }
                OutputTab(model: model).tabItem { Text("Output") }
                AdvancedTab(model: model).tabItem { Text("Advanced") }
                DiagnosticsTab(model: model).tabItem { Text("Diagnostics") }
            }
            .padding(.top, 8)
            Divider()
            speakBar
        }
        .onAppear { model.refreshChipState() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Picker("Voice", selection: $model.parameters.voice) {
                ForEach(RC8650Chip.voices) { voice in
                    Text(voice.systemName).tag(voice.id)
                }
            }
            .frame(maxWidth: 320)

            Spacer()

            if model.bootError != nil {
                Label("No firmware", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(model.bootError ?? "")
            } else {
                Label("Chip ready", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var speakBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.text)
                .font(.body)
                .frame(height: 62)
                .border(Color.secondary.opacity(0.3))
                .accessibilityLabel("Text to speak")

            HStack(spacing: 12) {
                Button("Speak") { model.speak() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.bootError != nil)
                Button("Stop") { model.stop(); model.stopSystem() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider().frame(height: 18)
                Button("Speak Through macOS") { model.speakThroughSystem() }
                    .help("Goes out through AVSpeechSynthesizer, so it exercises the installed extension rather than this app's own copy of the chip.")

                Spacer()

                if let report = model.lastRender {
                    Text(String(format: "%.2f s of speech in %.2f s (%.1f× real time)",
                                report.seconds, report.wallClock, report.realtimeFactor))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }
}
