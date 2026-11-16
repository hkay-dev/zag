# Zag

Zag is a text editor for Macs with Apple Silicon, written from scratch in Zig. Zag draws text with Core Text, reads and writes files through `libc`, and links only Apple's system frameworks (`AppKit`, `QuartzCore`, `CoreText`, `CoreGraphics`, `CoreFoundation`) and `libc`. The 0.1.0 executable is 436,560 bytes, and the disk image that you download is 366,969 bytes.

![Zag](docs/assets/zag-hero.png)

## What Zag does

- Open files in tabs, and split a window side by side (`⌘D`) or top and bottom (`⇧⌘D`). Drag a tab to move it or to split it into its own card. Press `⌘\` to show the open folder in a sidebar.
- Press `⌘P` to find a file in the open folder by typing part of its name, or `⌘K` to run any menu command from the keyboard.
- Press `⇧⌘M` to open a Markdown preview in a second window. The preview scrolls with the source and shows lists, code blocks, links and tables.
- Turn on typewriter scrolling, focus dimming by line, sentence or paragraph, Zen Mode (`⌃⌘Z`) or Late-Night Focus (`⌃⌘N`) when you write prose.
- Zag highlights syntax in 25 languages and file formats. [CHANGELOG.md](CHANGELOG.md) lists them.
- Zag animates the caret, the tab and sidebar highlights, split folds and theme changes.
- When you save, Zag writes a temporary file next to the original, copies the original's permissions, extended attributes and Finder tags, calls `fsync` and swaps the two files. Zag autosaves untitled tabs to `~/Library/Application Support/zag/Drafts` and reopens your windows and tabs the next time you start it.

## Install

Zag needs macOS 15 (Sequoia) or newer on Apple Silicon.

1. Download `Zag-0.1.0-arm64.dmg` from the [latest release](https://github.com/hkay-dev/zag/releases/latest).
2. Open the disk image and drag Zag into Applications.
3. Apple hasn't notarized this build, so macOS may refuse to open it the first time. If that happens, run these two commands once in Terminal.

```sh
xattr -dr com.apple.quarantine /Applications/Zag.app
open /Applications/Zag.app
```

## Build from source

You need Zig 0.17.0 or newer and the Xcode Command Line Tools. `scripts/bundle.sh` compiles the app icon with `xcrun actool`, which comes with the full Xcode.

```sh
# Build the release binary at zig-out/bin/zag
zig build --release

# Run the tests
zig build test

# Build zig-out/Zag.app
./scripts/bundle.sh stable

# Build the disk image at zig-out/Zag-0.1.0-arm64.dmg
./scripts/dmg.sh
```

`bundle.sh` and `dmg.sh` sign the app with an ad-hoc signature. To sign it with your own certificate, set `CODESIGN_IDENTITY`.

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/dmg.sh
```

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New tab / New window | `⌘T` / `⌘N` |
| Open file or folder | `⌘O` |
| Quick Open file in folder | `⌘P` |
| Command Palette | `⌘K` |
| Save / Save As | `⌘S` / `⇧⌘S` |
| Close tab / Close window | `⌘W` / `⇧⌘W` |
| Split right / Split down | `⌘D` / `⇧⌘D` |
| Focus card left / right | `⌥⌘←` / `⌥⌘→` |
| Previous / next tab | `⇧⌘[` / `⇧⌘]` (or `⌃⇧⇥` / `⌃⇥`) |
| Toggle sidebar | `⌘\` |
| Find / Find and Replace | `⌘F` / `⌥⌘F` |
| Go to Line | `⌘L` |
| Toggle Comment | `⌘/` |
| Format JSON | `⌥⌘J` |
| Soft Wrap | `⌥Z` |
| Markdown Preview | `⇧⌘M` |
| Zen Mode / Late-Night Focus | `⌃⌘Z` / `⌃⌘N` |
| Font panel / Bigger / Smaller / Actual Size | `⇧⌘T` / `⌘=` / `⌘-` / `⌘0` |
| Settings (`config.toml`) | `⌘,` |

## Settings and themes

Press `⌘,` to open `~/.config/zag/config.toml` in Zag. Zag watches that file and applies each save to every open window.

The light themes are Paper (the default), Ayu Light, One Light, Solarized Light and Gruvbox Light. The dark themes are Ink (the default), Ayu Dark, One Dark, Solarized Dark, Gruvbox Dark and Black. To change one color in a theme, set `light.<slot> = "#RRGGBB"` or `dark.<slot> = "#RRGGBB"`.

The [user guide](docs/guide/index.md) covers every command and setting. [tiny-binary.md](docs/decisions/tiny-binary.md) lists the choices behind the binary's size, and [motion.md](docs/decisions/motion.md) describes how Zag animates.

## Credits

[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) credits Zikky and the color palettes that Zag's themes borrow from.

## License

MIT. See [LICENSE](LICENSE).
