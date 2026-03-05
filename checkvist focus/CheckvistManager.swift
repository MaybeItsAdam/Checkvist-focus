import Foundation
import SwiftUI
import Combine

struct CheckvistTask: Codable, Identifiable {
    let id: Int
    let content: String
    let status: Int
    let due: String?
    let position: Int?
    let parentId: Int?
    let level: Int?

    enum CodingKeys: String, CodingKey {
        case id, content, status, due, position
        case parentId = "parent_id"
        case level
    }

    var dueDate: Date? {
        guard let due else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: due)
    }

    var isOverdue: Bool {
        guard let d = dueDate else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    var isDueToday: Bool {
        guard let d = dueDate else { return false }
        return Calendar.current.isDateInToday(d)
    }
}

class CheckvistManager: ObservableObject {
    @Published var username: String
    @Published var remoteKey: String
    @Published var listId: String

    /// All tasks (flat, from API)
    @Published var tasks: [CheckvistTask] = []
    
    /// The parent ID of the level currently being viewed (0 = root)
    @Published var currentParentId: Int = 0
    
    /// Index within the current level's sibling list
    @Published var currentSiblingIndex: Int = 0

    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    // MARK: - Filters
    @Published var filterText: String = ""
    @Published var hideFuture: Bool = false
    // UI state managed here so AppDelegate key monitor can drive it
    @Published var isFilterActive: Bool = false
    @Published var keyBuffer: String = ""

    /// Tasks visible at the current level, sorted by position
    var currentLevelTasks: [CheckvistTask] {
        tasks.filter { ($0.parentId ?? 0) == currentParentId }
             .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
    }

    var currentTask: CheckvistTask? {
        let level = currentLevelTasks
        guard !level.isEmpty, level.indices.contains(currentSiblingIndex) else { return nil }
        return level[currentSiblingIndex]
    }

    var currentTaskText: String { currentTask?.content ?? "" }

    /// Breadcrumb chain from root down to (but not including) current task
    var breadcrumbs: [CheckvistTask] {
        var result: [CheckvistTask] = []
        var parentId = currentParentId
        while parentId != 0 {
            if let parent = tasks.first(where: { $0.id == parentId }) {
                result.insert(parent, at: 0)
                parentId = parent.parentId ?? 0
            } else { break }
        }
        return result
    }

    /// Children of the currently focused task
    var currentTaskChildren: [CheckvistTask] {
        guard let t = currentTask else { return [] }
        return tasks.filter { ($0.parentId ?? 0) == t.id }
    }

    // Legacy compat for AppDelegate
    var currentTaskIndex: Int { currentSiblingIndex }

    /// Visible tasks: searches recursively through subtasks when filter active
    var visibleTasks: [CheckvistTask] {
        if !filterText.isEmpty {
            // Recursive search: include any task under currentParentId that matches
            return tasks.filter { task in
                task.content.localizedCaseInsensitiveContains(filterText) &&
                isDescendant(task, of: currentParentId)
            }
        }
        var result = currentLevelTasks
        if hideFuture {
            result = result.filter { task in
                guard let d = task.dueDate else { return false }
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
                return d <= Calendar.current.startOfDay(for: tomorrow)
            }
        }
        return result
    }

    /// Returns true if task is a descendant of the given parentId (or IS at that level)
    func isDescendant(_ task: CheckvistTask, of rootId: Int) -> Bool {
        if rootId == 0 { return true }   // root contains everything
        var pid = task.parentId ?? 0
        while pid != 0 {
            if pid == rootId { return true }
            pid = tasks.first(where: { $0.id == pid })?.parentId ?? 0
        }
        return false
    }

    private var token: String? = nil
    private var cancellables = Set<AnyCancellable>()

