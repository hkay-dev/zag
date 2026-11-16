# Changelog

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
