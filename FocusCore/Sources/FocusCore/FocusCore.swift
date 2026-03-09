import Foundation

public struct CoreTask {
  public let id: Int
  public let parentId: Int?

  public init(id: Int, parentId: Int?) {
    self.id = id
    self.parentId = parentId
  }
}

public struct CommandSuggestion: Equatable {
  public let label: String
  public let command: String
  public let preview: String
  public let keybind: String?
  public let submitImmediately: Bool

  public init(label: String, command: String, preview: String, keybind: String?, submitImmediately: Bool) {
    self.label = label
    self.command = command
    self.preview = preview
    self.keybind = keybind
    self.submitImmediately = submitImmediately
  }
}

public enum FocusCore {
  public static let commandSuggestions: [CommandSuggestion] = [
    .init(label: "Mark done", command: "done", preview: "Close selected task", keybind: "Space", submitImmediately: true),
    .init(label: "Mark undone", command: "undone", preview: "Reopen selected task", keybind: nil, submitImmediately: true),
    .init(label: "Invalidate task", command: "invalidate", preview: "Invalidate selected task", keybind: "Shift+Space", submitImmediately: true),
    .init(label: "Due today", command: "due today", preview: "Set due date to today", keybind: "dd", submitImmediately: true),
    .init(label: "Due tomorrow", command: "due tomorrow", preview: "Set due date to tomorrow", keybind: "dd", submitImmediately: true),
    .init(label: "Due next week", command: "due next week", preview: "Set due date to next week", keybind: "dd", submitImmediately: true),
    .init(label: "Clear due date", command: "clear due", preview: "Remove due date", keybind: "dd", submitImmediately: true),
    .init(label: "Add tag", command: "tag ", preview: "Append #tag to task", keybind: nil, submitImmediately: false),
    .init(label: "Remove tag", command: "untag ", preview: "Remove #tag from task", keybind: nil, submitImmediately: false),
    .init(label: "Switch list", command: "list ", preview: "Find and switch list", keybind: nil, submitImmediately: false),
  ]

  public static func filteredCommandSuggestions(query: String, limit: Int = 8) -> [CommandSuggestion] {
    let q = query.lowercased().trimmingCharacters(in: .whitespaces)
    let candidates = commandSuggestions.filter { suggestion in
      q.isEmpty
        || suggestion.label.lowercased().contains(q)
        || suggestion.command.lowercased().contains(q)
        || suggestion.preview.lowercased().contains(q)
    }
    return Array(candidates.prefix(limit))
  }

  public static func resolveDueDate(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> String {
    let cal = calendar
    let isoFormatter: DateFormatter = {
      let f = DateFormatter()
      f.calendar = cal
      f.dateFormat = "yyyy-MM-dd"
      return f
    }()

    switch input.lowercased() {
    case "today":
      return isoFormatter.string(from: now)
    case "tomorrow":
      return isoFormatter.string(from: cal.date(byAdding: .day, value: 1, to: now)!)
    case "next week":
      return isoFormatter.string(from: cal.date(byAdding: .weekOfYear, value: 1, to: now)!)
    case "next month":
      return isoFormatter.string(from: cal.date(byAdding: .month, value: 1, to: now)!)
    case "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday":
      let weekdays = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
      ]
      if let target = weekdays[input.lowercased()] {
        let current = cal.component(.weekday, from: now)
        var diff = target - current
        if diff <= 0 { diff += 7 }
        return isoFormatter.string(from: cal.date(byAdding: .day, value: diff, to: now)!)
      }
      return input
    default:
      return input
    }
  }

  public static func totalElapsed(taskId: Int, tasks: [CoreTask], ownElapsed: [Int: TimeInterval]) -> TimeInterval {
    var childrenByParent: [Int: [CoreTask]] = [:]
    for task in tasks {
      childrenByParent[task.parentId ?? 0, default: []].append(task)
    }

    func total(for id: Int) -> TimeInterval {
      var elapsed = ownElapsed[id] ?? 0
      for child in childrenByParent[id] ?? [] {
        elapsed += total(for: child.id)
      }
      return elapsed
    }

    return total(for: taskId)
  }
}
