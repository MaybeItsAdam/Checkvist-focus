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

struct CheckvistList: Codable, Identifiable {
    let id: Int
    let name: String
    let archived: Bool?
    let readOnly: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id, name, archived
        case readOnly = "read_only"
    }
}

class CheckvistManager: ObservableObject {
    @Published var username: String
    @Published var remoteKey: String
    @Published var listId: String

    /// All tasks (flat, from API)
    @Published var tasks: [CheckvistTask] = []
    
    /// User's available lists from the API
    @Published var availableLists: [CheckvistList] = []
    
    /// The parent ID of the level currently being viewed (0 = root)
    @Published var currentParentId: Int = 0
    
    /// Index within the current level's sibling list
    @Published var currentSiblingIndex: Int = 0

    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    // MARK: - Undo
    enum UndoableAction {
        case add(taskId: Int)
        case markDone(taskId: Int)
        case invalidate(taskId: Int)
        case update(taskId: Int, oldContent: String, oldDue: String?)
    }
    @Published var lastUndo: UndoableAction? = nil

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

    /// Max width of the menu bar text
    @Published var maxTitleWidth: Double

    /// Tasks visible at the current level, sorted by position
    var currentLevelTasks: [CheckvistTask] {
        tasks.filter { ($0.parentId ?? 0) == currentParentId }
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
        self.maxTitleWidth = UserDefaults.standard.object(forKey: "maxTitleWidth") as? Double ?? 150.0

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
        $maxTitleWidth.sink { UserDefaults.standard.set($0, forKey: "maxTitleWidth") }.store(in: &cancellables)
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
            // The API returns a flat list occasionally mixed up by creation time, so we must reconstruct the tree locally
            func depthFirst(parentId: Int, all: [CheckvistTask]) -> [CheckvistTask] {
                let children = all
                    .filter { ($0.parentId ?? 0) == parentId }
                    .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
                return children.flatMap { [$0] + depthFirst(parentId: $0.id, all: all) }
            }
            let sortedForest = depthFirst(parentId: 0, all: open)
            
            for t in sortedForest {
                print("DEBUG TASK: ID=\(t.id), Pos=\(t.position ?? -1), Content='\(t.content)', Due='\(t.due ?? "nil")'")
            }
            
            self.tasks = sortedForest
            if currentSiblingIndex >= sortedForest.count { currentSiblingIndex = 0 }
            print("DEBUG fetchTopTask: \(sortedForest.count) tasks loaded")

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
    @MainActor private func taskAction(_ task: CheckvistTask, endpoint: String, isUndo: Bool = false) async {
        if !isUndo {
            if endpoint == "close" {
                lastUndo = .markDone(taskId: task.id)
            } else if endpoint == "invalidate" {
                lastUndo = .invalidate(taskId: task.id)
            }
        }
        
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
    @MainActor func fetchLists() async {
        if token == nil { let ok = await login(); if !ok { return } }
        guard let validToken = token,
              let url = URL(string: "https://checkvist.com/checklists.json") else { return }
        
        var request = URLRequest(url: url)
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                let lists = try JSONDecoder().decode([CheckvistList].self, from: data)
                self.availableLists = lists.filter { !($0.archived ?? false) }
            }
        } catch {
            print("DEBUG fetchLists error: \(error)")
        }
    }

