import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    var checkvistManager = CheckvistManager()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.target = self

        // Title sync — objectWillChange fires before change, but .receive(on:) delays until after
        checkvistManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateTitle() }
            }
            .store(in: &cancellables)

        // Global key monitor for shortcuts not handled by onKeyPress (j/k, hf, Ctrl+↑↓)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let p = self.popover, p.isShown else { return event }
            return self.handleSupplementalKey(event: event) ? nil : event
        }

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self.checkvistManager.fetchTopTask()
            DispatchQueue.main.async { self.updateTitle() }
        }
    }

    func updateTitle() {
        let text = checkvistManager.currentTaskText
        let display = text.isEmpty ? "…" : (text.count > 22 ? String(text.prefix(22)) + "…" : text)
        statusItem?.button?.title = display
        statusItem?.button?.toolTip = text.isEmpty ? nil : text
    }

    func handleSupplementalKey(event: NSEvent) -> Bool {
        let m = checkvistManager
        let shift = event.modifierFlags.contains(.shift)
        let ctrl  = event.modifierFlags.contains(.control)
        let chars = event.charactersIgnoringModifiers ?? ""

        // We consider the user "typing" if they have text in the QuickEntryField
        // If they don't, we can aggressively assume single-key shortcuts
        let isTyping = !m.filterText.isEmpty

        // Ctrl+↑/↓ — reorder
        if ctrl && event.keyCode == 125 { Task { if let t = m.currentTask { await m.moveTask(t, direction: 1) }  }; return true }
        if ctrl && event.keyCode == 126 { Task { if let t = m.currentTask { await m.moveTask(t, direction: -1) } }; return true }

        // Up/Down arrows - always navigate list
        if event.keyCode == 125 { m.nextTask(); updateTitle(); return true }
        if event.keyCode == 126 { m.previousTask(); updateTitle(); return true }

        // Left/Right arrows - navigate hierarchy only if empty
        if event.keyCode == 124 {
            if isTyping { return false } // let text field move cursor
            m.enterChildren(); return true
        }
        if event.keyCode == 123 {
            if isTyping { return false } // let text field move cursor
            m.exitToParent(); updateTitle(); return true
        }

        // Return - mark done if empty
        if event.keyCode == 36 {
            if isTyping { return false } // let text field submit
            Task { await m.markCurrentTaskDone(); self.updateTitle() }
            return true
        }

        // Tab / Shift+Tab — indent/unindent
        if event.keyCode == 48 {
            if isTyping { return false } // let text field submit child
            if shift { Task { if let t = m.currentTask { await m.unindentTask(t) } } }
            else     { Task { if let t = m.currentTask { await m.indentTask(t) } }  }
            return true
        }

        // h+f sequence — hide future toggle
        if chars == "h" && !shift && !ctrl && !isTyping { m.keyBuffer = "h"; return true }
        if m.keyBuffer == "h" {
            m.keyBuffer = ""
            if chars == "f" && !shift && !ctrl && !isTyping { m.hideFuture.toggle(); return true }
            return false
        }
        if !isTyping { m.keyBuffer = "" }

        // j/k — Vim navigation
        if chars == "j" && !shift && !ctrl && !isTyping { m.nextTask(); updateTitle(); return true }
        if chars == "k" && !shift && !ctrl && !isTyping { m.previousTask(); updateTitle(); return true }

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
            Task { await checkvistManager.fetchTopTask(); DispatchQueue.main.async { self.updateTitle() } }
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

    func applicationWillTerminate(_ notification: Notification) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }
}
