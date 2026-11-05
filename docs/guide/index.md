---
title: Using ze
feature: editor
covers:
  - src/
  - scripts/bundle.sh
since: 2026-11-04
---

ze is a small text editor. Each file gets its own window, with the text filling the page and one
line at the bottom. That line shows the file's name, a dot when there are unsaved changes, and the
line and column of the caret. It also turns into a prompt when you find, replace, jump to a line or
open a file.

ze follows the Mac's light or dark setting: warm paper in light mode, ink in dark mode. Things move
a little instead of jumping: the caret glides to each new spot and blinks with a soft fade after a
moment of rest, the band behind the caret's line slides after it, a new selection fades in, the
quick open list rises out of the bottom line, and the page eases into place when the keyboard
scrolls it. Scrolling with the trackpad or mouse follows your fingers exactly. Windows in the
background don't show a caret.

## Open files

- From a terminal, `ze notes.txt` opens a file, and `ze .` opens a folder. A file that doesn't
  exist yet opens empty and is created when you save.
- **File > Open…** (⌘O) opens files or a folder.
- **File > Open Recent** lists the last 15 files you opened or saved. **Clear Menu** empties it.
- **File > Quick Open…** (⌘P) lists every file in the folder ze started in, or the folder you
  opened. Type a few letters of the name, use ↑ and ↓ to pick, and press Return. If there's no
  folder yet, it lists the folder of the file you're looking at.
- Opening a file that's already open brings its window forward. Quick open shows the new file in
  the same window when that window has no unsaved changes.
- A file opens where you left it: the caret and the scroll come back to where they were the last
  time you closed it.
- Files that look binary don't open.

## Pick up where you left off

When you quit ze with files open and later start it without naming a file (from the Dock, say),
it reopens those files in the same windows, at the same sizes and places. Starting it with a file,
like `ze notes.txt`, opens just that file. Close every window before quitting and the next start
gives you one empty window.

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

Closing a window, or quitting, with unsaved changes asks whether to save them first.

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
light.comment = #B3AEA3  # colors as #rrggbb
dark.caret = #FF8A3D
```

Colors come in a light set and a dark set, with these names: `background`, `text`, `muted` (the
bottom line's fainter words), `keyword`, `string`, `comment`, `number`, `selection`, `line` (the
caret's line), `caret`, `match` (other find matches), `panel` (the quick open list) and `rule`
(the line above the bottom line). A line ze doesn't understand is skipped, and a missing line
keeps its default. The menu toggles, the size shortcuts and the Font panel rewrite their own line
in the file and leave the rest of it alone.
