import SwiftUI
import AppKit

// MARK: - Tab-intercepting TextField wrapper
// Standard SwiftUI TextField sends Tab to focus-next. We need to intercept
// it and treat it as "add as child" instead.
class TabInterceptingTextField: NSTextField {
    var onTab: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 { onTab?(); return }   // 48 = Tab
        super.keyDown(with: event)
    }
}

struct QuickEntryField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void          // Enter
    var onTab: () -> Void             // Tab → add as child
    var onEscape: () -> Void          // Escape → clear

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TabInterceptingTextField {
        let tf = TabInterceptingTextField()
        tf.placeholderString = placeholder
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 13)
        tf.delegate = context.coordinator
        tf.onTab = onTab
        return tf
    }

    func updateNSView(_ tf: TabInterceptingTextField, context: Context) {
        if tf.stringValue != text { tf.stringValue = text }
        tf.placeholderString = placeholder
        tf.onTab = onTab
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickEntryField
        init(_ p: QuickEntryField) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.onEscape(); return true }
            return false
        }
    }
}

// MARK: - Popover View

struct PopoverView: View {
    @EnvironmentObject var manager: CheckvistManager
    @State private var queryText: String = ""
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()

            if !manager.breadcrumbs.isEmpty || manager.currentParentId != 0 {
                breadcrumbBar
                Divider()
            }

            if manager.hideFuture { hideFutureChip; Divider() }

            // Task list — keyboard navigable
            taskList
            Divider()

            hintBar
            Divider()

