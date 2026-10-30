// The Dictionaries tab: what is in the folder the extension reads, and the
// buttons that put things there.
//
// The list is numbered because the numbers are load order and load order is the
// only thing about a set of dictionaries there is to get wrong — rcdict matches
// first-match-wins, so the first file to define a word is the one that wins and
// a later file can only add.  Filename order is load order here, so the number
// beside a row is not decoration.

import SwiftUI
import UniformTypeIdentifiers

struct DictionariesTab: View {

    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var selection: DictionaryFile.ID?
    @State private var importing = false
    @State private var renaming: DictionaryFile?
    @State private var newName = ""
    @State private var creating = false

    private var store: DictionaryStore { model.dictionaries }

    private var selected: DictionaryFile? {
        store.files.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            explanation
            list
            buttons
            footer
        }
        .padding(16)
        .onAppear { store.reload() }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.plainText, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.importFiles(from: urls) }
        }
        .sheet(item: $renaming) { file in
            renameSheet(file)
        }
        .sheet(isPresented: $creating) {
            createSheet
        }
    }

    // MARK: - Pieces

    private var explanation: some View {
        Text("""
             Dictionaries change how words are pronounced. Every file here is \
             loaded, in the order shown, and the first rule that matches a word \
             wins — so a dictionary higher in the list cannot be overridden by \
             one below it, only added to. Rename a file to change where it comes.
             """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(Array(store.files.enumerated()), id: \.element.id) { index, file in
                row(index: index + 1, file: file)
                    .tag(file.id)
            }
        }
        .frame(minHeight: 180)
        .overlay {
            if store.files.isEmpty {
                ContentUnavailableView {
                    Text("No dictionaries")
                } description: {
                    Text("Add one to change how particular words are said.")
                } actions: {
                    Button("New Dictionary…") { startCreating() }
                    Button("Import…") { importing = true }
                }
            }
        }
        .accessibilityLabel("Dictionaries, in load order")
    }

    private func row(index: Int, file: DictionaryFile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).fontWeight(.medium)
                if let first = file.problems.first {
                    // The count and the first message, because "3 problems" on
                    // its own tells you only that you have to go looking.
                    Text(file.problems.count == 1
                         ? first.display
                         : "\(file.problems.count) problems — \(first.display)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(file.ruleCount == 1 ? "1 rule" : "\(file.ruleCount) rules")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        // simultaneousGesture rather than onTapGesture: a plain tap gesture on
        // a row takes the click the List needs for selection, which would leave
        // the buttons below permanently disabled.
        .simultaneousGesture(TapGesture(count: 2).onEnded { edit(file) })
        // One announcement per row rather than four fragments, and it leads
        // with the position because the position is the point of the list.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label(index: index, file: file))
        .contextMenu {
            Button("Edit…") { edit(file) }
            Button("Rename…") { startRenaming(file) }
            Button("Duplicate") { store.duplicate(file) }
            Divider()
            Button("Show in Finder") { reveal(file) }
            Divider()
            Button("Move to Trash") { store.delete(file) }
        }
    }

    private func label(index: Int, file: DictionaryFile) -> String {
        var parts = ["\(index) of \(store.files.count)", file.name,
                     file.ruleCount == 1 ? "1 rule" : "\(file.ruleCount) rules"]
        if !file.problems.isEmpty {
            parts.append(file.problems.count == 1
                         ? "1 problem: \(file.problems[0].display)"
                         : "\(file.problems.count) problems")
        }
        return parts.joined(separator: ", ")
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("New Dictionary…") { startCreating() }
            Button("Import…") { importing = true }
            Divider().frame(height: 18)
            Button("Edit…") { if let selected { edit(selected) } }
                .disabled(selected == nil)
            Button("Rename…") { if let selected { startRenaming(selected) } }
                .disabled(selected == nil)
            Button("Move to Trash") { if let selected { store.delete(selected) } }
                .disabled(selected == nil)

            Spacer()

            Button("Show Folder") { reveal(nil) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.status.isEmpty {
                Text(store.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Said plainly rather than left to be discovered: an imported file
            // is a copy, and the sandbox is why. See DictionaryStore.swift.
            Text("Imported dictionaries are copied here: the synthesizer is sandboxed and cannot read files kept elsewhere, so edit the copy with the Edit button rather than the original. Saving takes effect on the next thing spoken — nothing needs restarting.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sheets

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Dictionary").font(.headline)
            Text("A name beginning with a number is a simple way to fix where it comes in the load order — 00-mine.dict is read before 50-shared.dict.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { finishCreating() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { creating = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { finishCreating() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func renameSheet(_ file: DictionaryFile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Dictionary").font(.headline)
            Text("Dictionaries are loaded in filename order, so renaming is how one is moved earlier or later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { finishRenaming(file) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { finishRenaming(file) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Actions

    private func startCreating() {
        newName = "My Dictionary.dict"
        creating = true
    }

    private func finishCreating() {
        creating = false
        if let url = store.create(named: newName) {
            selection = url.lastPathComponent
            openWindow(id: DictionaryEditor.windowID, value: url.lastPathComponent)
        }
    }

    private func startRenaming(_ file: DictionaryFile) {
        newName = file.name
        renaming = file
    }

    private func finishRenaming(_ file: DictionaryFile) {
        renaming = nil
        store.rename(file, to: newName)
        // Follow the file rather than dropping the selection: renaming is how
        // load order is changed, so where it has landed in the list is the
        // interesting thing afterwards.
        let wanted = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        selection = store.files.first {
            $0.name.caseInsensitiveCompare(wanted) == .orderedSame
                || $0.name.caseInsensitiveCompare(wanted + ".dict") == .orderedSame
        }?.id
    }

    private func edit(_ file: DictionaryFile) {
        openWindow(id: DictionaryEditor.windowID, value: file.name)
    }

    private func reveal(_ file: DictionaryFile?) {
        try? FileManager.default.createDirectory(at: store.folder,
                                                 withIntermediateDirectories: true)
        if let file {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([store.folder])
        }
    }
}
