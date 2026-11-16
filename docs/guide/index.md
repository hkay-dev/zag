---
type: guide
summary: Opening, editing and reading files in Zag.
title: Using Zag
feature: editor
covers:
  - src/
  - scripts/bundle.sh
since: 2026-11-04
related:
  - zag#c325
  - zag#56et
  - zag#t8as
---

Zag is a small text editor. A window shows files on cards with rounded corners, set a little in
from the window's edges. A window starts with one card and can split into more, side by side or
stacked (see Cards), and each card shows the files you open in it as tabs. When you've opened a
folder, a sidebar on the left lists its files. With one file, the card's header shows the file's
icon, its name, a dot when there are unsaved changes, and its folder inside the open folder, with
small arrows between folders (a file directly in the open folder shows none; outside it the path
starts at ~). With more, the header shows tabs instead (see Tabs). When you find, replace, jump to
a line or open a file, a prompt line opens at the bottom of the card.

Zag follows the Mac's light or dark setting unless you pick one, with a theme for each (see
Themes). Things move a little instead of jumping: the caret glides to each new spot, a little
longer for a long jump, and shows solid for a moment before it fades out and back in. The band
behind the caret's line slides after it, a new selection fades in and one you leave (by clicking
or moving the caret) fades out, the quick open list rises out of the prompt line, and the prompt
line itself slides up from the bottom of the card, its words a moment behind. The page eases into
place when the keyboard scrolls it. Scrolling with the trackpad follows your fingers exactly, a
mouse wheel's clicks glide, and both stop at the ends, with no stretch past them. The bottom end
leaves three blank lines under the last line. The mouse pointer hides while you type and comes
back when you move the mouse. The sidebar's highlight and the picked row in the quick open list
hop to their new row with a little bounce, and the buttons by the traffic lights and the tabs'
**+** light up under the mouse, with a round fill that fades after a click.

Only the focused card of the front window has the keys. Every other card, in that window or a
window behind it, shows its caret as a dim hollow box that doesn't blink, and a window in the
background fades its sidebar highlight and dims its header.

Short notes, like "saved" or "reloaded", rise into a pill near the bottom of the window. Each one
fades in, shows for two seconds and fades out, and a new note replaces the one on show.

A card with no file open lists **Quick Open**, **Open** and **Commands** with their shortcuts,
then "or drop files and folders here", then up to five recent files and three recent folders
with their folders beside them. Each line is a button: click it to run the command or open the
file or folder. The list fades in after a moment and out when you start something.

Thin scroll bars show along the right edge of the text, and along the bottom when a long line
runs past the card, with each knob sized and placed by how much of the file is in view. They fade
in quickly while the page scrolls or when the mouse comes near that edge, and fade out a second
after both stop. Drag a knob to scroll, or click the track to glide the page there. A file that
fits in the card never shows one.

Zag doesn't follow the Mac's Reduce Motion setting: things move the same way with it on.

Right-click (or control-click) in the text for **Undo**, **Redo**, **Cut**, **Copy**, **Paste**,
**Select All**, **Find Selection**, **Toggle Comment**, **Format JSON**, **Split Right** and
**Split Down**. A right-click outside the selection moves the caret there first, so the command
acts where you clicked.

