import Carbon.HIToolbox
import Combine
import OSLog
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
  static private(set) var shared: AppDelegate!

  override init() {
    super.init()
    Self.shared = self
  }

  lazy var checkvistManager: CheckvistManager = CheckvistManager()
  private var statusItem: NSStatusItem!
  private var window: NSWindow?
  private var keyMonitor: Any?
  private var clickMonitor: Any?
  private var globalHotkeyRef: EventHotKeyRef?
  private var cancellables = Set<AnyCancellable>()
  private var lastToggleTime: Date = Date.distantPast
  private var pendingPopoverResize: DispatchWorkItem?
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.checkvist-focus", category: "keyboard")

  private var currentPopoverContentSize: NSSize {
    NSSize(
      width: PopoverLayout.width,
      height: PopoverLayout.preferredHeight(for: checkvistManager)
    )
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.title = "…"
    statusItem.button?.action = #selector(clicked)
    statusItem.button?.target = self
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

    // Title sync
    checkvistManager.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        DispatchQueue.main.async {
          self?.updateTitle()
          self?.schedulePopoverResize()
        }
      }
      .store(in: &cancellables)

    // Install shared Carbon event handler for hotkeys once
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, _ -> OSStatus in
        Task { @MainActor in
          AppDelegate.shared.togglePopover()
        }
        return noErr
      }, 1, &eventType, nil, nil)

    // Global key monitor for shortcuts not handled by onKeyPress (j/k, hf, Ctrl+↑↓)
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let w = self.window, w.isVisible else { return event }
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
        if enabled { self?.registerGlobalHotkey() } else { self?.unregisterGlobalHotkey() }
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

    checkvistManager.$maxTitleWidth
      .dropFirst().receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.updateTitle()
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

    let hotKeyID = EventHotKeyID(
      signature: OSType(0x4356_464B),  // "CVFK"
      id: 1)
    var ref: EventHotKeyRef?
    let keyCode = UInt32(checkvistManager.globalHotkeyKeyCode)
    let modifiers = UInt32(checkvistManager.globalHotkeyModifiers)
    let status = RegisterEventHotKey(
      keyCode, modifiers, hotKeyID,
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
      let taskText = self.checkvistManager.currentTaskText
      if taskText.isEmpty {
        self.statusItem?.button?.attributedTitle = NSAttributedString(string: "…")
        self.statusItem?.button?.toolTip = nil
        self.statusItem?.length = NSStatusItem.variableLength
        self.statusItem?.button?.layer?.mask = nil
        return
      }

      let text: String
      if let timerStr = self.checkvistManager.timerBarString {
        text =
          self.checkvistManager.timerBarLeading
          ? "\(timerStr)  \(taskText)"
          : "\(taskText)  \(timerStr)"
      } else {
        text = taskText
      }

      let pStyle = NSMutableParagraphStyle()
      pStyle.lineBreakMode = .byClipping
      let font = NSFont.menuBarFont(ofSize: 0)
      let attrString = NSAttributedString(
        string: text, attributes: [.paragraphStyle: pStyle, .font: font])

      let maxWidth: CGFloat = CGFloat(self.checkvistManager.maxTitleWidth)
      let textWidth = attrString.size().width
      let finalWidth = min(textWidth + 16, maxWidth)

      self.statusItem?.length = finalWidth
      self.statusItem?.button?.attributedTitle = attrString
      self.statusItem?.button?.toolTip = nil
      self.statusItem?.button?.wantsLayer = true

      if textWidth > finalWidth - 16 {
        let maskLayer = CAGradientLayer()
        maskLayer.frame = CGRect(x: 0, y: 0, width: finalWidth, height: 22)
        maskLayer.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        maskLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        maskLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        let fadeStart = (finalWidth - 24) / finalWidth
        maskLayer.locations = [0.0, NSNumber(value: fadeStart), 1.0]
        self.statusItem?.button?.layer?.mask = maskLayer
      } else {
        self.statusItem?.button?.layer?.mask = nil
      }
    }
  }

  @MainActor func handleSupplementalKey(event: NSEvent) -> Bool {
    let m = checkvistManager
    let shift = event.modifierFlags.contains(.shift)
    let ctrl = event.modifierFlags.contains(.control)
    let cmd = event.modifierFlags.contains(.command)
    let option = event.modifierFlags.contains(.option)

    // We consider the user "typing" if they are explicitly focused in the text box
    let isFocused = m.isQuickEntryFocused

    let chars = event.charactersIgnoringModifiers ?? ""

    // Reliable fallback for command/actions prompt
    if cmd && !shift && !ctrl && !option && chars.lowercased() == "k" && !isFocused {
      m.keyBuffer = ""
      m.quickEntryMode = .command
      m.filterText = ""
      m.isQuickEntryFocused = true
      m.commandSuggestionIndex = 0
      logger.log("Opened command palette via Cmd+K")
      return true
    }

    if m.quickEntryMode == .command && isFocused {
      if event.keyCode == 125 {
        m.selectNextCommandSuggestion(for: m.filterText)
        return true
      }
      if event.keyCode == 126 {
        m.selectPreviousCommandSuggestion(for: m.filterText)
        return true
      }
      if event.keyCode == 36 {
        let suggestions = m.filteredCommandSuggestions(query: m.filterText)
        if suggestions.indices.contains(m.commandSuggestionIndex) {
          let selected = suggestions[m.commandSuggestionIndex]
          if selected.submitImmediately {
            m.isQuickEntryFocused = false
            m.quickEntryMode = .search
            m.filterText = ""
            Task { await m.executeCommandInput(selected.command) }
          } else {
            m.filterText = selected.command
            m.isQuickEntryFocused = true
          }
          return true
        }
      }
    }

    // Delete confirmation: Return confirms, anything else cancels
    if m.pendingDeleteConfirmation {
      if event.keyCode == 36 {  // Return — confirm delete
        m.pendingDeleteConfirmation = false
        Task {
          if let t = m.currentTask {
            await m.deleteTask(t)
            self.updateTitle()
          }
        }
        return true
      } else {  // Any other key — cancel
        m.pendingDeleteConfirmation = false
        m.filterText = ""
        m.quickEntryMode = .search
        m.isQuickEntryFocused = false
        if event.keyCode == 53 { return true }  // Escape just cancels
      }
    }

    // Cmd+↑/↓ — reorder
    if cmd && event.keyCode == 125 {
      Task { if let t = m.currentTask { await m.moveTask(t, direction: 1) } }
      return true
    }
    if cmd && event.keyCode == 126 {
      Task { if let t = m.currentTask { await m.moveTask(t, direction: -1) } }
      return true
    }

    // Up/Down arrows — navigate list ALWAYS (even if focused, to allow list navigation while typing)
    if event.keyCode == 125 {
      m.nextTask()
      updateTitle()
      return true
    }
    if event.keyCode == 126 {
      m.previousTask()
      updateTitle()
      return true
    }

    // Shift+→ — focus/hoist (Checkvist), plain → — enter children
    if event.keyCode == 124 {
      if isFocused { return false }
      m.enterChildren()
      if !m.filterText.isEmpty {
        m.filterText = ""
        m.quickEntryMode = .search
        m.isQuickEntryFocused = false
      }
      return true
    }
    // Shift+← — un-focus (Checkvist), plain ← — exit to parent
    if event.keyCode == 123 {
      if isFocused { return false }
      if !m.filterText.isEmpty {
        m.filterText = ""
        m.quickEntryMode = .search
        m.isQuickEntryFocused = false
      }
      m.exitToParent()
      updateTitle()
      return true
    }

    // Space — mark done; Shift+Space — invalidate (Checkvist)
    if event.keyCode == 49 && !isFocused && !ctrl && !cmd {
      if shift {
        Task {
          await m.invalidateCurrentTask()
          self.updateTitle()
        }
      } else {
        Task {
          await m.markCurrentTaskDone()
          self.updateTitle()
        }
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
      if shift {
        Task { if let t = m.currentTask { await m.unindentTask(t) } }
      } else {
        m.quickEntryMode = .addChild
        m.isQuickEntryFocused = true
      }
      return true
    }

    // Escape — cancel input if active; otherwise close
    if event.keyCode == 53 {
      if isFocused || m.quickEntryMode != .search || !m.filterText.isEmpty {
        m.isQuickEntryFocused = false
        m.quickEntryMode = .search
        m.filterText = ""
        return true
      }
      closeWindow()
      return true
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
        m.commandSuggestionIndex = 0
        m.filterText = ""
        m.isQuickEntryFocused = false
      } else {
        Task {
          if let t = m.currentTask {
            await m.deleteTask(t)
            self.updateTitle()
          }
        }
      }
      return true
    }

    // ── Two-key sequences ──
    // Starter chars: e, d, g — swallow first press, dispatch on second
    let seqStarters: Set<String> = ["e", "d", "g"]
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
          m.commandSuggestionIndex = 0
          m.filterText = "due "
          m.isQuickEntryFocused = true
          return true
        case "gg":
          m.openTaskLink()
          return true
        default: break
        }
      }
      return false  // no match — let second char through
    }
    if seqStarters.contains(chars) && !shift && !ctrl && !isFocused {
      m.keyBuffer = chars
      return true
    }

    // t — toggle timer for current task
    if chars == "t" && !shift && !ctrl && !isFocused {
      if m.timerIsEnabled {
        m.toggleTimerForCurrentTask()
      }
      return true
    }

    // p — pause/resume timer
    if chars == "p" && !shift && !ctrl && !isFocused {
      if m.timerIsEnabled {
        if m.timerRunning { m.pauseTimer() } else { m.resumeTimer() }
      }
      return true
    }

    // j/k/u — Vim up/down navigation, undo
    if chars == "u" && !shift && !ctrl && !isFocused {
      Task { await m.undoLastAction() }
      return true
    }
    if chars == "j" && !shift && !ctrl && !isFocused {
      m.nextTask()
      updateTitle()
      return true
    }
    if chars == "k" && !shift && !ctrl && !isFocused {
      m.previousTask()
      updateTitle()
      return true
    }

    // h/l — Vim left/right navigation (parent / children)
    if chars == "h" && !shift && !ctrl && !isFocused {
      if !m.filterText.isEmpty {
        m.filterText = ""
        m.quickEntryMode = .search
        m.isQuickEntryFocused = false
      }
      m.exitToParent()
      updateTitle()
      return true
    }
    if chars == "l" && !shift && !ctrl && !isFocused {
      m.enterChildren()
      if !m.filterText.isEmpty {
        m.filterText = ""
        m.quickEntryMode = .search
        m.isQuickEntryFocused = false
      }
      return true
    }

    // H (Shift+h) — toggle hide future
    if chars == "h" && shift && !ctrl && !isFocused {
      m.hideFuture.toggle()
      return true
    }

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
      m.commandSuggestionIndex = 0
      m.filterText = ""
      m.isQuickEntryFocused = true
      return true
    }

    return false
  }

  // MARK: - Window

  private func makeWindowIfNeeded() -> FocusPanel {
    if let existing = window as? FocusPanel { return existing }

    let contentSize = currentPopoverContentSize
    let w = FocusPanel(
      contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
      styleMask: [.nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    // Ensure the window has no title bar and is transparent
    w.titleVisibility = .hidden
    w.titlebarAppearsTransparent = true
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = true
    w.level = .floating
    w.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]

    let hostingController = NSHostingController(
      rootView: PopoverView().environmentObject(checkvistManager))
    w.contentViewController = hostingController

    w.isMovableByWindowBackground = false
    window = w

    // Monitor for clicks outside the window to dismiss it
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      guard let self, let w = self.window, w.isVisible else { return }
      let clickLocation = event.locationInWindow
      // If the click is not inside our window bounds, close it
      if !w.frame.contains(clickLocation) && event.window == nil {
        self.closeWindow()
      }
    }

    return w
  }

  func closeWindow() {
    window?.orderOut(nil)
    if [.addSibling, .addChild].contains(checkvistManager.quickEntryMode) {
      checkvistManager.filterText = ""
      checkvistManager.quickEntryMode = .search
    }
    checkvistManager.isQuickEntryFocused = false
    updateTitle()  // Commit current selection as the menu bar title
  }

  @objc func clicked(_ sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    if event.type == .rightMouseUp {
      let menu = NSMenu()
      menu.addItem(withTitle: "Refresh", action: #selector(menuRefresh), keyEquivalent: "")
      if #available(macOS 14.0, *) {
        menu.addItem(makeSettingsMenuItem())
      } else {
        menu.addItem(withTitle: "Settings...", action: #selector(menuSettings), keyEquivalent: ",")
      }
      menu.addItem(.separator())
      menu.addItem(withTitle: "Quit", action: #selector(menuQuit), keyEquivalent: "q")

      // Allow menu items to trigger actions on self
      for item in menu.items { item.target = self }

      statusItem.menu = menu
      statusItem.button?.performClick(nil)
      statusItem.menu = nil
    } else {
      togglePopover()
    }
  }

  @objc func menuRefresh() {
    Task { [weak self] in
      await self?.checkvistManager.fetchTopTask()
      self?.updateTitle()
    }
  }

  @objc func menuSettings() {
    if #available(macOS 13.0, *) {
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } else {
      NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  @available(macOS 14.0, *)
  private func makeSettingsMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let hostingView = NSHostingView(
      rootView:
        SettingsLink {
          Text("Settings...")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .frame(width: 180, alignment: .leading)
    )
    hostingView.frame.size = hostingView.fittingSize
    item.view = hostingView
    return item
  }

  @objc func menuQuit() {
    exit(0)
  }

  func togglePopover() {
    let now = Date()
    guard now.timeIntervalSince(lastToggleTime) > 0.2 else { return }
    lastToggleTime = now

    let w = makeWindowIfNeeded()
    if w.isVisible {
      closeWindow()
    } else if let button = statusItem.button {
      // Position the window directly below the button, aligned to its right edge
      let btnRect = button.convert(button.bounds, to: nil)  // To window coords
      let screenRect = button.window!.convertToScreen(btnRect)  // To screen coords

      let paddingY: CGFloat = 4  // Small gap below menu bar
      let trX = screenRect.maxX + 10  // Align right edges (slightly inset for aesthetics)
      let trY = screenRect.minY - paddingY

      w.setAnchoredTopRight(
        contentSize: currentPopoverContentSize, topRight: NSPoint(x: trX, y: trY), display: true)

      w.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func updatePopoverSizeIfVisible() {
    guard let w = window as? FocusPanel, w.isVisible else { return }
    let anchoredTopRight = NSPoint(x: w.frame.maxX, y: w.frame.maxY)
    w.setAnchoredTopRight(
      contentSize: currentPopoverContentSize,
      topRight: anchoredTopRight,
      display: true
    )
  }

  private func schedulePopoverResize() {
    pendingPopoverResize?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.updatePopoverSizeIfVisible()
    }
    pendingPopoverResize = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: workItem)
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

class AnchorView: NSView {}

class FocusPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  func setAnchoredTopRight(contentSize: NSSize, topRight: NSPoint, display: Bool) {
    let frameSize = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
    let origin = NSPoint(x: topRight.x - frameSize.width, y: topRight.y - frameSize.height)
    super.setFrame(NSRect(origin: origin, size: frameSize), display: display)
  }
}
