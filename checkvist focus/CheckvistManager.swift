import Foundation
import SwiftUI
import Combine
import Security
import ServiceManagement

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

    private static let dueDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var dueDate: Date? {
        guard let due else { return nil }
        return Self.dueDateFormatter.date(from: due)
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

    // MARK: - Filters & Quick Entry
    enum QuickEntryMode { case search, addSibling, addChild, editTask, command }
    
    @Published var filterText: String = ""
    @Published var hideFuture: Bool = false
    @Published var keyBuffer: String = ""
    @Published var quickEntryMode: QuickEntryMode = .search
    @Published var isQuickEntryFocused: Bool = false
    @Published var editCursorAtEnd: Bool = true  // true = append (a), false = insert (i)
    @Published var pendingDeleteConfirmation: Bool = false

    // MARK: - Settings
    @Published var confirmBeforeDelete: Bool
    @Published var launchAtLogin: Bool
    @Published var globalHotkeyEnabled: Bool
    /// Carbon keyCode for the global hotkey (default 49 = Space)
    @Published var globalHotkeyKeyCode: Int
    /// Carbon modifier mask (default 0x0800 = optionKey i.e. ⌥)
    @Published var globalHotkeyModifiers: Int

    /// Tasks visible at the current level, sorted by position
    var currentLevelTasks: [CheckvistTask] {
        tasks.filter { ($0.parentId ?? 0) == currentParentId }
             .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
    }

    var currentTask: CheckvistTask? {
        let level = visibleTasks
        guard !level.isEmpty else { return nil }
        if currentSiblingIndex >= level.count {
            currentSiblingIndex = level.count - 1
        }
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

    /// Visible tasks: searches recursively through subtasks when filter active
    var visibleTasks: [CheckvistTask] {
        if !filterText.isEmpty && quickEntryMode == .search {
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
        self.listId = UserDefaults.standard.string(forKey: "checkvistListId") ?? ""
        self.confirmBeforeDelete = UserDefaults.standard.object(forKey: "confirmBeforeDelete") as? Bool ?? true
        self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false
        self.globalHotkeyEnabled = UserDefaults.standard.object(forKey: "globalHotkeyEnabled") as? Bool ?? false
        self.globalHotkeyKeyCode = UserDefaults.standard.object(forKey: "globalHotkeyKeyCode") as? Int ?? 49  // Space
        self.globalHotkeyModifiers = UserDefaults.standard.object(forKey: "globalHotkeyModifiers") as? Int ?? 0x0800  // ⌥

        // Migrate remoteKey from UserDefaults to Keychain
        if let legacyKey = UserDefaults.standard.string(forKey: "checkvistRemoteKey"), !legacyKey.isEmpty {
            Self.setKeychainValue(legacyKey, forKey: "checkvistRemoteKey")
            UserDefaults.standard.removeObject(forKey: "checkvistRemoteKey")
        }
        self.remoteKey = Self.keychainValue(forKey: "checkvistRemoteKey") ?? ""

        setupBindings()
    }

    private func setupBindings() {
        $username.sink { UserDefaults.standard.set($0, forKey: "checkvistUsername") }.store(in: &cancellables)
        $remoteKey.sink { Self.setKeychainValue($0, forKey: "checkvistRemoteKey") }.store(in: &cancellables)
        $listId.sink { UserDefaults.standard.set($0, forKey: "checkvistListId") }.store(in: &cancellables)
        $confirmBeforeDelete.sink { UserDefaults.standard.set($0, forKey: "confirmBeforeDelete") }.store(in: &cancellables)
        $launchAtLogin.sink { newValue in
            UserDefaults.standard.set(newValue, forKey: "launchAtLogin")
            if #available(macOS 13.0, *) {
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch { print("Launch at login error: \(error)") }
            }
        }.store(in: &cancellables)
        $globalHotkeyEnabled.sink { UserDefaults.standard.set($0, forKey: "globalHotkeyEnabled") }.store(in: &cancellables)
        $globalHotkeyKeyCode.sink { UserDefaults.standard.set($0, forKey: "globalHotkeyKeyCode") }.store(in: &cancellables)
        $globalHotkeyModifiers.sink { UserDefaults.standard.set($0, forKey: "globalHotkeyModifiers") }.store(in: &cancellables)
    }

    // MARK: - Keychain

    private static func keychainValue(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func setKeychainValue(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: - Navigation

    @MainActor func nextTask() {
        let count = visibleTasks.count
        guard count > 0 else { return }
        currentSiblingIndex = (currentSiblingIndex + 1) % count
    }

    @MainActor func previousTask() {
        let count = visibleTasks.count
        guard count > 0 else { return }
        currentSiblingIndex = (currentSiblingIndex - 1 + count) % count
    }

    /// Navigate into the current task's children
    @MainActor func enterChildren() {
        guard let task = currentTask, !currentTaskChildren.isEmpty else { return }
        currentParentId = task.id
        currentSiblingIndex = 0
    }

    /// Navigate back up to the parent level
    @MainActor func exitToParent() {
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

    @MainActor func navigateTo(task: CheckvistTask) {
        let parentId = task.parentId ?? 0
        let siblings = tasks.filter { ($0.parentId ?? 0) == parentId }
                            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        currentParentId = parentId
        currentSiblingIndex = siblings.firstIndex(where: { $0.id == task.id }) ?? 0
    }
    // MARK: - API

    @MainActor func login() async -> Bool {
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

    @MainActor func fetchTopTask() async {
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

    @MainActor func markCurrentTaskDone() async {
        guard let task = currentTask else { return }
        await taskAction(task, endpoint: "close")
    }

    /// POST to a Checkvist task action endpoint (close, reopen, invalidate)
    @MainActor private func taskAction(_ task: CheckvistTask, endpoint: String) async {
        if token == nil { let ok = await login(); if !ok { return } }
        guard let validToken = token else { return }
        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id)/\(endpoint).json") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            if let r = response as? HTTPURLResponse, (200...299).contains(r.statusCode) {
                await fetchTopTask()
            } else {
                errorMessage = "Failed to \(endpoint) task."
            }
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
    }

    @MainActor func updateTask(task: CheckvistTask, content: String? = nil, due: String? = nil) async {
        if token == nil { let ok = await login(); if !ok { return } }
        guard let validToken = token else { return }
        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")

        var taskDict: [String: Any] = [:]
        if let c = content { taskDict["content"] = c }
        if let d = due { taskDict["due"] = d }

        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": taskDict])

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                await fetchTopTask()
            } else {
                errorMessage = "Failed to update task."
            }
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
    }

    @MainActor func addTask(content: String) async {
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

    @MainActor func addTaskAsChild(content: String, parentId: Int) async {
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

    // MARK: - Delete

    @MainActor func deleteTask(_ task: CheckvistTask) async {
        if token == nil { let ok = await login(); if !ok { return } }
        guard let validToken = token else { return }
        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json") else { return }

        isLoading = true
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            if let r = response as? HTTPURLResponse, (200...299).contains(r.statusCode) {
                await fetchTopTask()
            } else {
                errorMessage = "Failed to delete task."
                isLoading = false
            }
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
            isLoading = false
        }
    }

    // MARK: - Invalidate

    @MainActor func reopenCurrentTask() async {
        guard let task = currentTask else { return }
        await taskAction(task, endpoint: "reopen")
    }

    @MainActor func invalidateCurrentTask() async {
        guard let task = currentTask else { return }
        await taskAction(task, endpoint: "invalidate")
    }

    // MARK: - Open Link

    @MainActor func openTaskLink() {
        guard let task = currentTask else { return }
        // Extract first URL from task content
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let range = NSRange(task.content.startIndex..., in: task.content)
        if let match = detector.firstMatch(in: task.content, range: range),
           let url = match.url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Reorder

    @MainActor func moveTask(_ task: CheckvistTask, direction: Int) async {
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

    @MainActor func indentTask(_ task: CheckvistTask) async {
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

    @MainActor func unindentTask(_ task: CheckvistTask) async {
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
