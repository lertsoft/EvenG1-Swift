import SwiftUI
import EvenG1Core

/// Pins a line of text in the lens: a reminder, a talking point, a shopping list.
struct NotesWidgetView: View {
    @EnvironmentObject private var bluetoothManager: G1BluetoothManager

    @State private var text = ""
    @FocusState private var isFieldFocused: Bool

    private var isDisconnected: Bool {
        bluetoothManager.connectionState != .fullyConnected
    }

    private var wrappedLines: [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return bluetoothManager.textHelper.wrapText(trimmed)
    }

    var body: some View {
        Form {
            if isDisconnected {
                Section {
                    Label("Connect glasses to show notes", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("notes.connectRequiredLabel")
                }
            }

            Section {
                GlassesHUDPreview(text: text, placeholder: "Type below to preview it")
            } header: {
                Text("Preview")
            } footer: {
                Text(footerText)
            }

            Section("Note") {
                TextField("What should stay in view?", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .focused($isFieldFocused)
                    .accessibilityIdentifier("notes.textField")
            }

            Section {
                Button {
                    bluetoothManager.sendText(text)
                    isFieldFocused = false
                } label: {
                    Label("Show on glasses", systemImage: "paperplane.fill")
                }
                .accessibilityIdentifier("notes.sendButton")
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDisconnected)

                Button(role: .destructive) {
                    bluetoothManager.clearDisplay()
                    text = ""
                } label: {
                    Label("Clear the lens", systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("notes.clearButton")
                .disabled(isDisconnected)
            }
        }
        .navigationTitle("Notes & Prompts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFieldFocused = false }
            }
        }
    }

    private var footerText: String {
        let lineCount = wrappedLines.count
        guard lineCount > 0 else {
            return "The display fits \(G1TextHelper.maxLines) lines of text."
        }

        if lineCount > G1TextHelper.maxLines {
            return "Uses \(lineCount) lines — only the first \(G1TextHelper.maxLines) will fit on the display."
        }
        return "Uses \(lineCount) of \(G1TextHelper.maxLines) available lines."
    }
}