    @MainActor func updateTask(task: CheckvistTask, content: String? = nil, due: String? = nil, isUndo: Bool = false) async {
        if !isUndo {
            lastUndo = .update(taskId: task.id, oldContent: task.content, oldDue: task.due)
        }
        
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

    @MainActor func addTask(content: String, insertAfterTask: CheckvistTask? = nil) async {
        guard !content.isEmpty, !listId.isEmpty else { return }

        if token == nil {
            let success = await login()
            if !success { return }
        }

        guard let validToken = token else { return }

        isLoading = true
        errorMessage = nil

        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks.json?parse=true") else {
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0 (Macintosh; Mac OS X)", forHTTPHeaderField: "User-Agent")
        
        var taskPayload: [String: Any] = ["content": content]
        let optimisticParentId = currentParentId != 0 ? currentParentId : nil
        if currentParentId != 0 {
            taskPayload["parent_id"] = currentParentId
        }
        
        // Find current position to insert right below
        var apiPosition = 0
        let target = insertAfterTask ?? currentTask
        var arrayInsertIndex = tasks.endIndex
        
        if let current = target {
            if let targetPos = current.position {
                apiPosition = targetPos + 1
            } else {
                let siblings = tasks.filter { ($0.parentId ?? 0) == currentParentId }
                if let idx = siblings.firstIndex(where: { $0.id == current.id }) {
                    apiPosition = idx + 2
                }
            }
            if let rawIdx = tasks.firstIndex(where: { $0.id == current.id }) {
                var endIdx = rawIdx + 1
                while endIdx < tasks.count && isDescendant(tasks[endIdx], of: current.id) {
                    endIdx += 1
                }
                arrayInsertIndex = endIdx
            }
        } else {
            apiPosition = 1
            arrayInsertIndex = tasks.endIndex
        }
        
        if apiPosition > 0 { taskPayload["position"] = apiPosition }
        
        // Optimistic UI update
        let tempId = -Int.random(in: 1...1000000)
        let optimisticTask = CheckvistTask(id: tempId, content: content, status: 0, due: nil, position: nil, parentId: optimisticParentId, level: nil)
        
        if arrayInsertIndex <= tasks.endIndex {
            tasks.insert(optimisticTask, at: arrayInsertIndex)
        } else {
            tasks.append(optimisticTask)
        }
        
        // Hide UI instantly in the same layout pass as the array insertion
        self.filterText = ""
        self.quickEntryMode = .search
        self.isQuickEntryFocused = false
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": taskPayload])

        do {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                if let newTask = try? JSONDecoder().decode(CheckvistTask.self, from: data) {
                    lastUndo = .add(taskId: newTask.id)
                }
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
              let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks.json?parse=true") else { return }
        isLoading = true; errorMessage = nil
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": ["content": content, "parent_id": parentId]])
        
        // Optimistic UI update
        let childPosition = 1
        let tempId = -Int.random(in: 1...1000000)
        let optimisticTask = CheckvistTask(id: tempId, content: content, status: 0, due: nil, position: nil, parentId: parentId, level: nil)
        
        // Find parent index and insert immediately after
        if let parentRawIdx = tasks.firstIndex(where: { $0.id == parentId }) {
            tasks.insert(optimisticTask, at: parentRawIdx + 1)
        } else {
            tasks.append(optimisticTask)
        }
        
        // Hide UI instantly in the same layout pass as the array insertion
        self.filterText = ""
        self.quickEntryMode = .search
        self.isQuickEntryFocused = false
        
        // Also tell the API to put it at position 1
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": ["content": content, "parent_id": parentId, "position": childPosition]])
        
        do {
            let (data, response) = try await session.data(for: request)
            if let r = response as? HTTPURLResponse, (200...299).contains(r.statusCode) { 
                if let newTask = try? JSONDecoder().decode(CheckvistTask.self, from: data) {
                    lastUndo = .add(taskId: newTask.id)
                }
                await fetchTopTask() 
            }
            else { errorMessage = "Failed to add task."; isLoading = false }
        } catch { errorMessage = "Error: \(error.localizedDescription)"; isLoading = false }
    }

    // MARK: - Delete

    @MainActor func deleteTask(_ task: CheckvistTask, isUndo: Bool = false) async {
        if !isUndo {
            lastUndo = nil // Clear undo history since we don't support recovering hard-deleted tasks yet
        }
        
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

    // MARK: - Undo Execution
    
    @MainActor func undoLastAction() async {
        guard let action = lastUndo else { return }
        lastUndo = nil
        
        switch action {
        case .add(let taskId):
            let mockTask = CheckvistTask(id: taskId, content: "", status: 0, due: nil, position: nil, parentId: nil, level: nil)
            await deleteTask(mockTask, isUndo: true)
        case .markDone(let taskId), .invalidate(let taskId):
            let mockTask = CheckvistTask(id: taskId, content: "", status: 1, due: nil, position: nil, parentId: nil, level: nil)
            await taskAction(mockTask, endpoint: "reopen", isUndo: true)
        case .update(let taskId, let oldContent, let oldDue):
            let mockTask = CheckvistTask(id: taskId, content: "", status: 0, due: nil, position: nil, parentId: nil, level: nil)
            await updateTask(task: mockTask, content: oldContent, due: oldDue, isUndo: true)
        }
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
        guard let idx = siblings.firstIndex(where: { $0.id == task.id }) else { return }
        let newIdx = idx + direction
        guard siblings.indices.contains(newIdx) else { return }
        let neighbour = siblings[newIdx]
        
        // Optimistic UI update: instantly swap positions locally
        if let rawIdx1 = tasks.firstIndex(where: { $0.id == task.id }),
           let rawIdx2 = tasks.firstIndex(where: { $0.id == neighbour.id }) {
            let tempPos = tasks[rawIdx1].position
            tasks[rawIdx1] = CheckvistTask(id: task.id, content: task.content, status: task.status, due: task.due, position: neighbour.position, parentId: task.parentId, level: task.level)
            tasks[rawIdx2] = CheckvistTask(id: neighbour.id, content: neighbour.content, status: neighbour.status, due: neighbour.due, position: tempPos, parentId: neighbour.parentId, level: neighbour.level)
            
            // Adjust the selection index to follow the dragged task
            currentSiblingIndex = newIdx
        }

        guard let url = URL(string: "https://checkvist.com/checklists/\(listId)/tasks/\(task.id).json") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(validToken, forHTTPHeaderField: "X-Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CheckvistFocus/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": ["position": newIdx + 1]]) // Checkvist 1-indexed position
        _ = try? await session.data(for: request)
        
        // Wait gracefully to resync authoritative state
        await fetchTopTask()
    }

    // MARK: - Indent / Unindent

    @MainActor func indentTask(_ task: CheckvistTask) async {
        guard let validToken = token else { return }
        let siblings = tasks.filter { ($0.parentId ?? 0) == (task.parentId ?? 0) }
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
