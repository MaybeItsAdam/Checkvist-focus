import SwiftUI
import AppKit

// MARK: - Carbon modifier constants (avoid importing Carbon in SwiftUI file)
private let carbonCmdKey     = 0x0100
private let carbonShiftKey   = 0x0200
private let carbonOptionKey  = 0x0800
private let carbonControlKey = 0x1000

// MARK: - Hotkey Recorder

class HotkeyNSTextField: NSTextField {
    var isRecording = false
    var onRecord: ((Int, Int) -> Void)?
    var displayString: String = ""

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        stringValue = "Type shortcut\u{2026}"
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        stringValue = displayString
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }

        if event.keyCode == 53 { // Escape = cancel
            window?.makeFirstResponder(nil)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonMods = 0
        if flags.contains(.command) { carbonMods |= carbonCmdKey }
        if flags.contains(.shift)   { carbonMods |= carbonShiftKey }
        if flags.contains(.option)  { carbonMods |= carbonOptionKey }
        if flags.contains(.control) { carbonMods |= carbonControlKey }

        // Require at least one modifier for a global hotkey
        guard carbonMods != 0 else { return }

        onRecord?(Int(event.keyCode), carbonMods)
        window?.makeFirstResponder(nil)
    }
}

struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    func makeNSView(context: Context) -> HotkeyNSTextField {
        let tf = HotkeyNSTextField()
        tf.isEditable = false
        tf.isSelectable = false
        tf.alignment = .center
        tf.font = .systemFont(ofSize: 12)
        tf.bezelStyle = .roundedBezel
        tf.displayString = Self.displayString(keyCode: keyCode, modifiers: modifiers)
        tf.stringValue = tf.displayString
        tf.onRecord = { code, mods in
            keyCode = code
            modifiers = mods
        }
        return tf
    }

    func updateNSView(_ tf: HotkeyNSTextField, context: Context) {
        tf.displayString = Self.displayString(keyCode: keyCode, modifiers: modifiers)
        if !tf.isRecording {
            tf.stringValue = tf.displayString
        }
        tf.onRecord = { code, mods in
            keyCode = code
            modifiers = mods
        }
    }

    static func displayString(keyCode: Int, modifiers: Int) -> String {
        var mods = ""
        if modifiers & carbonControlKey != 0 { mods += "\u{2303}" }
        if modifiers & carbonOptionKey  != 0 { mods += "\u{2325}" }
        if modifiers & carbonShiftKey   != 0 { mods += "\u{21E7}" }
        if modifiers & carbonCmdKey     != 0 { mods += "\u{2318}" }

        let keyNames: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            36: "\u{21A9}", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            48: "\u{21E5}", 49: "Space", 50: "`", 51: "\u{232B}",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
            123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}"
        ]

        let keyName = keyNames[keyCode] ?? "Key\(keyCode)"
        return mods + keyName
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var checkvistManager: CheckvistManager

    var body: some View {
        Form {
            Section(header: Text("Checkvist Credentials")) {
                TextField("Username (Email)", text: $checkvistManager.username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocorrectionDisabled()

                SecureField("Remote API Key", text: $checkvistManager.remoteKey)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                TextField("List ID", text: $checkvistManager.listId)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocorrectionDisabled()
            }
            .padding(.bottom, 10)

            HStack {
                Spacer()

                if checkvistManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.trailing, 8)
                }

                Button("Test Connection & Save") {
                    Task {
                        let success = await checkvistManager.login()
                        if success {
                            await checkvistManager.fetchTopTask()
                        }
                    }
                }
                .disabled(checkvistManager.isLoading || checkvistManager.username.isEmpty || checkvistManager.remoteKey.isEmpty || checkvistManager.listId.isEmpty)
            }

            if let errorMessage = checkvistManager.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.top, 10)
            } else if !checkvistManager.isLoading && checkvistManager.currentTaskText != "Loading..." && checkvistManager.currentTaskText != "Error" && checkvistManager.currentTaskText != "Login failed." && checkvistManager.currentTaskText != "List ID not set." && checkvistManager.currentTaskText != "Authentication required." {
                Text("Successfully connected! Top Task: \(checkvistManager.currentTaskText)")
                    .foregroundColor(.green)
                    .font(.caption)
                    .padding(.top, 10)
            }

            Divider().padding(.vertical, 10)

            Section(header: Text("Preferences")) {
                Toggle("Confirm before deleting tasks", isOn: $checkvistManager.confirmBeforeDelete)
                if #available(macOS 13.0, *) {
                    Toggle("Launch at login", isOn: $checkvistManager.launchAtLogin)
                }

                HStack {
                    Toggle("Global hotkey", isOn: $checkvistManager.globalHotkeyEnabled)
                    Spacer()
                    if checkvistManager.globalHotkeyEnabled {
                        HotkeyRecorderField(
                            keyCode: $checkvistManager.globalHotkeyKeyCode,
                            modifiers: $checkvistManager.globalHotkeyModifiers
                        )
                        .frame(width: 120, height: 22)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