The window has no title bar of its own. The traffic lights appear at the top of the sidebar, in
line with the header, next to a sidebar button that shows or hides the sidebar and a **+**
button at the sidebar's right that opens a new tab; hover either for its name and shortcut. With
the sidebar hidden, the traffic lights and the sidebar button move onto the header. When a window
is too narrow to show the sidebar, the sidebar button dims and its tooltip says why. A folder too
long for the header or the sidebar's top line loses its start to "…", so you still see the
folders nearest the file. Drag the header or the empty band above the sidebar to move the window,
and double-click it to zoom (or minimize, or nothing, as Desktop & Dock's "Double-click a
window's title bar" setting says).

## Command palette

**View > Command Palette…** (⌘K) lists every command in Zag's menus above the prompt line, the
View menu's first. **Help > Keyboard Shortcuts** opens the same list. The list is an inset
rounded panel with a soft shadow above it, set in the Mac's system font like a menu. Each command
shows its shortcut on the right, lined up like the Mac's menus, and a checkmark in a column on
the left when it's on. The picked row has the same soft fill as the sidebar's selection, the row
under the mouse lights faintly, and the first rows slide in one after another when the list
opens. Quick open looks the same. Type a few letters, use ↑ and ↓ (or Page Up and Page Down) to
pick, and press Return to run it, or Escape to close the list. Past ten rows the list scrolls,
and the prompt line counts where you are, like "3 of 120 commands".

Commands inside a submenu or under a heading show its name in gray, like "Appearance: Dark" or
"Focus: Line", and each theme reads like "Theme: Ayu Dark (Dark)", so typing `dark` finds them
all. A command that Late-Night Focus has set shows dimmed, and picking it says why.

The Mac's own menu search works too: press ⇧⌘/ (or open the **Help** menu) and type, and macOS
points at the matching command in its menu. Press Return to run it. The Help menu also opens
**Zag User Guide** and **Report an Issue** in your browser.

## Markdown preview

**View > Markdown Preview** (⇧⌘M), also in ⌘K, opens a read-only preview in a separate window,
titled with the file's name and "Preview", with the file's icon in the title bar. The window uses
the editor's page color, grey in Zen and stronger with the Mac's Increase Contrast setting, and
centers the text in a column no wider than 680 points at the default text size. Run the command
again, or press ⌘W in the preview, to close it.

Keep typing in the editor: the preview crossfades to the new text after a short pause, and the
paragraph at its top doesn't move. As you scroll the editor, the preview follows you down the
page. The preview shows the file you opened it for, even after you switch tabs or cards, and
closes with that file's window. Other text files can be previewed too, using the same Markdown
rules. The preview window remembers where you left it and how big it was, and opens there next
time.

- The preview's type follows the editor's font, text size and line height: **Bigger** and
  **Smaller** grow and shrink the headings, the body and the code, and code uses the editor's
  font.
- With the preview in front, ⌘F opens a find bar at the top of the preview, and ⌘G and ⇧⌘G step
  through the matches.
- Lists show •, ◦ and ▪ by depth, or numbers. A task's `[ ]` or `[x]` becomes an empty or ticked
  box, and a ticked task's text turns gray.
- Code blocks show on a bordered panel, colored by the language after the opening fence, like
  ` ```zig `. A code block inside a list item lines up with the item's text. Inline `code` shows
  on the same panel color.
- Quotes show a bar beside them, and `---` draws a line across the column.
- Tables show each row on one line with its columns lined up and the header row in bold.
- Links are tinted and underlined. A link to a heading, like `[setup](#setup)`, glides to that
  heading. A link to another file, like `[guide](docs/index.md)`, opens that file in Zag from the
  Markdown file's folder, and Zag beeps when the file isn't there. A web or mail link opens in
  its own app.

## Open files

- From a terminal, `zag notes.txt` opens a file, and `zag .` opens a folder. A file that doesn't
  exist yet opens empty, its tab says **New**, and Zag creates the file when you save.
- **File > Open…** (⌘O) opens files or a folder.
- Drag files or a folder from Finder over a window and the cards light up; drop them to open the
  files as tabs in the focused card. A folder becomes the sidebar's folder. You can also drop
  them on Zag's Dock icon.
- **File > Open Recent** lists the last 15 files you opened or saved, each with its icon; two
  files with the same name show their folders too. **Clear Menu** empties it.
- **File > Quick Open…** (⌘P) finds a file by name (see Quick open).
- Opening a file that's already open in another window or card brings it forward. Quick open
  and the sidebar show the new file in a new tab of the focused card, right of the one on show
  (see Tabs).
- A file opens where you left it: the caret and the scroll come back to where they were the last
  time you closed it.
- Files that look binary don't open.
- A file you can't write to shows a lock after its name in the tab or header. Saving it asks
  first (see Save and close).

## Quick open

**File > Quick Open…** (⌘P) lists every file in the sidebar's folder above the prompt line. With
no folder open, quick open uses the folder of the file on show. Before you type, the list starts
with your recent files and the files open in your cards. Type a few letters of the name, or a
few words that each match part of the path, and the list ranks the best matches, favoring
matches in the file name, at the starts of words and in runs. Each row shows the file's Finder
icon, its name and its folder, with the matched letters in the accent color. The prompt line
counts the files, like "3 of 4,512 files", or the matches while you type.

- ↑ and ↓ pick a row, and Page Up and Page Down move ten rows.
- Return opens the pick the usual way.
- ⌘Return, or ⌘-click a row, opens it in a new tab of this card.
- ⌥Return, or ⌥-click a row, opens it in a new card split off this one, or a new tab when the
  card has no room to split.
- Escape closes the list.

Quick open leaves out files and folders whose names start with a dot, unless **Show Hidden
Files** is on (see Sidebar); even then it never lists `.git`.

## Tabs

Every file a card has shown appears in it as a tab, with its unsaved changes and undo, so
switching never asks you to save. With one file the header shows just its name and folder. Open
a second and the header turns into a row of tabs: the name becomes the first tab, the new one
pops in beside it with a little bounce, and a **+** shows after the last one. The active tab's
name is in medium weight and full strength, the others lighter. When you switch, the old tab's
text dissolves into the new tab's, and the tabs don't change width.

- Click a tab to show its file. The active tab's highlight hops over to it.
- **View > Show Next Tab** (⌃Tab or ⇧⌘]) and **Show Previous Tab** (⌃⇧Tab or ⇧⌘[) step through
  the focused card's tabs and go around at the ends. **View > Go to Tab** shows tab 1 to 8 with
  ⌘1 to ⌘8, and the last tab with ⌘9.
- The active tab, and any tab under the mouse, shows a **×** that closes it. A tab with unsaved
  changes shows a dot there instead until you point at it. The dot grows in with a little bounce
  when you first change the file and shrinks away as the **×** comes back when you save. An
  untitled file with text shows a smaller, fainter dot, because Zag has its text safe in a draft
  (see Drafts). Closing a tab folds it shut and the tabs after it slide over. After a click on a
  **×**, the tabs don't change width until the mouse leaves the row, so the next **×** slides
  under the pointer.
- A middle-click on a tab closes it.
- **File > New Tab** (⌘T), the **+**, or a double-click on the empty part of the tab row opens an
  untitled file in a new tab. Zag leaves the tab open, even while it's empty, until you close it. Its
  tab and the window take their name from its first line of text once you pause typing, or at
  once when you press Return. With no text it's "Untitled", or "Untitled 2" and on when the card
  already has a blank one. When the file on show is already blank, ⌘T pulses its tab instead.
- Double-click an untitled tab to name it. The tab uses that name, whatever its text says, until
  you save it.
- **File > Close Tab** (⌘W) closes the tab on show, asking first when it has unsaved changes. The
  tab to its right takes its place. Closing the last tab folds its card away, or closes the
  window when it's the only card.
- **File > Reopen Closed Tab** opens the last file whose tab you closed, of the last 20, if it's
  still on disk.
- **File > Close Window** (⇧⌘W) closes the window and all its tabs.
- Drag a tab along the row to move it. The tabs it passes slide out of its way, and it springs
  into its place when you let go. Pull it more than 8 points off the row to drag it to another
  card or a split (see Cards).
- Right-click (or control-click) a tab, or a card's lone file name, for **Close Tab**, **Close
  Other Tabs**, **Close Tabs to the Left**, **Close Tabs to the Right**, **Duplicate Tab** (an
  untitled copy of its text right after it), **Move to New Window**, **Split Right** and **Split
  Down** (which move the tab into a new card beside or below), **Reveal in Finder** and **Copy
  Path**. The tab shows a faint tinted outline in the caret's color while the menu is open,
  fading in and out. Closing several tabs asks about each one with unsaved changes, and
  **Cancel** stops there. When Zag asks about a tab that isn't on show, it outlines that tab and
  leaves the active one on show.
- Hover a tab for its full path.

When the tabs don't fit, the active tab gets up to half the row and the others get narrower, with
names that end in "…". Past that, a chevron appears after the **+**: click it for a menu of every
tab in the card, with the one on show checked. The row scrolls to show the active tab, and a
sideways swipe or a mouse wheel over the row scrolls it by hand. Drag the header between and
around the tabs to move the window.

## Cards

A window can show several cards, each with its own tabs, split side by side or stacked. One card
has the focus: typing, saving and the File menu act on it, and the window's title follows its
file. With more than one card, the focused card has a thin ring in the caret's color, and the
others show a hollow caret and dim their header.

- **View > Split Right** (⌘D) and **Split Down** (⇧⌘D) split the focused card in two. The new
  card springs open beside or below it and takes the tab on show. A card with only one tab
  doesn't give it up, and the new card starts with quick open so you can pick a file for it.
  When the focused card has no room to split, ⌘D shakes it and the trackpad taps.
- Click a card to focus it. **View > Next Card** (⌘]) and **Previous Card** (⌘[) step through
  them and go around at the ends. **Card Left**, **Card Right**, **Card Above** and **Card Below**
  (⌥⌘ and an arrow) move to the nearest card that way.
- **View > Maximize or Restore Card** (⇧⌘Return) gives the focused card the whole window while
  the others shrink away; run it again and the splits spring back as they were.
- **View > Move Tab to Next Card** (⌥⌘]) and **Move Tab to Previous Card** (⌥⌘[) move the tab on
  show into that card, after its active tab. With one card, Zag says there's no other card.
- **View > Close Card** closes the focused card and all its tabs, asking about unsaved ones first.
  A window's only card closes the window.
- Right-click a card's header away from its tabs for **New Tab**, **Split Right**, **Split Down**
  and **Close Card**.
- Drag the gap between two cards to resize them. Neither gets narrower than 220 points or shorter
  than 140. The split snaps to halves and thirds when you come within a few points of them, with
  a tap on a trackpad and a faint guide that flashes down the gap. Pull past a limit and the gap
  stretches a little, then springs back when you let go. Double-click the gap to even the split.
- Closing a card's last tab folds the card away, and its neighbor springs over to fill the room.
- Drag a tab onto another card's tabs to move it there: they slide apart to show where it goes.
  Drag it over the middle of another card's text to add it to that card's tabs. Drag it over any
  card's text nearer an edge, its own included when it has other tabs, and a preview of half the
  card shows on the side nearest the mouse; dropping there splits the card and puts the tab in
  the new half. A card with no room to split takes the tab as a new tab instead. With more than
  one card, a card's lone file name drags the same way, and its card folds away once the file
  leaves. The card a tab drops into pulses its ring once.
- Press Escape during a drag to send the tab home.
- **Window > Move Tab to New Window** moves the tab on show into a window of its own, and
  **Window > Merge All Windows** moves every other window's tabs into the focused card and closes
  those windows.

## Sidebar

The left side of each window lists the files of the sidebar's folder, folders first, in letter
order with numbers compared as numbers, so `file2` comes before `file10`. The sidebar's folder
is the one Zag started in from a terminal, or the one you opened last. Started from the Dock or
Finder with no folder from last time, Zag shows no sidebar until you open a folder. The sidebar
shows the Mac's own translucent sidebar material, and the cards' chrome lets a little of it show
through. At the top, the folder's own name shows in bold with a small arrow. Files and folders
whose names start with a dot don't show unless **Show Hidden Files** is on. Files have the Mac's
own icon for their kind, the same ones Finder shows, and folders have a small tinted folder.
Names are in the Mac's system font and end in "…" when they don't fit; hover a row for its full
path. The file on show in the focused card is marked with a soft rounded fill and its name is in
bold; when the selection moves, the bold fades from the old name to the new one. A fainter
highlight follows the mouse down the list, sliding from row to row without a bounce, and fades
out when the mouse leaves. When a folder opens or closes, or tabs slide, the highlight follows
the row under a still mouse, so a tab that moves under the mouse lights up too.

The folder's name is pinned at the top while the rows scroll. An open folder whose files fill the
top of the list pins under the name too, up to three levels deep, until the next folder's row
pushes it away. Click a pinned folder to scroll back to it. The list stops a little above the
window's bottom edge, level with the cards, and when more rows wait below, the last few points
fade out. A folder Zag can't read says so in the middle of the list, and so does a folder with
nothing to show. Past 50,000 rows the list stops and its last row says "Too many files to list
them all". When you open another folder, the sidebar crossfades from the old folder's rows to the
new one's.

- Click the folder's name for a menu of the folder and the folders above it (pick one to show it
  in Finder), then **Reveal in Finder**, **Open Folder…**, **Recent Folders** and **Show Hidden
  Files**.
- Click a folder to open or close it. Its files fade in or out while the rows below slide to make
  room, and its arrow turns. Clicking another row while a folder is closing doesn't make the list
  jump.
- Click a file to show it in a new tab, where its text fades in. A dot next to a file in the
  sidebar means it has unsaved changes.
- ⌘-click a file to open it in a new window.
- Drag a file onto a card's tabs to open it there as a new tab: the tabs slide apart to show
  where it goes. Drag it over a card's text to open it in a new card split off that card's
  nearest edge that has room, with a preview of the half it takes. A copy of the file's name
  follows the mouse while its row dims. A file already open in the window moves there instead.
  Let go where it can't drop and the copy slides back to its row. Drag it out of the window to
  copy the file into Finder or another app.
- Right-click (or control-click) a file for **Open in New Tab**, **Open in New Split** (beside the
  focused card, or below it when there's no room beside), **Open in New Window**, **New File…**,
  **New Folder…**, **Rename…**, **Duplicate**, **Move to Trash**, **Reveal in Finder**, **Copy
  Path**, **Copy Relative Path**, **Collapse All** and **Show Hidden Files**. For a folder the
  first three are greyed out, and a right-click on empty space in the list acts on the open folder.
  The row shows a faint tinted outline in the caret's color while the menu is open, apart from
  the highlight on the file on show.
  - **New File…** asks for a name, makes an empty file in that folder and opens it in the focused
    card. **New Folder…** makes a folder. Neither command replaces an existing file or folder.
  - **Rename…** renames the file or folder, and open tabs of it, or of files inside it, follow it
    to its new name. You can change just the name's capitalization; Zag won't replace another
    file or folder.
  - **Duplicate** makes a copy beside it named "name copy.ext", or "name copy 2.ext" and on.
  - **Move to Trash** moves it to the Trash; open tabs of it turn its text into unsaved changes.
  - **Collapse All** shuts every open folder, and the list crossfades to its top.
- **View > Show Hidden Files** lists dotfiles and dot folders in the sidebar and quick open.
- **View > Sidebar** (⌘\) or the sidebar button by the traffic lights shows or hides the sidebar
  in every window. The sidebar slides in and out, and the text's card follows its edge. Zag also
  hides it when a window is too narrow to fit it beside the text.
- Drag the sidebar's right edge to make it wider or narrower, from 150 to 500 points. Every
  window follows, and new windows and the next start use the width you left it at. Past either
  limit the edge stretches a little with some resistance, gives a tap on a trackpad where it
  stops, and springs back when you let go. Drag it in below 100 points and the sidebar slides
  shut; show it again and it has the width it had.

### Sidebar keys

**View > Focus Sidebar** (⇧⌘E) gives the sidebar the keys, and shows it first when it's hidden.
Clicking a folder does the same. An outline marks the row the keys are on and slides from row to
row.

- ↑ and ↓ move between rows.
- → opens a folder, or steps into an open one; ← closes it, or steps out to its folder.
- Return opens a file in the focused card, which takes the keys, or opens or closes a folder.
- Type the start of a name to jump to the next row that starts with it. After a one-second pause,
  typing starts a new name.
- Escape, or a click in a card, gives the keys back to the card.

Zag reads the disk again when you come back to it, so new and deleted files show up in the
sidebar.

## Pick up where you left off

When you quit Zag with files open and later start it again, Zag reopens those files in the same
windows, at the same sizes and places, and brings back the folder you had open. Each window
comes back with its cards in the same places and sizes, each with its tabs in order and the same
tab on show. A file that's gone drops out of its card, and a note says which one didn't reopen.
Starting Zag with a file, like `zag notes.txt` or a double-click in Finder, opens that file on
top of the last session. Close every window before quitting and the next start gives you one
empty window.

### Drafts

An untitled file saves itself as a draft a second after you stop typing, so there's no need to
save a scratchpad. Its tab shows the fainter draft dot, quitting doesn't ask about it, and it
comes back in its tab next time. If Zag can't save its drafts when you quit, it says so and
cancels quitting, leaving your tabs open. If Zag ever stops without quitting, its drafts come
back as tabs in the front window at the next start, after the tab on show, even when that start
opens other files. Saving the draft to a file with ⌘S removes the old draft, not the file you
chose, even when you chose the draft's own file. Closing its tab and choosing **Don't Save**
deletes the draft. Zag writes drafts to `~/Library/Application Support/zag/Drafts`, and moves
any it finds in the old `ze/Drafts` folder there.

- **File > Recover Drafts** brings back every draft that no tab shows, and says how many came
  back.
- **File > Browse Drafts…** opens the Drafts folder in Finder.

## Edit

Typing, selecting and moving work like other Mac text fields, including ⌥ and ⌘ with the arrow
keys, ⌥⌫ to delete a word, and the Control-key shortcuts (⌃A, ⌃E, ⌃K and the rest).

- Double-click selects a word and triple-click selects a line; drag after either to grow the
  selection by words or lines. ⇧ with a double or triple click grows the selection from where it
  started by whole words or lines.
- Drag a selection past the top or bottom of the text, or past the side of an unwrapped line, and
  the page scrolls, faster the farther out you go.
- A selection has a clear tint of its own (the caret's color on Paper and Ink, blue on the Ayu
  and One themes) with rounded corners, so it reads as one shape. The band on the caret's line
  fades away while you select. A selection in a card without the keys draws dimmer.
- With the caret next to a bracket, like `(` or `}`, Zag marks that bracket and its partner.
- Return copies the line's indentation. Tab indents, or indents every selected line; ⇧Tab
  takes one level of indentation off. Zag indents with spaces or tabs as the file already does,
  or as the `indent-with` and `tab-width` settings say for a new file.
- ⌘/ comments or uncomments the selected lines.
- ⌥⌘J (**Edit > Format JSON**) lays out the selection as indented JSON, or the whole file when
  nothing's selected, and flashes what it changed. Keys come out in their order and numbers and
  strings come out as you wrote them. If the text isn't valid JSON, nothing changes: the caret
  moves to where it goes wrong, the card shakes, and a note says what's wrong there, like
  `unexpected "}" in JSON at line 3, column 5`. ⌘Z puts a formatted file back.
- ⌘Z and ⇧⌘Z undo and redo. A run of typing undoes as one step.
- Undo, redo, Replace All and every paste flash the text they changed. The flash fades out, and
  your next keypress clears it. Cutting text flashes a bar where the text was.
- Zag saves a file with Windows line endings with Windows line endings.

### Line commands

Each line command works on the caret's line, or on every line the selection touches, as one undo
step.

- **Edit > Duplicate Line** (⌃⇧D) copies the lines below themselves and moves the caret or
  selection onto the copy.
- **Move Line Up** (⌥↑) and **Move Line Down** (⌥↓) swap the lines with the line above or below;
  the caret and selection move with them.
- **Join Lines** (⌃J) joins the lines, or the caret's line and the next, into one: each line break
  and the next line's indent become one space, or nothing next to a blank line or a trailing
  space.
- **Delete Line** (⇧⌘K) deletes the lines with their line break, and the caret moves to the same
  column of the line that takes their place.

### Brackets and quotes

Typing `(`, `[`, `{`, `"`, `'` or `` ` `` adds the closing one after the caret, and the pair
flashes. Typing the closing one when it's already next steps over it, and ⌫ between an empty pair
deletes both. With text selected, typing an opening one wraps the selection. A `'` right after a
letter types a single apostrophe, so "don't" types normally.

**View > Auto-Close Brackets** turns this off and on. The checkmark shows when it's on.

## Soft wrap

**View > Soft Wrap** (⌥Z) wraps long lines at the window's edge instead of scrolling sideways.
Lines break after the last space that fits, or in the middle of a word that's wider than the
window. ↑ and ↓ move by screen rows, and ⌘← and ⌘→ go to the start and end of the row; ⌃A and
⌃E still go to the ends of the whole line. Resizing the window rewraps the text. With the
`hanging-indent` setting on, wrapped rows start under their line's indent, up to half a row. The
setting applies to every window and Zag remembers it.

Without soft wrap, text scrolled sideways fades into a faint rule where it meets the line numbers
or the card's edge.

## Line numbers

**View > Line Numbers** (⇧⌘L) shows a column of line numbers on the left of the text. The
caret's line is brighter than the rest, even while a prompt is open. With soft wrap, each
wrapped row shows a faint ↳ instead of a number. The column doesn't scroll when a long line
scrolls sideways. Click a number to select that whole line, and drag down the column to select
more lines. The column eases wider when the file reaches 100 lines, 1,000 lines and so on, and
Zen mode hides it. It's on by default, applies to every window and Zag remembers it.

## Focus

**View > Focus** brightens the caret's range and fades the rest toward the page color: **Off**,
**Line** (the whole logical line, including wrapped rows), **Sentence** or **Paragraph**. A
sentence ends at `.`, `!`, `?` or `…` and any closing quotes after them, where a space or the
end of the text follows, so the caret right after a period still lights the sentence it
finished. A paragraph runs between blank lines. When the caret moves to another range, the old
range fades out and the new one fades in, evenly and all at once, while selected text and the
caret show their normal colors. The `focus-dim` setting says how far the rest fades. The choice
applies to every window and Zag remembers it.

## Typewriter scrolling

**View > Typewriter Scrolling** pins the caret's row halfway down the card. Moving the caret or
typing glides the page instead, even at the start and end of a file, where blank space fills the
card above the first line or below the last. Scrolling with the mouse or trackpad is still free;
the next caret move or keypress glides the row back to the middle, longer for a longer way. It
works with soft wrap and Focus too. The choice applies to every window and Zag remembers it.

## Zen mode

**View > Zen Mode** (⌃⌘Z) fades out the traffic lights, the cards' headers and outlines and the
status bar, covers the sidebar, turns the theme grey, and pads the text so a page 80 columns wide
(the `zen-columns` setting) appears in the middle of the window. They all fade together over
about half a second. The text is left-aligned and wraps at that width, or at the window's edge
when the window is narrower. With split cards, each card centers its own page. Find, go to line,
quick open and the command palette still open their prompt line at the bottom. Drag the empty
strip at the top to move the window. The traffic lights hide; move the mouse to the window's
top-left corner and they fade back so you can close, minimize or go full screen. They fade out
again a moment after the mouse leaves, or as soon as you type. **View > Peek Window Controls**
(⌃⌘P) shows them for two seconds without a trip to the corner. In full screen they come with the
menu bar at the top of the screen, and **View > Enter Full Screen** (⌃⌘F) works too. Turn Zen
Mode off to bring the window back as it was. The choice applies to every window and Zag remembers
it; your sidebar, wrap and theme settings don't change.

## Late-Night Focus

**View > Late-Night Focus** (⌃⌘N) turns on Typewriter Scrolling, Focus on paragraph, Zen Mode and
the Black theme in one step, in dark mode whatever the Mac is set to. With the
`late-night-warmth` setting on, it also warms the colors. They fade in together, and turning it
off fades back. Late-Night doesn't change your own Zen, Typewriter, Focus, appearance and theme
settings, so they come back exactly as they were when you turn it off. While it's on, those menu
items show what Late-Night set and are greyed out, and their tooltips say how to change them.
Leaving Zen with ⌃⌘Z turns Late-Night Focus off. It applies to every window and Zag remembers it.

## Status bar

A thin strip along the bottom of each card, at its right, shows where the caret is as "Ln 120,
Col 14". Both count from 1, and the column counts characters, so an accented letter or an emoji
counts as one. Click "Ln, Col" to open Go to Line. While text is selected the strip adds how
much, like "48 characters, 3 lines". For plain text and Markdown files (and files that aren't
saved yet) it also shows the words, like "1,204 words": runs of text between spaces, counted
again only when the text changes. The `word-count` setting shows the count in every file
(`always`) or none (`off`). After those come the file's language, its indent, like "Spaces: 4"
or "Tabs: 4", and its line endings, "LF" or "CRLF". When the strip switches to another tab, a
selection, a language, an indent or a line ending, the old line crossfades to the new one. A card
that isn't the focused one shows its own, a little dimmer. The prompt line covers the strip while
it's open, and Zen Mode hides it.

## Find and replace

1. Press ⌘F. The prompt starts with the selected text when it's on one line, or else the word at
   the caret, which becomes the current match, or else your last search. Typing replaces it.
2. Type: Zag jumps to the first match and shows how many there are. Zag stops counting at 10,000
   and shows `10000+`, so a one-letter search in a huge file answers at once. If nothing
   matches, the words shake and the count turns the caret's color.
3. Press Return for the next match, ⇧Return for the previous one, and Escape to close the prompt.

Searching ignores case unless you type a capital letter. Two pills at the right end of the
prompt line change that for every search, and Zag remembers them from one find to the next:

- **Aa** (⌥⌘C) matches case exactly.
- **\b** (⌥⌘W) matches whole words only.

Click a pill or press its keys to turn it on or off; hover it for its name and keys.

The match you're on is a bright yellow pill that pops when you jump to it, and the other matches
are softer, rounded pills. When the prompt opens on text you'd selected, the other matches fade in
outward from the one you're on. While find is open, a thin tick along the card's right edge marks
each row with a match, and the current match's tick shows in the caret's color. When a search
goes past the end of the file and starts again at the top, or the other way, "wrapped" shows in
the prompt line for a moment. ⌘G and ⇧⌘G find the next and previous match after the prompt is
closed, and they pop the match too; when they go around the file a note says "wrapped to the top"
or "wrapped to the end".

Escape puts the selection and the scroll back where they were before you opened find, unless you
pressed Return or ⌘G to step to a match.

To replace, press ⌥⌘F (**Edit > Find and Replace…**). The prompt line shows `find` and `with`,
and lists its keys while there's room.

- Type what to find, press Tab, and type what to put in its place. Tab goes back and forth.
- Return replaces the selected match, flashes the new text and selects the next match.
- ⌥Return replaces every match in the file and closes the prompt. A note says how many it
  replaced, and one ⌘Z puts them all back.

The replacement goes in exactly as typed.

### Typing in the prompt

The prompt's fields work like a text field: click to place the caret, ⇧-click to select,
double-click a word, triple-click the whole field, and drag to select. ⌘Z and ⇧⌘Z step back and
forth through what you typed; with nothing to step, ⌘Z closes the prompt and undoes in the text.
In find, replace and go to line, ↑ and ↓ step through your last 50 searches, replacements or
lines, and past the newest back to what you'd typed. The prompt is one line: pasting several
lines into find joins them with spaces, quick open and the palette take only the first line, and
go to line takes just its digits, `:`, `+` and `-`.

## Go to line

**Edit > Go to Line…** (⌘L), or a click on "Ln, Col" in the status bar, asks for a line. The
prompt line shows how many lines the file has, like "of 1,204 lines". Type:

- `120` to go to line 120.
- `120:14` to go to line 120, column 14, or `:14` for column 14 of the caret's line.
- `+5` or `-5` to go five lines down or up from the caret's line, with an optional `:column`.

Lines and columns count from 1 and stop at the ends of the file and the line. Press Return to
jump: the line flashes and Zag scrolls it into view. If Zag can't read what you typed, the prompt
shakes and doesn't close.

## Changes from other apps

When another app changes a file that's open in Zag, Zag notices the next time you come back to it:

- If you haven't changed the file in Zag, Zag reloads it and a note says "reloaded". The caret
  doesn't move, and ⌘Z brings back the text from before the reload.
- If you have unsaved changes, Zag asks what to do and says which lines differ. **Keep Mine**
  leaves your text alone, **Reload** takes the other app's version, and **Show Changes** opens
  the version on disk as an untitled tab in a card beside yours, so you can compare.
- If the file was deleted, a note says "deleted on disk" and Zag turns the text into unsaved
  changes, so ⌘S writes it back.
- If a file became read-only, or writable again, its lock shows or goes.

If another app changes the file while you're still in Zag, ⌘S asks before saving over it: Save
Anyway writes your text, Cancel leaves the other app's version alone.

## Save and close

⌘S saves, ⇧⌘S saves under a new name, and ⌥⌘S (**File > Save All**) saves every file with
unsaved changes in every window. A note says "saved". Zag writes the file next to the old one and
then swaps it in, so a crash halfway through a save never leaves a half-written file. Zag
preserves the file's permissions and its Finder tags. If a save under a new name fails, the file
goes back to its old name. If the write fails, Zag says what the system said and offers **Try
Again**, **Save As…** and **Cancel**. Saving over a read-only file asks first. With the
`trim-trailing-whitespace` or `ensure-final-newline` setting on, saving strips spaces and tabs at
the ends of lines or adds a newline at the end.

**File > Reveal in Finder** shows the file on show in Finder.

Closing a window with unsaved changes, or quitting with unsaved changes to files, asks whether to
save them first. Closing also asks about untitled files with text in them, since their drafts go
with the window; quitting saves the drafts instead (see Drafts). When a window shows more than
one of these across its cards and tabs, one question covers them all: **Save All** saves each one
(asking for a name for any untitled file), **Don't Save** drops the changes, and **Cancel** leaves
the window open.

## VoiceOver

VoiceOver reads each card's text, line by line, and follows the caret and the selection as they
move. It can move the caret, select text and switch between cards. Tabs show up as a group of
tabs when a card has two or more, and pressing one switches to it. The sidebar is an outline
named after the folder: each row says its name, how deep it is, whether a folder is open and
whether it's selected. Pressing a folder opens or closes it, and pressing a file opens it in the
focused card. With soft wrap on, VoiceOver still reads a whole line at a time. VoiceOver doesn't
see the find, replace or quick open prompts, but it reads the card's text while one is open.

## Syntax colors

Zag colors code by the file's name, for Zig, C and its family (C++, Objective-C, Java, Kotlin,
C#), JavaScript and TypeScript, Python, Rust, Go, Swift, Dart, PHP, SQL, shell and Fish, Ruby,
Lua, JSON and JSON Lines, TOML, YAML, INI, CSS, HTML (and XML, SVG and plist), Markdown and
diffs. Shell setup files like `.zshrc` and `.bash_profile` color as shell, and `Makefile`,
`Dockerfile`, `.gitignore` and `.env` files color as data. When the name doesn't say, Zag reads
the first line: a `#!` line naming `sh`, `bash`, `zsh`, `fish`, `python`, `node`, `ruby`, `lua`,
`php` or `dart` (through `env` too), or a first line of `<?php` or `<?xml`.

Keywords are bold, and strings, comments and numbers each get a color. In code, a word right
before `(` takes the function color, a Capitalized word the type color, and an ALL_CAPS word the
number color. SQL keywords match in any case. In data files and CSS, keys at the start of a line
take the function color and `[sections]` the keyword color. In HTML, tag names take the keyword
color, attribute names the function color, their values the string color and `&entities;` the
number color, and Zag colors the text inside `<style>` and `<script>` as CSS and JavaScript. In
Markdown, headings, list markers and **strong** text take the keyword color, `code` and fenced
blocks the string color, and links the function color with their address dimmed. In a diff, file
headers take the keyword color, `@@` lines the function color, added lines the string color,
removed lines the number color, and `\ No newline` notes the comment color. Other files are plain
text.

## Language

**View > Language** lists every language Zag colors, with a checkmark on the focused card's
file's language. Pick one to color the file as that language, whatever its name says, until you
close its tab. The status bar shows the language in use.

## Themes

Zag has a theme for light mode and one for dark mode. **View > Theme** picks the mode under
Appearance: Auto (the default) switches every window when the Mac switches, and Light or Dark
fixes Zag in that mode whatever the Mac does. Below that it lists the themes, each with a small
swatch of its colors:

- Light Mode: Paper (the default), Ayu Light, One Light, Solarized Light and Gruvbox Light.
- Dark Mode: Ink (the default), Ayu Dark, One Dark, Solarized Dark, Gruvbox Dark and Black.

Picking a theme makes it the theme for its own mode. Black is for OLED screens: a black window
with soft off-white text. Checkmarks show the mode and the two themes in use, and Zag writes them
to the settings file. Zen Mode turns every theme color grey while it's on, without changing the
saved colors. Switching themes, or the Mac's light and dark setting, fades over a quarter of a
second. Gray text in every theme is dark enough to read comfortably. With **Increase contrast**
on in System Settings > Accessibility > Display, Zag strengthens the card outlines, the sidebar's
selection, hover highlight and the line under its pinned folders, the tabs' highlights and the
gray text, and follows the setting the moment you change it.

## Font and text size

- **View > Font…** (⇧⌘T) opens the Mac's Font panel. Pick any font; monospaced ones look best.
- **View > Bigger** (⌘= or ⌘+) and **Smaller** (⌘-) change the text size in every window, from 8
  to 40 points, and **Actual Size** (⌘0) puts it back to 14. A note shows the new size, like
  "15 pt", and at either end the note says so and the trackpad taps.

Zag remembers the font and size for next time.

## Settings

**Zag > Settings…** (⌘,) opens Zag's settings file in a Zag window. The file lists every setting
with a short note. Change a value and save, and every window picks it up at once. The file is
`~/.config/zag/config.toml`, plain TOML, so you can edit it in any other app too. Zag watches the
file, so a change you save elsewhere applies right away, even while Zag is in the background and
you never switch to it. Every setting appears in the file: the first time Zag starts with a file
that lacks one, Zag adds that line with its note after your other settings, and leaves your own
lines and notes alone.

If Zag can't read the file again, it leaves your last loaded settings in effect rather than
switching to defaults. Fix the file's access, then use **Reload Settings** to try again.

The Zag menu also has:

- **Reveal Config in Finder** shows `config.toml` in Finder.
- **Reload Settings** reads the file again and names any problems again.
- **Reset Settings to Defaults…** asks first, moves your `config.toml` to the Trash and writes a
  new one with every setting at its default.

Changing a theme, Appearance, Focus, Auto-Close Brackets, the colors, the caret's line band, the
marks and guides, the word count or what saving does leaves your scroll where it is, even when
the caret is off screen. Changes to the font, text size, line height, tab width, Soft Wrap,
hanging indent, Zen Mode, Line Numbers, sidebar visibility or width, or Typewriter Scrolling
bring the caret back into view.

```text
# Zag settings. Save this file and every window picks up the change.

# A font's PostScript name, like Menlo-Regular, or system for SF Mono.
font = "system"
# The text size in points, from 8 to 40.
size = 14
# Line height, as a multiple of the size, from 1 to 3.
line-height = 1.75
# Wrap long lines at the window's edge: true or false.
wrap = false
# Close brackets and quotes as you type them: true or false.
pairs = true
# Fade text outside the caret's range: off, line, sentence or paragraph.
focus = "off"
# Keep the caret's row in the middle as you type: true or false.
typewriter = false
# Number the lines beside the text: true or false.
line-numbers = true
# Hide the window's chrome and center a grey page zen-columns wide: true or false.
zen = false
# Late-Night Focus: zen, typewriter, paragraph focus and Black on top of the above: true or false.
late-night = false
# Show the folder's files on the left of the window: true or false.
sidebar = true
# How wide the sidebar is, in points from 150 to 500: drag its edge to change it.
sidebar-width = 250

# Columns per tab stop, from 1 to 16.
tab-width = 4
# What the Tab key inserts: spaces or tabs.
indent-with = "spaces"
# Strip spaces and tabs at the ends of lines when saving: true or false.
trim-trailing-whitespace = false
# End the file with a newline when saving: true or false.
ensure-final-newline = false
# Start wrapped rows under their line's indent: true or false.
hanging-indent = false

# The caret's shape: bar, block or underline.
caret-style = "bar"
# The bar caret's width in points, from 1 to 6.
caret-width = 2
# Blink the caret: true or false.
caret-blink = true
# Shade the caret's line: true or false.
highlight-current-line = true
# Mark spaces, tabs and line ends: none, trailing or all.
show-invisibles = "none"
# Draw a faint line at each indent level: true or false.
indent-guides = false
# Count words in the status bar: auto (prose files), always or off.
word-count = "auto"
# How wide zen's page is, in columns from 40 to 160.
zen-columns = 80
# How far Focus fades the text outside the caret's range, from 0.2 to 0.95.
focus-dim = 0.78
# Warm the colors in Late-Night Focus: true or false.
late-night-warmth = false
# List hidden files and folders in the sidebar: true or false.
show-hidden = false

# Light or dark: auto follows the Mac, light or dark keeps Zag in that mode.
appearance = "auto"
# The theme for each mode: paper, ayu-light, one-light, solarized-light,
# gruvbox-light, ink, ayu-dark, one-dark, solarized-dark, gruvbox-dark or black.
light-theme = "paper"
dark-theme = "ink"

# Change one color of a theme with a line like light.keyword = "#9C3D26".
# The names are background, text, muted, keyword, string, comment,
# number, function, type, selection, line, caret, match, panel, rule
# and header.
#
# Or set a mode's colors under a section at the end of the file:
# [dark]
# keyword = "#F08A6C"
# comment = "#888"
```

Text is in quotes, flags are `true` or `false` and numbers stand bare. Zag still reads the older
forms too: `on`, `off`, `yes` and `no`, text without quotes, and a color without quotes, and it
ignores a ` # note` after a value.

A few settings change how the text looks:

- `caret-style` draws the caret as a bar, a see-through block over the character, or an
  underline, and a block or underline covers both cells of a wide character. A prompt's caret is
  always a bar. `caret-blink = false` shows a solid caret.
- `show-invisibles` marks spaces with a faint centered dot and tabs with a faint arrow: `trailing`
  marks only the ones after a line's last character, `all` marks every one.
- `indent-guides` draws a faint line at each indent level, running through blank lines between
  indented ones.
- `highlight-current-line = false` drops the band behind the caret's line.

A `light.` or `dark.` line changes one color of that mode's theme, whichever theme it is. So does
a plain `name = "#color"` line under a `[light]` or `[dark]` line at the end of the file. A color
is `#RRGGBB` or the short `#RGB`, with or without the `#`. The names are `background` (the card;
the window around it is a step darker), `text`, `muted` (the header's fainter words), `keyword`,
`string`, `comment`, `number`, `function`, `type`, `selection`, `line` (the caret's line),
`caret`, `match` (other find matches), `panel` (the quick open list), `rule` (the line under the
header and above the prompt line and the quick open list) and `header` (the card's header, a
step lighter than the text on dark themes and a few steps darker on light ones, so it stands
apart from the text). Either mode can also use any theme from the file, so
`light-theme = "one-dark"` makes Zag dark all the time.

When a line has a problem, Zag skips it and uses the default, or clamps a number that's out of
range to the nearest end, and a note names the first problem and counts the rest, like
`config.toml line 12: wrap = "maybe" isn't true or false (and 2 more)`. Zag names each new set of
problems once; saving `config.toml` or **Reload Settings** names them again. A missing line uses
its default. The menus, the size shortcuts and the Font panel rewrite their own line in the file
and leave the rest of it alone. Tabs, splits, the sidebar's folder and full screen belong to each
window, so they aren't settings.
