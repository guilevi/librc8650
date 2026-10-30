// A small editor for one dictionary file.
//
// It exists because the files have to be copies (DictionaryStore.swift says
// why), and a copy the user cannot edit in place is a copy that goes stale the
// first time they change the original.  Editing here makes the copy the
// document rather than a snapshot of one.
//
// It is a separate window and not a sheet so that it can be left open while the
// main window speaks: write a rule, save, Speak, listen, adjust.  That loop is
// the entire job, and a modal sheet would break it every time round.

import SwiftUI

enum DictionaryEditor {
    static let windowID = "dictionary-editor"
}

struct DictionaryEditorView: View {

    let model: AppModel
    /// The file name, not a URL: a URL would have to be Codable through the
    /// window's value, and the folder is fixed anyway.
    let fileName: String?

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var saved = ""
    @State private var result = DictionaryValidator.Result(ruleCount: 0, problems: [])
    @State private var sample = "The computer is fast."
    @State private var preview = ""
    @State private var error: String?

    private var store: DictionaryStore { model.dictionaries }
    private var dirty: Bool { text != saved }

    private var url: URL? {
        guard let fileName else { return nil }
        return store.folder.appendingPathComponent(fileName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            editor
            summary
            tryItOut
            buttons
            note
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 520)
        .onAppear(perform: load)
        // .task(id:) cancels and restarts when the text changes, so the sleep
        // is the debounce: parsing on every keystroke of a long dictionary
        // would be wasted work between one letter and the next.
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            revalidate()
        }
        .task(id: sample) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            refreshPreview()
        }
        // Saving on close rather than asking: the alternative is a modal the
        // user has to answer before they can hear the change they just made.
        .onDisappear { if dirty { save() } }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(fileName ?? "Dictionary")
                .font(.headline)
            if dirty {
                Text("Edited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(dirty ? "\(fileName ?? "Dictionary"), edited"
                                  : (fileName ?? "Dictionary"))
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            // Tabs separate the columns of this format, so the editor must not
            // be helpful about them, and neither smart quotes nor substitution
            // has any business in a file of phoneme symbols.
            .disableAutocorrection(true)
            .border(Color.secondary.opacity(0.3))
            .frame(minHeight: 220)
            .accessibilityLabel("Dictionary text")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(result.ruleCount == 1 ? "1 rule" : "\(result.ruleCount) rules")
                    .monospacedDigit()
                if result.problems.isEmpty {
                    Text("no problems").foregroundStyle(.secondary)
                } else {
                    Text(result.problems.count == 1
                         ? "1 problem" : "\(result.problems.count) problems")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .accessibilityElement(children: .combine)

            if !result.problems.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(result.problems) { problem in
                            Text(problem.display)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 90)
                .accessibilityLabel("Problems")
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// The thing that turns a text box into an authoring tool: what the rules
    /// as they stand right now do to a line of text.  Control bytes are shown
    /// as ⌃A, because where the phoneme mode switches landed is most of what
    /// there is to see.
    private var tryItOut: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try it").font(.subheadline).fontWeight(.medium)
            TextField("Text to try", text: $sample)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Text to try the dictionary on")
            Text(preview.isEmpty ? "—" : preview)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                .padding(6)
                .background(Color.secondary.opacity(0.08))
                .accessibilityLabel("Result: \(preview.isEmpty ? "nothing" : preview)")
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty)
            Button("Revert") { text = saved }
                .disabled(!dirty)
            Button("Speak This") { model.speak(sample) }
                .help("Speaks the text above through this app's own copy of the chip, with every dictionary in the folder applied — save first to include these edits.")
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var note: some View {
        Text("Closing this window saves. What is saved applies to the next thing spoken — nothing needs restarting.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private func load() {
        guard let url else { return }
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        saved = text
        revalidate()
        refreshPreview()
    }

    private func revalidate() {
        result = DictionaryValidator.validate(text: text,
                                              name: fileName ?? "dictionary")
    }

    private func refreshPreview() {
        preview = DictionaryPreview.expand(text: sample, dictionary: text,
                                           name: fileName ?? "dictionary")
    }

    private func save() {
        guard let url else { return }
        do {
            try store.write(text, to: url)
            saved = text
            error = nil
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }
}
