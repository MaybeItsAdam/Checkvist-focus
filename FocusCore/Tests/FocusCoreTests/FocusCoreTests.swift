import XCTest
@testable import FocusCore

final class FocusCoreTests: XCTestCase {
  func testFiltersSuggestions() {
    let due = FocusCore.filteredCommandSuggestions(query: "due")
    XCTAssertFalse(due.isEmpty)
    XCTAssertTrue(due.allSatisfy { $0.label.lowercased().contains("due") || $0.command.contains("due") })
  }

  func testResolveRelativeDates() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let start = ISO8601DateFormatter().date(from: "2026-03-08T00:00:00Z")!
    XCTAssertEqual(FocusCore.resolveDueDate("today", now: start, calendar: calendar), "2026-03-08")
    XCTAssertEqual(FocusCore.resolveDueDate("tomorrow", now: start, calendar: calendar), "2026-03-09")
    XCTAssertEqual(FocusCore.resolveDueDate("next week", now: start, calendar: calendar), "2026-03-15")
  }

  func testTimerRollupSumsDescendants() {
    let tasks: [CoreTask] = [
      .init(id: 1, parentId: nil),
      .init(id: 2, parentId: 1),
      .init(id: 3, parentId: 1),
      .init(id: 4, parentId: 2),
    ]
    let own: [Int: TimeInterval] = [1: 10, 2: 20, 3: 30, 4: 40]

    XCTAssertEqual(FocusCore.totalElapsed(taskId: 4, tasks: tasks, ownElapsed: own), 40)
    XCTAssertEqual(FocusCore.totalElapsed(taskId: 2, tasks: tasks, ownElapsed: own), 60)
    XCTAssertEqual(FocusCore.totalElapsed(taskId: 1, tasks: tasks, ownElapsed: own), 100)
  }
}