    // Bypass system PAC proxy scripts that cause -1003 errors
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [AnyHashable: Any]()
        return URLSession(configuration: config)
    }()

    init() {
        self.username = UserDefaults.standard.string(forKey: "checkvistUsername") ?? ""
        self.remoteKey = UserDefaults.standard.string(forKey: "checkvistRemoteKey") ?? ""
        self.listId = UserDefaults.standard.string(forKey: "checkvistListId") ?? ""
        setupBindings()
    }

    private func setupBindings() {
        $username.sink { UserDefaults.standard.set($0, forKey: "checkvistUsername") }.store(in: &cancellables)
        $remoteKey.sink { UserDefaults.standard.set($0, forKey: "checkvistRemoteKey") }.store(in: &cancellables)
        $listId.sink { UserDefaults.standard.set($0, forKey: "checkvistListId") }.store(in: &cancellables)
    }

    // MARK: - Tree Helpers (legacy, kept for AppDelegate Combine subscription)

    var currentTaskBreadcrumbs: [CheckvistTask] { breadcrumbs }

    // MARK: - Navigation

    func nextTask() {
        let count = currentLevelTasks.count
        guard count > 0 else { return }
        currentSiblingIndex = (currentSiblingIndex + 1) % count
    }

    func previousTask() {
        let count = currentLevelTasks.count
        guard count > 0 else { return }
        currentSiblingIndex = (currentSiblingIndex - 1 + count) % count
    }

    /// Navigate into the current task's children
    func enterChildren() {
        guard let task = currentTask, !currentTaskChildren.isEmpty else { return }
        currentParentId = task.id
        currentSiblingIndex = 0
    }

    /// Navigate back up to the parent level
    func exitToParent() {
        guard currentParentId != 0 else { return }
        // Find the parent task and make it the selected sibling
        if let parent = tasks.first(where: { $0.id == currentParentId }) {
            let grandparentId = parent.parentId ?? 0
            let siblings = tasks.filter { ($0.parentId ?? 0) == grandparentId }
                                .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
            currentParentId = grandparentId
            currentSiblingIndex = siblings.firstIndex(where: { $0.id == parent.id }) ?? 0
        } else {
            currentParentId = 0
            currentSiblingIndex = 0
        }
    }

    func navigateTo(task: CheckvistTask) {
        let parentId = task.parentId ?? 0
        let siblings = tasks.filter { ($0.parentId ?? 0) == parentId }
                            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        currentParentId = parentId
        currentSiblingIndex = siblings.firstIndex(where: { $0.id == task.id }) ?? 0
    }
    // MARK: - API

    func login() async -> Bool {
        guard !username.isEmpty, !remoteKey.isEmpty else {
            errorMessage = "Username or Remote Key is missing."
            return false
        }

        isLoading = true
        errorMessage = nil

        guard let url = URL(string: "https://checkvist.com/auth/login.json") else {
            errorMessage = "Invalid login URL."
            isLoading = false
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

        let body: [String: String] = ["username": username, "remote_key": remoteKey]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                errorMessage = "Login failed. Check your credentials."
                isLoading = false
                return false
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tokenString = json["token"] as? String {
                self.token = tokenString
            } else if let tokenString = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n")) {
                self.token = tokenString
            } else {
                errorMessage = "Failed to parse token."
                isLoading = false
                return false
            }

            isLoading = false
            return true
        } catch {
            errorMessage = "Network error: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    func fetchTopTask() async {
        guard !listId.isEmpty else { return }

        if token == nil {
            let success = await login()
            if !success { return }
        }

        guard let validToken = token else { return }

        isLoading = true
        errorMessage = nil

        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks.json") else {
            errorMessage = "Invalid list URL."
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                self.token = nil
                self.isLoading = false
                return
            }

            let decoder = JSONDecoder()
            let allTasks = try decoder.decode([CheckvistTask].self, from: data)

            // Only open tasks, walk depth-first respecting Checkvist's tree order
            let open = allTasks.filter { $0.status == 0 }
            
            // Build a depth-first order: sort each level by position, recurse children
            func depthFirst(parentId: Int, all: [CheckvistTask]) -> [CheckvistTask] {
                let children = all
                    .filter { ($0.parentId ?? 0) == parentId }
                    .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
                return children.flatMap { [$0] + depthFirst(parentId: $0.id, all: all) }
            }
            let sorted = depthFirst(parentId: 0, all: open)

            self.tasks = sorted
            if currentSiblingIndex >= sorted.count { currentSiblingIndex = 0 }
            print("DEBUG fetchTopTask: \(sorted.count) tasks loaded")

        } catch {
            print("DEBUG fetchTopTask error: \(error)")
            errorMessage = "Failed to fetch tasks: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func markCurrentTaskDone() async {
        guard let task = currentTask, let validToken = token else { return }

        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": ["status": 1]])

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                await fetchTopTask()
            } else {
                errorMessage = "Failed to mark task as done."
            }
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
    }

    func addTask(content: String) async {
        guard !content.isEmpty, !listId.isEmpty else { return }

        if token == nil {
            let success = await login()
            if !success { return }
        }

        guard let validToken = token else { return }

        isLoading = true
        errorMessage = nil

        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks.json") else {
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": ["content": content]])

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                await fetchTopTask()
            } else {
                errorMessage = "Failed to add task."
                isLoading = false
            }
        } catch {
            errorMessage = "Error adding task: \(error.localizedDescription)"
            isLoading = false
        }
    }

    func addTaskAsChild(content: String, parentId: Int) async {
        guard !content.isEmpty, !listId.isEmpty else { return }
        if token == nil { let ok = await login(); if !ok { return } }
        guard let validToken = token,
              let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks.json") else { return }
        isLoading = true; errorMessage = nil
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": ["content": content, "parent_id": parentId]])
        do {
            let (_, response) = try await session.data(for: request)
            if let r = response as? HTTPURLResponse, (200...299).contains(r.statusCode) { await fetchTopTask() }
            else { errorMessage = "Failed to add task."; isLoading = false }
        } catch { errorMessage = "Error: \(error.localizedDescription)"; isLoading = false }
    }

    // MARK: - Reorder

    func moveTask(_ task: CheckvistTask, direction: Int) async {
        guard let validToken = token else { return }
        let siblings = tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
                            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        guard let idx = siblings.firstIndex(where: { $0.id == task.id }) else { return }
        let newIdx = idx + direction
        guard siblings.indices.contains(newIdx) else { return }
        let neighbour = siblings[newIdx]

        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": ["position": neighbour.position ?? newIdx + 1]])
        _ = try? await session.data(for: request)
        await fetchTopTask()
        if let movedTask = tasks.first(where: { $0.id == task.id }) { navigateTo(task: movedTask) }
    }

    // MARK: - Indent / Unindent

    func indentTask(_ task: CheckvistTask) async {
        guard let validToken = token else { return }
        let siblings = tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
                            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        guard let idx = siblings.firstIndex(where: { $0.id == task.id }), idx > 0 else { return }
        let newParent = siblings[idx - 1]

        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": ["parent_id": newParent.id]])
        _ = try? await session.data(for: request)
        await fetchTopTask()
    }

    func unindentTask(_ task: CheckvistTask) async {
        guard let validToken = token, let parentId = task.parentId, parentId != 0 else { return }
        guard let parent = tasks.first(where: { $0.id == parentId }) else { return }
        let newParentId = parent.parentId ?? 0

        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = newParentId == 0 ? ["task": ["parent_id": NSNull()]] : ["task": ["parent_id": newParentId]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: request)
        await fetchTopTask()
    }
}
