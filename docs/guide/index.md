---
type: guide
summary: Opening, editing and reading files in Zag.
title: Using Zag
feature: editor
covers:
  - src/
  - scripts/bundle.sh
since: 2026-11-04
---

Zag is a small text editor. A window shows files on cards with rounded corners that sit a little
in from the window's edges. A window starts with one card and can split into more, side by side
or stacked (see Cards), and each card keeps the files you open in it as tabs.
When you've opened a folder, a sidebar on the left lists its files. With one file, the card's
header shows the file's icon, its name, a dot when there are unsaved changes, and its folder
inside the open folder, with small arrows between folders (a file directly in the open folder
shows none; outside it the path starts at ~).
With more, it shows tabs instead (see Tabs). When you find, replace, jump to a line or open a
file, a prompt line opens at the bottom of the card.

Zag follows the Mac's light or dark setting unless you pick one, with a theme for each (see Themes). Things move
a little instead of jumping: the caret glides to each new spot, a little longer for a long jump,
and holds solid for a moment before it fades out and back in, the band behind the caret's line
slides after it, a new selection fades in and one you leave (by clicking or moving the caret) fades out, the quick open list rises out of the prompt line, and
the prompt line itself slides up from the bottom of the card, its words a moment behind. The page
eases into place when the keyboard scrolls it. Scrolling with the trackpad or mouse follows your
fingers exactly and stops at the ends, with no stretch past them. The bottom end leaves three
blank lines under the last line. Windows in the background don't show a caret, their
sidebar highlight fades and their header dims. The mouse pointer hides while you type and
comes back when you move the mouse. The sidebar's highlight and the picked row in the quick open
list hop to their new row with a little bounce, and the buttons by the traffic lights and the
tabs' **+** light up under the mouse, with a round fill that fades after a click.

A card with no file open shows the shortcuts for quick open, open and the command palette,
fading in after a moment and out when you start something.

A thin scroll bar shows on the right edge of the text while the page scrolls, with its knob
sized and placed by how much of the file is in view. It fades in quickly and fades out a second
after it stops. A file that fits in the window never shows one.

Zag doesn't follow the Mac's Reduce Motion setting: things move the same way with it on.

Right-click (or control-click) in the text for **Cut**, **Copy**, **Paste**, **Select All** and
**Toggle Comment**, the same commands as the Edit menu.