            // Unified search / add bar
            quickEntryBar
        }
        .frame(width: 360)
        .focusable()
        .focused($listFocused)
        .onAppear { listFocused = true }
    }

    // MARK: - Subviews

    var headerBar: some View {
        HStack {
            Text("Checkvist Focus").font(.headline).foregroundColor(.secondary)
            Spacer()
            Button { Task { await manager.fetchTopTask() } } label: {
                Image(systemName: "arrow.clockwise").foregroundColor(.secondary)
            }.buttonStyle(PlainButtonStyle()).help("Refresh")
            if #available(macOS 13.0, *) {
                SettingsLink { Image(systemName: "gearshape").foregroundColor(.secondary) }
                    .buttonStyle(PlainButtonStyle()).padding(.leading, 6)
            }
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "xmark.circle").foregroundColor(.secondary)
            }.buttonStyle(PlainButtonStyle()).padding(.leading, 6)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var breadcrumbBar: some View {
        HStack(spacing: 4) {
            Button { manager.exitToParent() } label: {
                Image(systemName: "chevron.left").font(.caption).foregroundColor(.blue)
            }.buttonStyle(PlainButtonStyle())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button("All Tasks") {
                        manager.currentParentId = 0; manager.currentSiblingIndex = 0
                    }.buttonStyle(PlainButtonStyle()).font(.caption2).foregroundColor(.blue)
                    ForEach(manager.breadcrumbs) { crumb in
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(.secondary)
                        Button(crumb.content) { manager.navigateTo(task: crumb) }
                            .buttonStyle(PlainButtonStyle()).font(.caption2).foregroundColor(.blue).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    var hideFutureChip: some View {
        HStack {
            Label("Hide Future", systemImage: "clock")
                .font(.caption2).padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.orange.opacity(0.15)).foregroundColor(.orange).clipShape(Capsule())
            Spacer()
            Button { manager.hideFuture = false } label: {
                Image(systemName: "xmark").font(.caption2).foregroundColor(.secondary)
            }.buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
    }

    var taskList: some View {
        Group {
            if manager.isLoading && manager.tasks.isEmpty {
                HStack { Spacer(); ProgressView().padding(24); Spacer() }
            } else if manager.visibleTasks.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: queryText.isEmpty ? "checkmark.circle" : "magnifyingglass")
                            .font(.title2).foregroundColor(.secondary)
                        Text(queryText.isEmpty ? "No tasks here" : "No matches")
                            .foregroundColor(.secondary).font(.callout)
                    }.padding(24)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(manager.visibleTasks.enumerated()), id: \.element.id) { index, task in
                                taskRow(task: task, index: index).id(task.id)
                            }
                        }
                    }
                    .onChange(of: manager.currentSiblingIndex) { _, _ in
                        if let t = manager.currentTask { proxy.scrollTo(t.id, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxHeight: 280)
    }

    var hintBar: some View {
        HStack(spacing: 10) {
            hintLabel("↑↓/jk")
            hintLabel("→ enter")
            hintLabel("← back")
            hintLabel("⏎ done")
            hintLabel("Tab child")
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(Color.secondary.opacity(0.05))
    }

    @ViewBuilder var quickEntryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: queryText.isEmpty ? "magnifyingglass" : "plus.circle")
                .foregroundColor(.secondary).font(.system(size: 13))

            QuickEntryField(
                text: $queryText,
                placeholder: queryText.isEmpty
                    ? "Search tasks… or type to add (⏎ sibling, ⇥ child)"
                    : "Add \"\(queryText)\"",
                onSubmit: { if !queryText.isEmpty { submitSibling() } },
                onTab:    { if !queryText.isEmpty { submitChild() } },
                onEscape: { queryText = ""; manager.filterText = "" }
            )
            .frame(height: 20)
            .onChange(of: queryText) { _, q in
                manager.filterText = q
                manager.currentSiblingIndex = 0
            }

            if !queryText.isEmpty {
                Button { queryText = ""; manager.filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }.buttonStyle(PlainButtonStyle())
            }

            if manager.isLoading {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)

        if let error = manager.errorMessage {
            Text(error).font(.caption2).foregroundColor(.red)
                .padding(.horizontal, 14).padding(.bottom, 6)
        }
    }

    // MARK: - Task Rows

    @ViewBuilder
    func taskRow(task: CheckvistTask, index: Int) -> some View {
        let isSelected = index == manager.currentSiblingIndex
        let childCount = manager.tasks.filter { ($0.parentId ?? 0) == task.id }.count

        Button { manager.currentSiblingIndex = index } label: {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    Task { manager.currentSiblingIndex = index; await manager.markCurrentTaskDone() }
                } label: {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(isSelected ? .accentColor : .secondary).font(.system(size: 14))
                }.buttonStyle(PlainButtonStyle())

                VStack(alignment: .leading, spacing: 3) {
                    // Show breadcrumb path when filter shows cross-level results
                    if !queryText.isEmpty, let pid = task.parentId, pid != manager.currentParentId {
                        Text(breadcrumbPath(for: task))
                            .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Text(task.content)
                        .font(.system(size: 13)).foregroundColor(.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let due = task.due {
                        dueBadge(due: due, overdue: task.isOverdue, today: task.isDueToday)
                    }
                }

                if childCount > 0 {
                    Button {
                        manager.currentSiblingIndex = index; manager.enterChildren()
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(childCount)").font(.caption2).foregroundColor(.secondary)
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }.buttonStyle(PlainButtonStyle()).help("Enter subtasks (→)")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.09) : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(Color.accentColor).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button("Mark Done") {
                Task { manager.currentSiblingIndex = index; await manager.markCurrentTaskDone() }
            }
            if childCount > 0 {
                Button("Enter Subtasks →") { manager.currentSiblingIndex = index; manager.enterChildren() }
            }
            Divider()
            Button("Move Up ⌃↑")   { Task { await manager.moveTask(task, direction: -1) } }
            Button("Move Down ⌃↓") { Task { await manager.moveTask(task, direction: 1) } }
            Divider()
            Button("Indent ⇥")    { Task { await manager.indentTask(task) } }
            Button("Unindent ⇧⇥") { Task { await manager.unindentTask(task) } }
        }
    }

    // MARK: - Helpers

    func breadcrumbPath(for task: CheckvistTask) -> String {
        var parts: [String] = []
        var pid = task.parentId ?? 0
        while pid != 0 && pid != manager.currentParentId {
            if let parent = manager.tasks.first(where: { $0.id == pid }) {
                parts.insert(parent.content, at: 0)
                pid = parent.parentId ?? 0
            } else { break }
        }
        return parts.joined(separator: " › ")
    }

    func submitSibling() {
        guard !queryText.isEmpty else { return }
        let content = queryText; queryText = ""; manager.filterText = ""
        Task { await manager.addTask(content: content) }
    }

    func submitChild() {
        guard !queryText.isEmpty, let parent = manager.currentTask else { return }
        let content = queryText; queryText = ""; manager.filterText = ""
        Task { await manager.addTaskAsChild(content: content, parentId: parent.id) }
    }

    @ViewBuilder
    func dueBadge(due: String, overdue: Bool, today: Bool) -> some View {
        Text(due).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(overdue ? Color.red.opacity(0.15) : today ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.1))
            .foregroundColor(overdue ? .red : today ? .orange : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    func hintLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary.opacity(0.6))
    }
}
