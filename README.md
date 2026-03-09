# <img src="checkvist%20focus/Assets.xcassets/AppIcon.appiconset/ios-1024.png" alt="Checkvist Focus logo" width="28" /> Checkvist Focus

A blazing-fast, keyboard-centric macOS Menu Bar application that seamlessly integrates with your [Checkvist](https://checkvist.com/) account to help you focus on your top priorities.

## Features

### Menu Bar

The menu bar shows your currently focused task. When timer display is enabled, it shows the selected task's rolled-up timer value (task + descendants).

### Navigation

| Key | Action |
|-----|--------|
| `j` / `↓` | Move to next task |
| `k` / `↑` | Move to previous task |
| `→` or `l` | Enter subtasks (children) |
| `←` or `h` | Go back to parent level |
| `Esc` | Revert selection to when popover opened, close |

### Task Completion

Press `Space` to mark the current task done. Completion is tactile and satisfying:
- Immediate haptic pulse
- The circle icon springs into a green checkmark
- A strikethrough line draws across the task text
- Additional haptic confirmation pulses follow
- The task then disappears

Press `Shift+Space` to **invalidate** (void) a task instead.

### Timer

| Key | Action |
|-----|--------|
| `t` | Start timer for current task (or switch to a different task's timer) |
| `p` | Pause / resume the running timer |

The timer badge appears beneath the task text and shows elapsed time in the most readable unit:
- `42s` — seconds (under a minute)
- `1.4m` / `14m` — minutes (to 2 significant figures)
- `1.4h` / `14h` — hours (to 2 significant figures)

The timer persists while you navigate and across app relaunches. Parent tasks display rolled-up totals from descendants.

### Searching & Filtering

Press `/` to open search. Type to filter tasks dynamically — results search recursively through all subtasks under the current level. Press `Esc` to clear.

### Editing

| Key | Action |
|-----|--------|
| `i` | Edit task, cursor at start |
| `a` or `ee` / `ea` | Edit task, cursor at end |
| `ei` | Edit task, cursor at start (two-key) |
| `F2` | Edit task, cursor at end |

Press `Enter` to save, `Esc` to cancel.

### Adding Tasks

| Key | Action |
|-----|--------|
| `Enter` | Add sibling task below current |
| `Shift+Enter` | Add child task |
| `Tab` | Add child task (in quick-entry field, promotes to child) |

Checkvist smart syntax works on creation: `^today`, `^tomorrow`, `^monday`, `^2026-03-15` assign due dates inline.

### Commands (`:` or `;`)

Press `:` or `;` to enter command mode for the current task:

| Command | Action |
|---------|--------|
| `done` / `undone` | Mark complete or reopen |
| `invalidate` | Void the task |
| `due today` / `due tomorrow` / `due monday` | Set due date |
| `due 2026-03-15` | Set exact due date |
| `clear due` | Remove due date |
| `tag <name>` | Append `#name` tag to task |
| `untag <name>` | Remove `#name` tag from task |
| `list <name>` | Switch to a different Checkvist list |

### Action Palette (`Cmd+K`)

Press `Cmd+K` to open action search with autocomplete and keybind hints.

- Arrow keys move selection and auto-scroll.
- `Enter` applies selected action.
- `Esc` closes.

Common prompt shortcuts:

| Key | Action |
|-----|--------|
| `gt` | Open `tag ` prompt |
| `gu` | Open `untag ` prompt |
| `Shift+L` | Open `list ` prompt |

### Reordering & Structure

| Key | Action |
|-----|--------|
| `Cmd+↑` / `Cmd+↓` | Move task up / down among siblings |
| `Tab` (not in entry) | Indent task (make child of sibling above) |
| `Shift+Tab` | Unindent task |

### Other Shortcuts

| Key | Action |
|-----|--------|
| `dd` | Open due-date command |
| `gg` | Open first URL found in task content |
| `H` (Shift+h) | Toggle "Hide Future" filter (shows only today + overdue) |
| `u` | Undo last action (add, complete, edit) |
| `Fn+Delete` | Delete task (with confirmation prompt) |
| `/` | Focus search |

### Due Date Display

Due dates appear as color-coded badges on each task row:
- **Red** — overdue
- **Orange** — due today
- **Grey** — upcoming

### Global Hotkey

Configure a system-wide hotkey (default `⌥Space`) in Settings to open/close the popover from any application.

---

## Installation (Open Source Release)

Because this app is open-source and not signed with a paid Apple Developer certificate, macOS Gatekeeper will prevent it from running initially.

1. Download the latest `.dmg` from the [Releases page](https://github.com/yourusername/checkvist-focus/releases).
2. Open the DMG and drag `Checkvist Focus.app` to your **Applications** folder.
3. **Right-Click (or Control-Click)** on the app icon and select **"Open"**.
4. Click **"Open"** again in the warning dialog.

Or via Terminal:
```bash
xattr -cr /Applications/"Checkvist Focus.app"
```

## Configuration

Open **Settings** (right-click the menu bar icon → Settings):

1. **Username** — your Checkvist account email
2. **OpenAPI Key** — generate from Checkvist profile → Account → OpenAPI key
3. **List ID** — found in the Checkvist URL: `checkvist.com/checklists/123456` → `123456`

## Architecture

- **Swift 6** + **SwiftUI** for UI and state
- **AppKit** (`NSStatusItem`, `NSPanel`) for menu bar and keyboard monitoring
- **Combine** + `@Published` / `ObservableObject` for reactive state
- **Checkvist OpenAPI** via `URLSession` async/await
- **Keychain** for secure credential storage

## Build Requirements

- macOS 13.0+
- Xcode 14.0+

## License

MIT License.
