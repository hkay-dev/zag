---
title: Using ze
feature: editor
covers:
  - src/
  - scripts/bundle.sh
since: 2026-11-04
---

ze is a small text editor. A window shows one file at a time, with the text filling the page and
one line at the bottom. When you've opened a folder, a sidebar on the left lists its files. The
bottom line shows the file's name, a dot when there are unsaved changes, and the line and column
of the caret. It also turns into a prompt when you find, replace, jump to a line or open a file.

ze follows the Mac's light or dark setting unless you pick one, with a theme for each (see Themes). Things move
a little instead of jumping: the caret glides to each new spot and blinks with a soft fade after a
moment of rest, the band behind the caret's line slides after it, a new selection fades in, the
quick open list rises out of the bottom line, and the page eases into place when the keyboard
scrolls it. Scrolling with the trackpad or mouse follows your fingers exactly. Pull the trackpad
past the top or bottom of the file (or the left edge) and the page stretches with some resistance,
then springs back when you lift your fingers; momentum that hits an end overshoots a little and
settles. A mouse wheel stops at the ends. Windows in the background don't show a caret.

The window has no title bar, so the empty strip along its top stands in for one: drag it to move
the window, and double-click it to zoom (or minimize, or nothing, as Desktop & Dock's "Double-click
a window's title bar" setting says).

## Command palette

**View > Command Palette…** (⌘K) lists every command in ze's menus in the bottom line, the View
menu's first, each with its shortcut and a checkmark when it's on. Type a few letters, use ↑ and
↓ to pick, and press Return to run it, or Escape to close the list. Commands inside a submenu or
under a heading carry its name, like "Appearance: Dark" or "Dark Mode: Ayu Dark", so typing
`dark` finds them all.

## Open files

- From a terminal, `ze notes.txt` opens a file, and `ze .` opens a folder. A file that doesn't
  exist yet opens empty and is created when you save.
- **File > Open…** (⌘O) opens files or a folder.
- **File > Open Recent** lists the last 15 files you opened or saved. **Clear Menu** empties it.
- **File > Quick Open…** (⌘P) lists every file in ze's folder (see Sidebar). Type a few letters
  of the name, use ↑ and ↓ to pick, and press Return.
- Opening a file that's already open in another window brings that window forward. Quick open
  and the sidebar show the new file in the same window, which keeps the file it had (see Sidebar).
- A file opens where you left it: the caret and the scroll come back to where they were the last
  time you closed it.
- Files that look binary don't open.

## Sidebar

The left side of each window lists the files of ze's folder, folders first. That's the folder ze
started in from a terminal, or the one you opened last. Started from the Dock or Finder with no
folder from last time, it's your home folder. Files and folders whose names start with a dot are
left out. Each row has a small icon for its kind: folder, code, Markdown, data, image or plain
text. Names are in the Mac's system font and end in "…" when they don't fit.

- Click a folder to open or close it.
- Click a file to show it in the same window. The window keeps every file it has shown, with
  its unsaved changes and undo, so switching never asks you to save. A dot next to a file in the
  sidebar means it has unsaved changes.
- ⌘-click a file to open it in a new window.
- **View > Previous File** (⌃Tab) goes back to the file the window showed before.
- **View > Sidebar** (⌘\) shows or hides the sidebar in every window. It also hides when a window
  is too narrow to fit it beside the text.

The sidebar reads the disk again when you come back to ze, so new and deleted files show up.

## Pick up where you left off

When you quit ze with files open and later start it without naming a file (from the Dock, say),
it reopens those files in the same windows, at the same sizes and places, and brings back the
folder you had open. Each window comes back with the file it was showing, not the others it held.
Starting it with a file, like `ze notes.txt`, opens just that file. Close every window before
quitting and the next start gives you one empty window.

## Edit

Typing, selecting and moving work like other Mac text fields, including ⌥ and ⌘ with the arrow
keys, ⌥⌫ to delete a word, and the Control-key shortcuts (⌃A, ⌃E, ⌃K and the rest).

- Double-click selects a word and triple-click selects a line; drag after either to grow the
  selection by words or lines.
- Return keeps the line's indentation. Tab indents, or indents every selected line; ⇧Tab
  takes one level of indentation off.
- ⌘/ comments or uncomments the selected lines.
- ⌘Z and ⇧⌘Z undo and redo. A run of typing undoes as one step.
- Files with Windows line endings keep them.

### Brackets and quotes

Typing `(`, `[`, `{`, `"`, `'` or `` ` `` adds the closing one after the caret. Typing the closing
one when it's already next steps over it, and ⌫ between an empty pair deletes both. With text
selected, typing an opening one wraps the selection. A `'` right after a letter stays a single
apostrophe, so "don't" types normally.

**View > Auto-Close Brackets** turns this off and on. The checkmark shows when it's on.

## Soft wrap

**View > Soft Wrap** (⌥Z) wraps long lines at the window's edge instead of scrolling sideways.
Lines break after the last space that fits, or in the middle of a word that's wider than the
window. ↑ and ↓ move by screen rows, and ⌘← and ⌘→ go to the start and end of the row; ⌃A and
⌃E still go to the ends of the whole line. Resizing the window rewraps the text. The setting
applies to every window and is remembered.

## Find and replace

1. Press ⌘F. The prompt starts with the selected text or your last search.
2. Type: ze jumps to the first match and shows how many there are. Searching ignores case unless
   you type a capital letter.
3. Press Return for the next match, ⇧Return for the previous one, and Escape to close the prompt.

⌘G and ⇧⌘G find the next and previous match after the prompt is closed. ⌘L asks for a line
number and jumps to it.

To replace, press ⌥⌘F (**Edit > Find and Replace…**). The bottom line shows `find` and `with`.

- Type what to find, press Tab, and type what to put in its place. Tab goes back and forth.
- Return replaces the selected match and selects the next one.
- ⌥Return replaces every match in the file and closes the prompt. The bottom line says how many
  it replaced, and one ⌘Z puts them all back.

The replacement goes in exactly as typed.

## Changes from other apps

When another app changes a file that's open in ze, ze notices the next time you come back to it:

- If you haven't changed the file in ze, it reloads it and says "reloaded" in the bottom line.
  The caret stays put, and ⌘Z brings back the text from before the reload.
- If you have unsaved changes, ze asks whether to keep yours or reload the file.
- If the file was deleted, ze says "deleted on disk" and keeps the text as unsaved changes, so
  ⌘S writes it back.

## Save and close

⌘S saves and ⇧⌘S saves under a new name. ze writes the file next to the old one and then swaps
it in, so a crash halfway through a save never leaves a half-written file. The file keeps its
permissions.

Closing a window, or quitting, with unsaved changes asks whether to save them first. When a
window holds more than one unsaved file, one question covers them all: **Save All** saves each
one (asking for a name for any untitled file), **Don't Save** drops the changes, and **Cancel**
keeps the window open.

## Syntax colors

ze colors code by the file's extension, for Zig, C and its family (C++, Objective-C, Java,
Kotlin, C#), JavaScript and TypeScript, Python, Rust, Go, Swift, shell, Ruby, Lua, JSON, TOML,
YAML, INI, CSS and Markdown. Keywords are bold, and strings, comments and numbers each get a
color. In code, a word right before `(` takes the function color, a Capitalized word the type
color, and an ALL_CAPS word the number color. In data files, keys at the start of a line take the
function color and `[sections]` the keyword color. In Markdown, headings, list markers and
**strong** text take the keyword color, `code` and fenced blocks the string color, and links the
function color with their address dimmed. Other files are plain text.

## Themes

ze has a theme for light mode and one for dark mode. **View > Theme** picks the mode under
Appearance: Auto (the default) switches every window when the Mac switches, and Light or Dark keeps
ze in that mode whatever the Mac does. Below that it picks the themes: Paper (the default), Ayu Light
or One Light for light mode, and Ink (the default), Ayu Dark or One Dark for dark mode. Checkmarks
show the mode and the two themes in use. ze remembers them in the settings file.

## Font and text size

- **View > Font…** (⌘T) opens the Mac's Font panel. Pick any font; monospaced ones look best.
- **View > Bigger** (⌘=) and **Smaller** (⌘-) change the text size in every window, and
  **Actual Size** (⌘0) puts it back to 14.

ze remembers the font and size for next time.

## Settings

**ze > Settings…** (⌘,) opens ze's settings file in a ze window. It lists every setting with a
short note. Change a value and save, and every window picks it up at once. The file is
`~/.config/ze/settings`, so you can also edit it in another app; ze picks up the change when you
come back to it.

```text
font = system            # or a font's PostScript name, like Menlo-Regular
size = 14
line-height = 1.75       # as a multiple of the size
wrap = off
pairs = on               # auto-close brackets and quotes
sidebar = on             # the folder's files on the left
appearance = auto        # auto, light or dark
light-theme = paper      # paper, ayu-light, one-light, ink, ayu-dark or one-dark
dark-theme = ink
light.comment = #B3AEA3  # one color of the light theme, as #rrggbb
```

A `light.` or `dark.` line changes one color of that mode's theme, whichever theme it is. The
names are `background`, `text`, `muted` (the bottom line's fainter words), `keyword`, `string`,
`comment`, `number`, `function`, `type`, `selection`, `line` (the caret's line), `caret`, `match`
(other find matches), `panel` (the quick open list and the sidebar) and `rule` (the line above the
bottom line and the sidebar's edge).
Either mode can also use any theme from the file, so `light-theme = one-dark` keeps ze dark all
the time. A line ze doesn't understand is skipped, and a missing line keeps its default. The menus,
the size shortcuts and the Font panel rewrite their own line in the file and leave the rest of it
alone.
