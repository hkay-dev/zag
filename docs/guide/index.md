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
line and column of the caret. It also turns into a prompt when you find, jump to a line or open a
file.

ze follows the Mac's light or dark setting: warm paper in light mode, ink in dark mode. The caret
glides to each new spot, and after a moment of rest it blinks with a soft fade. Windows in the
background don't show a caret.

## Open files

- From a terminal, `ze notes.txt` opens a file, and `ze .` opens a folder. A file that doesn't
  exist yet opens empty and is created when you save.
- **File > Open…** (⌘O) opens files or a folder.
- **File > Quick Open…** (⌘P) lists every file in the folder ze started in, or the folder you
  opened. Type a few letters of the name, use ↑ and ↓ to pick, and press Return. If there's no
  folder yet, it lists the folder of the file you're looking at.
- Opening a file that's already open brings its window forward. Quick open shows the new file in
  the same window when that window has no unsaved changes.
- Files that look binary don't open.

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

## Find and go to a line

1. Press ⌘F. The prompt starts with the selected text or your last search.
2. Type: ze jumps to the first match and shows how many there are. Searching ignores case unless
   you type a capital letter.
3. Press Return for the next match, ⇧Return for the previous one, and Escape to close the prompt.

⌘G and ⇧⌘G find the next and previous match after the prompt is closed. ⌘L asks for a line
number and jumps to it.

## Save and close

⌘S saves and ⇧⌘S saves under a new name. ze writes the file next to the old one and then swaps
it in, so a crash halfway through a save never leaves a half-written file. The file keeps its
permissions.

Closing a window, or quitting, with unsaved changes asks whether to save them first.

## Text size

**View > Bigger** (⌘=) and **Smaller** (⌘-) change the text size in every window, and
**Actual Size** (⌘0) puts it back.
