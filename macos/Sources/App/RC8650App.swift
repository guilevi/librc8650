// The container app.  Three jobs:
//
//   * it is what carries the speech synthesis extension, since a macOS app
//     extension ships inside an app and is registered when that app is;
//   * it edits the settings the extension speaks with, per voice;
//   * it is a bench for the chip — every command it accepts, the Interrogate
//     reply it answers with, and a Speak button that goes straight to the
//     emulator rather than through the system, so the two can be compared.

import SwiftUI

@main
struct RC8650App: App {

    @State private var model = AppModel()

    var body: some Scene {
        Window("RC8650", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Install Firmware Image…") { model.chooseFirmware() }
                Button("Refresh System Voice List") { model.refreshSystemVoices() }
            }
        }

        // One window per dictionary, keyed by file name, so that a dictionary
        // can be edited beside the main window rather than in a sheet on top of
        // it: write a rule, save, Speak, listen, adjust.  Asking for the same
        // file twice brings the window it is already open in to the front.
        WindowGroup(id: DictionaryEditor.windowID, for: String.self) { $name in
            DictionaryEditorView(model: model, fileName: name)
        }
        .windowResizability(.contentMinSize)
    }
}
