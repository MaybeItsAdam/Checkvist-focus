# Checkvist Focus

A blazing-fast, keyboard-centric macOS Menu Bar application that seamlessly integrates with your [Checkvist](https://checkvist.com/) account to help you focus on your top priorities. It brings complex task management to your fingertips with advanced Vim-style navigation and editing.

## Features

- **Menu Bar Integration:** Sits quietly in your macOS menu bar. The icon guarantees your top-most actionable task from a specified list is always visible, even around the MacBook notch.
- **Vim-Style Navigation:** Keep your hands on the keyboard. Navigate through your lists and hierarchies using familiar Vim motions:
  - `j` / `k` or `↑`/`↓` to move up and down tasks.
  - `Enter` or `→` to enter subtasks (children).
  - `Backspace` or `←` to navigate back to the parent level.
- **Search & Filter (`/`):** Press `/` to instantly activate search mode. Type to filter tasks dynamically. The navigation completely syncs with your search results.
- **Inline Editing (`i` or `a`):** Hit `i` or `a` on a selected task to instantly spawn an inline text box to edit the task's content (updates via Checkvist API).
- **Command Mode (`:` or `;`):** Press `:` to execute quick commands on the selected task:
  - `done` / `undone` — mark task as completed or open.
  - `due today` / `due tomorrow` / `due 2026-03-15` — assign due dates instantly.
  - `clear due` — remove a due date.
- **Fluid Task Addition:**
  - Press `Enter` on any task to add a new sibling task directly underneath. 
  - Press `Tab` to add a new child task, complete with visual indentation tracking.
- **Focus Mode Features:**
  - Press `h` then `f` to toggle hiding/showing future tasks.
  - Due dates are color-coded (Red for overdue, Orange for due today).
- **SwiftUI Native Settings:** Configure your Checkvist credentials and List ID directly in the macOS native Settings window.

## Configuration

To use the app, you will need your Checkvist OpenAPI credentials:

1. **Username:** Your Checkvist account email.
2. **OpenAPI Key:** Generate a remote key from your Checkvist profile pages (Account > OpenAPI key).
3. **List ID:** The ID of the list you want to sync. You can find this in the URL when viewing a list on the Checkvist website (e.g., `https://checkvist.com/checklists/123456`, the List ID is `123456`).

Enter these in the app's Settings preferences.

## Architecture & Tech Stack

- **Swift 6** & **SwiftUI** for the UI, state, and list rendering.
- **AppKit** (`NSStatusItem`, `NSPopover`) for the menu bar lifecycle. Global keyboard monitors directly intercept key events.
- **Combine** & `@Published` along with `UserDefaults` for persistent configuration and state management (`ObservableObject`).
- **Checkvist OpenAPI** via `URLSession` async/await requests for API synchronization.

## Build Requirements

- macOS 13.0+
- Xcode 14.0+

## License

MIT License.