The window has no title bar of its own. The traffic lights sit at the top of the sidebar, in line
with the header, next to a sidebar button that shows or hides the sidebar and a **+** button
at the sidebar's right that opens a new tab; hover either for its name. With the sidebar hidden, the traffic lights and
the sidebar button sit on the header. A folder too long for the header or the sidebar's top line
loses its start to "…", keeping the folders nearest the file. Drag the header or the empty band
above the sidebar to move the window, and double-click it to zoom (or minimize, or nothing, as
Desktop & Dock's "Double-click a window's title bar" setting says).

## Command palette

**View > Command Palette…** (⌘K) lists every command in Zag's menus above the prompt line, the View
menu's first. The list is an inset rounded panel with a soft shadow above it, set in the Mac's
system font like a menu. Each command has its shortcut on the right, lined up like the Mac's
menus, and a checkmark in a column on the left when it's on. The picked row has the same soft
fill as the sidebar's selection, and the first rows slide in one after another when the list
opens. Quick open looks the same. Type a few letters, use ↑ and
↓ to pick, and press Return to run it, or Escape to close the list. Commands inside a submenu or
under a heading carry its name in gray, like "Appearance: Dark" or "Dark Mode: Ayu Dark", so
typing `dark` finds them all.

The Mac's own menu search works too: press ⇧⌘/ (or open the **Help** menu) and type, and macOS
points at the matching command in its menu. Press Return to run it.

## Markdown preview

**View > Markdown Preview** (⇧⌘M), also in ⌘K, opens a read-only preview in a separate
window, titled with the file's name and "Preview", with the file's icon in the title bar. The
window has the same page color as the editor, grey in Zen and stronger with the Mac's Increase
Contrast setting, and the text sits in a centered column no wider
than 680 points. Run it again to close it. Keep typing in the editor: the preview updates after a
short pause without jumping back to the top. It stays with the file it was opened for when you
switch tabs or cards, and closes with its window. Other text files can be previewed too, using
the same Markdown rules. The preview window remembers where you left it and how big it was, and
opens there next time. Links are tinted and underlined.

## Open files

- From a terminal, `zag notes.txt` opens a file, and `zag .` opens a folder. A file that doesn't
  exist yet opens empty and is created when you save.
- **File > Open…** (⌘O) opens files or a folder.
- Drop files or a folder from Finder onto a window, or onto Zag's Dock icon, to open them. A blank
  window takes the first file; the rest, and any file after that, open in new windows.
- **File > Open Recent** lists the last 15 files you opened or saved. **Clear Menu** empties it.
- **File > Quick Open…** (⌘P) lists every file in Zag's folder (see Sidebar). Type a few letters
  of the name, use ↑ and ↓ to pick, and press Return.
- Opening a file that's already open in another window or card brings it forward. Quick open
  and the sidebar show the new file in a new tab of the focused card, right of the one on show
  (see Tabs).
- A file opens where you left it: the caret and the scroll come back to where they were the last
  time you closed it.
- Files that look binary don't open.

## Tabs

Every file a window has shown stays in it as a tab, with its unsaved changes and undo, so
switching never asks you to save. With one file the header is just its name and folder. Open a
second and the header turns into a row of tabs: the name becomes the first tab, the new one pops
in beside it with a little bounce, and a **+** shows after the last one. The active tab's name is
in medium weight and full strength, the others lighter; switching fades the text in without
moving it, and tabs keep their widths.

- Click a tab to show its file. The active tab's highlight hops over to it.
- The active tab, and any tab under the mouse, shows a **×** that closes it. A tab with unsaved
  changes shows a dot there instead until you point at it. The dot grows in with a little bounce
  when you first change the file and shrinks away as the **×** comes back when you save. Closing
  one folds it shut and the tabs after it slide over.
- **File > New Tab** (⌘T) or the **+** opens an untitled file in a new tab. It stays open, even
  while it's empty, until you close it. Its tab and the window take their name from its first
  line of text once you pause typing, or at once when you press Return, and it's "Untitled" while
  it has none.
- **File > Close Tab** (⌘W) closes the tab on show, asking first when it has unsaved changes. The
  tab to its right takes its place. Closing the last tab folds its card away, or closes the
  window when it's the only card.
- **File > Close Window** (⇧⌘W) closes the window and all its tabs.
- **View > Show Next Tab** (⌃Tab) and **Show Previous Tab** (⌃⇧Tab) step through the tabs and go
  around at the ends.
- Drag a tab along the row to move it. The tabs it passes slide out of its way, and it springs
  into its place when you let go.
- Right-click (or control-click) a tab, or a card's lone file name, for **Close Tab**, **Close
  Other Tabs**, **Close Tabs to the Right**, **Split Right** and **Split Down** (which move the tab
  into a new card beside or below), **Reveal in Finder** and **Copy Path**. The tab keeps a faint
  tinted outline in the caret's color while the menu is open, fading in and out. Closing several
  tabs asks about each one with unsaved changes, and **Cancel** stops there.

When the tabs don't fit, they all get narrower and their names end in "…". Past that, the row
scrolls to keep the active tab in view. Drag the header between and around the tabs to move the
window.

## Cards

A window can hold several cards, each with its own tabs, split side by side or stacked. One card
has the focus: typing, saving and the File menu act on it, and the window's title follows its
file. With more than one card, the focused card has a thin ring in the caret's color, and the
others hide their caret and dim their header.

- **View > Split Right** (⌘D) and **Split Down** (⇧⌘D) split the focused card in two. The new
  card springs open beside or below it and takes the tab on show. A card with only one tab keeps
  it, and the new card starts with quick open so you can pick a file for it.
- Click a card to focus it. **View > Next Card** (⌘]) and **Previous Card** (⌘[) step through
  them and go around at the ends.
- Drag the gap between two cards to resize them. Neither gets narrower than 220 points or shorter
  than 140. The split snaps to halves and thirds when you come within a few points of them, with
  a tap on a trackpad. Pull past a limit and the gap stretches a little, then springs back when
  you let go. ⌘D shakes the card and beeps when the focused card has no room to split.
- Closing a card's last tab folds the card away, and its neighbor springs over to fill the room.
- Drag a tab to another card to move it there. Over the other card's tabs, they slide apart to
  show where it goes; over the card itself, it joins that card's tabs. Near a card's left, right,
  top or bottom edge, a preview of half the card shows, and dropping there splits the card and
  puts the tab in the new half. That works on the tab's own card too, when it has other tabs.
  With more than one card, a card's lone file name drags the same way, and its card folds away
  once the file leaves.

## Sidebar

The left side of each window lists the files of Zag's folder, folders first. That's the folder Zag
started in from a terminal, or the one you opened last. Started from the Dock or Finder with no
folder from last time, it's your home folder. The sidebar sits on the Mac's own translucent
sidebar material, and the cards' chrome lets a little of it show through. At the top, the
folder's own name shows in bold with a small arrow. Click it for a menu of the folder and the
folders above it; pick one to show it in Finder. Files and folders whose names start with a dot
are left out. Files have the Mac's own icon for their kind, the same ones Finder shows, and
folders have a small tinted folder. Names are in the Mac's system font and end in "…" when they
don't fit. The file on show in the focused card is marked with a soft rounded fill and its name
is in bold; when the selection moves, the bold fades from the old name to the new one. A fainter
highlight follows the mouse down the list, sliding from row to row without a bounce, and fades
out when the mouse leaves. It stays on the row under a still mouse when a folder opens or
closes and when tabs slide, so a tab that moves under the mouse lights up too.

The folder's name stays pinned at the top while the rows scroll. An open folder whose
files fill the top of the list pins under the name too, up to three levels deep, until the next
folder's row pushes it away. Click a pinned folder to scroll back to it. The list stops a little
above the window's bottom edge, level with the cards, and when more rows sit below, the last few
points fade out.

- Click a folder to open or close it. Its files fade in or out while the rows below slide to make
  room, and its arrow turns. Clicking another row while a folder is closing doesn't make the list
  jump.
- Click a file to show it in a new tab, where its text fades in. A dot next to a file in the
  sidebar means it has unsaved changes.
- ⌘-click a file to open it in a new window.
- Drag a file onto a card's tabs to open it there as a new tab: the tabs slide apart to show
  where it goes. Drag it over a card's text to open it in a new card split off that card's nearest
  edge, with a preview of the half it takes. A copy of the file's name follows the mouse while its
  row dims. A file already open in the window moves there instead. Let go where it can't land and
  the copy slides back to its row.
- Right-click (or control-click) a file for **Open in New Tab**, **Open in New Split** (beside the
  focused card, or below it when there's no room beside), **Open in New Window**, **Reveal in
  Finder** and **Copy Path**. A folder has the last two. The row keeps a faint tinted outline in
  the caret's color while the menu is open, apart from the highlight on the file on show.
- **View > Show Next Tab** (⌃Tab) and **Show Previous Tab** (⌃⇧Tab) step through the window's
  tabs.
- **View > Sidebar** (⌘\) or the sidebar button by the traffic lights shows or hides the sidebar
  in every window. It slides in and out, and the text's card follows its edge. It also hides when
  a window is too narrow to fit it beside the text.
- Drag the sidebar's right edge to make it wider or narrower, from 150 to 500 points. Every
  window follows, and new windows and the next start use the width you left it at. Past either
  limit the edge stretches a little with some resistance, gives a tap on a trackpad where it
  stops, and springs back when you let go. Drag it in below 100 points and the sidebar slides
  shut; show it again and it has the width it had.

The sidebar reads the disk again when you come back to Zag, so new and deleted files show up.

## Pick up where you left off

When you quit Zag with files open and later start it without naming a file (from the Dock, say),
it reopens those files in the same windows, at the same sizes and places, and brings back the
folder you had open. Each window comes back with its cards in the same places and sizes, each
with its tabs in order and the same tab on show. A file that's gone drops out of its card.
Starting it with a file, like `zag notes.txt`, opens just that file. Close every window before
quitting and the next start gives you one empty window.

### Drafts

An untitled file saves itself as a draft a second after you stop typing, so there's no need to
save a scratchpad. It shows no unsaved dot, quitting doesn't ask about it, and it comes back in
its tab next time. If Zag ever stops without quitting, its drafts come back as tabs in the front
window at the next start, even when that start opens other files. Saving it to a file with ⌘S,
or closing its tab and choosing **Don't Save**, deletes the draft. Drafts live in
`~/Library/Application Support/ze/Drafts`.

## Edit

Typing, selecting and moving work like other Mac text fields, including ⌥ and ⌘ with the arrow
keys, ⌥⌫ to delete a word, and the Control-key shortcuts (⌃A, ⌃E, ⌃K and the rest).

- Double-click selects a word and triple-click selects a line; drag after either to grow the
  selection by words or lines.
- A selection has a clear tint of its own (the caret's color on Paper and Ink, blue on the Ayu
  and One themes), so it stands apart from the band on the caret's line, which stays put while
  you select.
- Return keeps the line's indentation. Tab indents, or indents every selected line; ⇧Tab
  takes one level of indentation off.
- ⌘/ comments or uncomments the selected lines.
- ⌘Z and ⇧⌘Z undo and redo. A run of typing undoes as one step.
- Undo, redo, Replace All and big pastes (several lines, or over 40 characters) flash the text
  they changed. The flash fades out, and your next keypress clears it.
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

## Focus

**View > Focus** keeps the caret's range bright and fades the rest toward the page color:
**Off**, **Line** (the whole logical line, including wrapped rows), **Sentence** or **Paragraph**.
A sentence ends at `.`, `!` or `?`; a paragraph sits between blank lines. When the caret moves to
another range, the old range fades out and the new one fades in, evenly and all at once, while
selected text and the caret keep their normal colors. The choice applies
to every window and is remembered.

## Typewriter scrolling

**View > Typewriter Scrolling** keeps the caret's row halfway down the card. Moving the caret or
typing glides the page instead, even at the start and end of a file, where blank space fills the
card above the first line or below the last. Scrolling with the mouse or trackpad is still free;
the next caret move brings the row back to the middle. It works with soft wrap and Focus too.
The choice applies to every window and is remembered.

## Zen mode

**View > Zen Mode** (⌃⌘Z) fades out the traffic lights, the cards' headers and outlines, covers
the sidebar, turns the theme grey, and pads the text so an 80-column page sits in the middle of
the window. They all fade together over about half a second.
The text stays left-aligned and wraps at 80 columns, or at the window's edge when the window is
narrower. With split cards, each card centers its own page. Find, go to line, quick open and the
command palette still open their prompt line at the bottom. Drag the empty strip at the top to
move the window. Turn Zen Mode off to bring the window back as it was. The choice applies to
every window and is remembered; your sidebar, wrap and theme settings don't change.

## Status bar

A thin strip along the bottom of each card, at its right, shows where the caret is as "Ln 120,
Col 14". Both count from 1, and the column counts characters, so an accented letter or an emoji
is one. While text is selected it adds how much, like "48 characters, 3 lines". For plain text
and Markdown files (and files that aren't saved yet) it also shows the words, like "1,204 words":
runs of text between spaces, counted again only when the text changes. A card that isn't the
focused one shows its own, a little dimmer. The prompt line covers the strip while it's open, and
Zen Mode hides it. There's no setting for it.

## Find and replace

1. Press ⌘F. The prompt starts with the selected text or your last search.
2. Type: Zag jumps to the first match and shows how many there are. Searching ignores case unless
   you type a capital letter. If nothing matches, the words shake.
3. Press Return for the next match, ⇧Return for the previous one, and Escape to close the prompt.

The match you're on is a bright yellow pill that pops when you jump to it, and the other matches
are softer, rounded pills. When the prompt opens on text you'd selected, the other matches fade in
outward from the one you're on. ⌘G and ⇧⌘G find the next and previous match after the prompt is
closed, and they pop the match too. ⌘L asks for a line number and jumps to it.

To replace, press ⌥⌘F (**Edit > Find and Replace…**). The prompt line shows `find` and `with`.

- Type what to find, press Tab, and type what to put in its place. Tab goes back and forth.
- Return replaces the selected match and selects the next one.
- ⌥Return replaces every match in the file and closes the prompt. The header says how many
  it replaced, and one ⌘Z puts them all back.

The replacement goes in exactly as typed.

## Changes from other apps

When another app changes a file that's open in Zag, Zag notices the next time you come back to it:

- If you haven't changed the file in Zag, it reloads it and says "reloaded" in the header.
  The caret stays put, and ⌘Z brings back the text from before the reload.
- If you have unsaved changes, Zag asks whether to keep yours or reload the file.
- If the file was deleted, Zag says "deleted on disk" and keeps the text as unsaved changes, so
  ⌘S writes it back.

## Save and close

⌘S saves and ⇧⌘S saves under a new name. Zag writes the file next to the old one and then swaps
it in, so a crash halfway through a save never leaves a half-written file. The file keeps its
permissions.

Closing a window with unsaved changes, or quitting with unsaved changes to files, asks whether to
save them first. Closing also asks about untitled files with text in them, since their drafts go
with the window; quitting keeps the drafts instead (see Drafts). When a window holds more than
one of these in its tabs, one question covers them all: **Save All** saves each one (asking for a
name for any untitled file), **Don't Save** drops the changes, and **Cancel** keeps the window
open.

## VoiceOver

VoiceOver reads each card's text, line by line, and follows the caret and the selection as they
move. It can move the caret, select text and switch between cards. Tabs show up as a group of
tabs when a card has two or more, and pressing one switches to it. The sidebar is an outline
named after the folder: each row says its name, how deep it is, whether a folder is open and
whether it's selected. Pressing a folder opens or closes it, and pressing a file opens it in the
focused card. With soft wrap on, VoiceOver still reads a whole line at a time. VoiceOver doesn't
see the find, replace or quick open prompts, but it keeps reading the card's text while one is
open.

## Syntax colors

Zag colors code by the file's extension, for Zig, C and its family (C++, Objective-C, Java,
Kotlin, C#), JavaScript and TypeScript, Python, Rust, Go, Swift, shell, Ruby, Lua, JSON, TOML,
YAML, INI, CSS and Markdown. Keywords are bold, and strings, comments and numbers each get a
color. In code, a word right before `(` takes the function color, a Capitalized word the type
color, and an ALL_CAPS word the number color. In data files, keys at the start of a line take the
function color and `[sections]` the keyword color. In Markdown, headings, list markers and
**strong** text take the keyword color, `code` and fenced blocks the string color, and links the
function color with their address dimmed. Other files are plain text.

## Themes

Zag has a theme for light mode and one for dark mode. **View > Theme** picks the mode under
Appearance: Auto (the default) switches every window when the Mac switches, and Light or Dark keeps
Zag in that mode whatever the Mac does. Below that it picks the themes: Paper (the default), Ayu Light
or One Light for light mode, and Ink (the default), Ayu Dark or One Dark for dark mode. Checkmarks
show the mode and the two themes in use. Zag remembers them in the settings file.
Zen Mode turns every theme color grey while it's on, without changing the saved colors.
Switching themes, or the Mac's light and dark setting, fades over a quarter of a second. Gray
text in every theme is dark enough to read comfortably. With **Increase contrast** on in System
Settings > Accessibility > Display, Zag strengthens the card outlines, the sidebar's selection,
hover highlight and the line under its pinned folders, the tabs' highlights and the gray text,
and follows the setting the moment you change it.

## Font and text size

- **View > Font…** (⇧⌘T) opens the Mac's Font panel. Pick any font; monospaced ones look best.
- **View > Bigger** (⌘=) and **Smaller** (⌘-) change the text size in every window, and
  **Actual Size** (⌘0) puts it back to 14.

Zag remembers the font and size for next time.

## Settings

**Zag > Settings…** (⌘,) opens Zag's settings file in a Zag window. It lists every setting with a
short note. Change a value and save, and every window picks it up at once. The file is
`~/.config/ze/settings`, so you can also edit it in another app; Zag picks up the change when you
come back to it.

```text
font = system            # or a font's PostScript name, like Menlo-Regular
size = 14
line-height = 1.75       # as a multiple of the size
wrap = off
pairs = on               # auto-close brackets and quotes
focus = off              # off, line, sentence or paragraph
typewriter = off         # keep the caret's row in the middle
zen = off                # hide the chrome and center an 80-column grey page
sidebar = on             # the folder's files on the left
sidebar-width = 250      # in points, from 150 to 500
appearance = auto        # auto, light or dark
light-theme = paper      # paper, ayu-light, one-light, ink, ayu-dark or one-dark
dark-theme = ink
light.comment = #B3AEA3  # one color of the light theme, as #rrggbb
```

A `light.` or `dark.` line changes one color of that mode's theme, whichever theme it is. The
names are `background` (the card; the window around it is a step darker), `text`, `muted` (the
header's fainter words), `keyword`, `string`, `comment`, `number`, `function`, `type`,
`selection`, `line` (the caret's line), `caret`, `match` (other find matches), `panel` (the quick
open list), `rule` (the line under the header and above the prompt line and the quick open list)
and `header` (the card's header, a step lighter than the text on dark themes and a few steps
darker on light ones, so it stands apart from the text).
Either mode can also use any theme from the file, so `light-theme = one-dark` keeps Zag dark all
the time. A line Zag doesn't understand is skipped, and a missing line keeps its default. The menus,
the size shortcuts and the Font panel rewrite their own line in the file and leave the rest of it
alone.
