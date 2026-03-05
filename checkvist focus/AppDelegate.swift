import SwiftUI
import Combine
import Carbon.HIToolbox

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    lazy var checkvistManager: CheckvistManager = CheckvistManager()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var keyMonitor: Any?
    private var globalHotkeyRef: EventHotKeyRef?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.target = self

        // Title sync
        checkvistManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)

        // Install shared Carbon event handler for hotkeys once
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Task { @MainActor in
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.togglePopover()
                }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        // Global key monitor for shortcuts not handled by onKeyPress (j/k, hf, Ctrl+↑↓)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let p = self.popover, p.isShown else { return event }
            return self.handleSupplementalKey(event: event) ? nil : event
        }

        // Register global hotkey if enabled
        if checkvistManager.globalHotkeyEnabled {
            registerGlobalHotkey()
        }
        checkvistManager.$globalHotkeyEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if enabled { self?.registerGlobalHotkey() }
                else { self?.unregisterGlobalHotkey() }
            }
            .store(in: &cancellables)

        // Re-register when hotkey key/modifiers change
        checkvistManager.$globalHotkeyKeyCode
            .dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.checkvistManager.globalHotkeyEnabled else { return }
                self.registerGlobalHotkey()
            }
            .store(in: &cancellables)
        checkvistManager.$globalHotkeyModifiers
            .dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.checkvistManager.globalHotkeyEnabled else { return }
                self.registerGlobalHotkey()
            }
            .store(in: &cancellables)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.checkvistManager.fetchTopTask()
            self?.updateTitle()
        }
    }

    // MARK: - Global Hotkey (⌥Space by default)

    private func registerGlobalHotkey() {
        unregisterGlobalHotkey()

        let hotKeyID = EventHotKeyID(signature: OSType(0x4356_464B), // "CVFK"
                                      id: 1)
        var ref: EventHotKeyRef?
        let keyCode = UInt32(checkvistManager.globalHotkeyKeyCode)
        let modifiers = UInt32(checkvistManager.globalHotkeyModifiers)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { globalHotkeyRef = ref }
    }

    private func unregisterGlobalHotkey() {
        if let ref = globalHotkeyRef {
            UnregisterEventHotKey(ref)
            globalHotkeyRef = nil
        }
    }

    func updateTitle() {
        DispatchQueue.main.async {
            let text = self.checkvistManager.currentTaskText
            // Heavily truncate to avoid MacBook notch collisions
            let display = text.isEmpty ? "…" : (text.count > 12 ? String(text.prefix(12)) + "…" : text)
            self.statusItem?.button?.title = display
            self.statusItem?.button?.toolTip = text.isEmpty ? nil : text
        }
    }

    @MainActor func handleSupplementalKey(event: NSEvent) -> Bool {
        let m = checkvistManager
        let shift = event.modifierFlags.contains(.shift)
        let ctrl  = event.modifierFlags.contains(.control)
        let cmd   = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers ?? ""

        // We consider the user "typing" if they are explicitly focused in the text box
        let isFocused = m.isQuickEntryFocused

        // Delete confirmation: Return confirms, anything else cancels
        if m.pendingDeleteConfirmation {
            if event.keyCode == 36 { // Return — confirm delete
                m.pendingDeleteConfirmation = false
                Task { if let t = m.currentTask { await m.deleteTask(t); self.updateTitle() } }
                return true
            } else { // Any other key — cancel
                m.pendingDeleteConfirmation = false
                m.filterText = ""
                m.quickEntryMode = .search
                m.isQuickEntryFocused = false
                if event.keyCode == 53 { return true } // Escape just cancels
            }
        }

        // Ctrl+↑/↓ — reorder
        if ctrl && event.keyCode == 125 { Task { if let t = m.currentTask { await m.moveTask(t, direction: 1) }  }; return true }
        if ctrl && event.keyCode == 126 { Task { if let t = m.currentTask { await m.moveTask(t, direction: -1) } }; return true }

        // Up/Down arrows — navigate list ALWAYS (even if focused, to allow list navigation while typing)
        if event.keyCode == 125 { m.nextTask(); updateTitle(); return true }
        if event.keyCode == 126 { m.previousTask(); updateTitle(); return true }

        // Shift+→ — focus/hoist (Checkvist), plain → — enter children
        if event.keyCode == 124 {
            if isFocused { return false }
            m.enterChildren()
            if !m.filterText.isEmpty { m.filterText = ""; m.quickEntryMode = .search; m.isQuickEntryFocused = false }
            return true
        }
        // Shift+← — un-focus (Checkvist), plain ← — exit to parent
        if event.keyCode == 123 {
            if isFocused { return false }
            if !m.filterText.isEmpty { m.filterText = ""; m.quickEntryMode = .search; m.isQuickEntryFocused = false }
            m.exitToParent(); updateTitle(); return true
        }

        // Space — mark done; Shift+Space — invalidate (Checkvist)
        if event.keyCode == 49 && !isFocused && !ctrl && !cmd {
            if shift {
                Task { await m.invalidateCurrentTask(); self.updateTitle() }
            } else {
                Task { await m.markCurrentTaskDone(); self.updateTitle() }
            }
            return true
        }

        // Shift+Enter — add sub-item (Checkvist); Enter — add sibling
        if event.keyCode == 36 {
            if isFocused { return false }
            if shift {
                m.quickEntryMode = .addChild
            } else {
                m.quickEntryMode = .addSibling
            }
            m.isQuickEntryFocused = true
            return true
        }

        // Tab / Shift+Tab — indent/unindent OR add child
        if event.keyCode == 48 {
            if isFocused { return false }
            if shift { Task { if let t = m.currentTask { await m.unindentTask(t) } } }
            else {
                m.quickEntryMode = .addChild
                m.isQuickEntryFocused = true
            }
            return true
        }

        // Escape — unfocus first, then clear filter if hit again
        if event.keyCode == 53 {
            if isFocused {
                m.isQuickEntryFocused = false
                return true
            } else if !m.filterText.isEmpty {
                m.filterText = ""
                m.quickEntryMode = .search
                return true
            }
            return false
        }

        // F2 — edit task (Checkvist), cursor at end
        if event.keyCode == 120 && !isFocused {
            m.quickEntryMode = .editTask
            m.editCursorAtEnd = true
            m.filterText = m.currentTask?.content ?? ""
            m.isQuickEntryFocused = true
            return true
        }

        // Del (forward delete / Fn+Backspace) — delete task (Checkvist)
        if event.keyCode == 117 && !isFocused {
            if m.confirmBeforeDelete {
                m.pendingDeleteConfirmation = true
                m.quickEntryMode = .command
                m.filterText = ""
                m.isQuickEntryFocused = false
            } else {
                Task { if let t = m.currentTask { await m.deleteTask(t); self.updateTitle() } }
            }
            return true
        }

        // ── Two-key sequences ──
        // Starter chars: e, d, t, g — swallow first press, dispatch on second
        let seqStarters: Set<String> = ["e", "d", "t", "g"]
        if !m.keyBuffer.isEmpty {
            let seq = m.keyBuffer + chars
            m.keyBuffer = ""
            if !isFocused {
                switch seq {
                case "ee", "ea":
                    m.quickEntryMode = .editTask
                    m.editCursorAtEnd = true
                    m.filterText = m.currentTask?.content ?? ""
                    m.isQuickEntryFocused = true
                    return true
                case "ei":
                    m.quickEntryMode = .editTask
                    m.editCursorAtEnd = false
                    m.filterText = m.currentTask?.content ?? ""
                    m.isQuickEntryFocused = true
                    return true
                case "dd":
                    m.quickEntryMode = .command
                    m.filterText = "due "
                    m.isQuickEntryFocused = true
                    return true
                case "tt":
                    m.quickEntryMode = .command
                    m.filterText = "tag "
                    m.isQuickEntryFocused = true
                    return true
                case "gg":
                    m.openTaskLink()
                    return true
                default: break
                }
            }
            return false // no match — let second char through
        }
        if seqStarters.contains(chars) && !shift && !ctrl && !isFocused {
            m.keyBuffer = chars
            return true
        }

        // j/k — Vim up/down navigation
        if chars == "j" && !shift && !ctrl && !isFocused { m.nextTask(); updateTitle(); return true }
        if chars == "k" && !shift && !ctrl && !isFocused { m.previousTask(); updateTitle(); return true }

        // h/l — Vim left/right navigation (parent / children)
        if chars == "h" && !shift && !ctrl && !isFocused {
            if !m.filterText.isEmpty { m.filterText = ""; m.quickEntryMode = .search; m.isQuickEntryFocused = false }
            m.exitToParent(); updateTitle(); return true
        }
        if chars == "l" && !shift && !ctrl && !isFocused {
            m.enterChildren()
            if !m.filterText.isEmpty { m.filterText = ""; m.quickEntryMode = .search; m.isQuickEntryFocused = false }
            return true
        }

        // H (Shift+h) — toggle hide future
        if chars == "h" && shift && !ctrl && !isFocused { m.hideFuture.toggle(); return true }

        // Forward-slash — focus search (Vim / Checkvist)
        if chars == "/" && !shift && !ctrl && !isFocused {
            m.quickEntryMode = .search
            m.isQuickEntryFocused = true
            return true
        }

        // i — insert (cursor at start), a — append (cursor at end)
        if chars == "i" && !shift && !ctrl && !isFocused {
            m.quickEntryMode = .editTask
            m.editCursorAtEnd = false
            m.filterText = m.currentTask?.content ?? ""
            m.isQuickEntryFocused = true
            return true
        }
        if chars == "a" && !shift && !ctrl && !isFocused {
            m.quickEntryMode = .editTask
            m.editCursorAtEnd = true
            m.filterText = m.currentTask?.content ?? ""
            m.isQuickEntryFocused = true
            return true
        }

        // : or ; — command mode
        if (chars == ":" || chars == ";") && !ctrl && !isFocused {
            m.quickEntryMode = .command
            m.filterText = ""
            m.isQuickEntryFocused = true
            return true
        }

        return false
    }

    // MARK: - Popover

    private func makePopoverIfNeeded() -> NSPopover {
        if let existing = popover { return existing }
        let p = NSPopover()
        p.contentSize = NSSize(width: 360, height: 460)
        p.behavior = .applicationDefined
        p.contentViewController = NSHostingController(
            rootView: PopoverView().environmentObject(checkvistManager)
        )
        popover = p
        return p
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            Task { [weak self] in 
                await self?.checkvistManager.fetchTopTask() 
                self?.updateTitle() 
            }
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        let p = makePopoverIfNeeded()
        if p.isShown { p.performClose(nil) }
        else if let button = statusItem.button {
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // SwiftUI will try to gracefully terminate the app when the Settings view is closed 
        // since we don't use MenuBarExtra. We must explicitly cancel this auto-termination.
        // Our explicit Quit button now uses exit(0) to bypass this hook.
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        unregisterGlobalHotkey()
    }
}
