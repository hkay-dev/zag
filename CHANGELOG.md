# Changelog

## 0.1.1 (2026-11-16)

This release strengthens file saving, draft recovery, and editing, and reduces repeated work during drawing and navigation.

### Saved work

- Zag checkpoints drafts before quitting and pauses quit when a checkpoint fails.
- Duplicate Tab and Show Changes snapshots restore with the next session.
- Tab moves preserve unsaved text when Zag runs short of memory.
- Save As protects the saved file when its destination matches a draft’s backing file.
- File saves check replacement identity and preserve permissions, extended attributes, and ACLs. External-change detection also checks replacements that share a file’s size and timestamp.
- Session saving prepares every window before writing the session, and restores paths that contain tabs.
- Settings changes merge into edited configuration tabs across windows. Reset Settings puts a backup in Trash.

### Editing and navigation

- Editing, undo, and redo preserve text and history when memory allocation fails.
- Delete Line handles the last terminated line correctly. Cursor movement, deletion, and Find respect character boundaries around malformed UTF-8.
- Syntax highlighting handles multiline HTML attributes, Markdown fences, unfinished strings, and language-specific hash comments.
- Quick Open scans new folders in the background and refreshes after hidden-file changes.
- Sidebar and picker clicks follow the rows as they animate. Folder folds preserve their target through directory refreshes.
- Markdown Preview updates relative links after Save As and supports navigation through documents with more than 256 headings.

### Less repeated work

- Zag reuses syntax colors, wrapped-line indentation, caret-row calculations, and preview colors between draws.
- Find markers calculate row positions directly. Horizontal scrolling uses displayed columns for tabbed text.
- Sidebar highlights finish their animation when the sidebar closes.

## 0.1.0 (2026-11-15)

First public open-source release of Zag for macOS 15+ on Apple Silicon.

### Features

- Native `AppKit`, `CoreGraphics`, and `CoreText` editor in a 436,560-byte executable (about 426 KiB) with zero external dependencies.
- Rounded editor cards with horizontal and vertical splits (`⌘D`, `⇧⌘D`), draggable tabs, and a collapsible folder sidebar (`⌘\`).
- Fuzzy Quick Open (`⌘P`), Command Palette (`⌘K`), Go to Line (`⌘L`), and incremental Find and Replace (`⌘F`, `⌥⌘F`).
- Built-in syntax highlighting for Zig, C/C++/Objective-C, Java, Kotlin, C#, JavaScript/TypeScript, Python, Rust, Go, Swift, Shell, Fish, Ruby, Lua, SQL, PHP, Dart, Diff, JSON/JSONL, TOML, YAML, INI, CSS, HTML/XML/SVG, and Markdown.
- Live Markdown Preview window (`⇧⌘M`) with tables, relative link resolution, code blocks, and scroll sync.
- Built-in JSON formatter (`⌥⌘J`), auto-closing bracket and quote pairs, line commenting (`⌘/`), and CRLF/LF preservation.
- Paper, Ayu Light, One Light, Solarized Light, Gruvbox Light, Ink, Ayu Dark, One Dark, Solarized Dark, Gruvbox Dark, and Black themes with live-reloading `~/.config/zag/config.toml` overrides, Zen Mode (`⌃⌘Z`), Typewriter Scrolling, Focus dimming, and Late-Night Focus (`⌃⌘N`).
- Atomic file saves that preserve POSIX modes, extended attributes, and ACLs, external modification detection, session window/tab restoration, and background untitled draft autosaving.
- Standalone `scripts/dmg.sh` installer builder producing a compressed `Zag-0.1.0-arm64.dmg`.
