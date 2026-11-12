---
type: decision
status: accepted
summary: Anything in ze's window that moves, appears or goes away animates; how the animations are built and timed.
---

# Everything that moves animates

Harsha's rule from 2026-11-05 (zig-editor#ekky): any part of the window that moves, shows up or
goes away animates. That covers folders opening and closing, a file's text coming in, the sidebar
showing and hiding, and later tabs and split panes. A jump is a bug.

## How

- ze draws every frame itself in `drawRect`, so an animation is a value that changes over time and
  a draw that reads it. `Tween` holds one: `aim` starts a glide from wherever it is now, `snap`
  jumps, `at(now)` reads it. Aiming again mid-glide keeps the speed, so a quick second click turns
  the motion around instead of restarting it.
- Playful motion uses `Spring` instead: a damped spring that overshoots a little and settles.
  A new tab's width and the active tab's highlight ride one, so tabs pop in and the highlight
  hops. So do the sidebar's selection and the quick open list's picked row, and each split's
  share of its room, so a new card springs open. Things that leave (a closing tab, a card
  folding away) get a critically damped spring and don't bounce.
- A highlight that rides a spring and whose row moves for another reason (a folder above it
  opening) shifts the spring by the same amount, so it only bounces when it changes rows.
- Tabs that change places slide rather than jump: before the order changes, each tab notes
  where it's drawn (`Slot.flip`), and on the next draw a spring (`Slot.shift`) carries it from
  there to its new place. A dragged tab rides the same spring, snapped to the mouse, and springs
  home when it's let go; it draws last on its own backing so it passes over the others.
- A tab dragged over another card's tabs opens a gap there (`Doc.opening`) that the tabs slide
  aside for. The drop preview springs between places and grows in from a little smaller; the
  tab's copy under the mouse fades in once it leaves its row.
- A drag's copy doesn't vanish when the mouse lets go (`Win.fly`, zig-editor#3epv). Dropped on a
  tab row it slides into the gap as the new tab grows there; dropped nowhere it slides back to its
  tab or sidebar row over 0.3 s, the way Finder returns an icon; dropped on a card it fades where
  it is. The tab or sidebar row it came from stays faint until it's back. The copy keeps its own
  retained name line, since the tab it came from may be gone by then.
- Focus mode crossfades instead of moving: when the caret moves to another sentence, line or
  paragraph, the old range dims and the new one brightens, every letter at once, at an even rate
  over 0.25 s (zig-editor#xgxf). Typing that only stretches the range doesn't fade.
- Drawing can happen on any frame, not just after an event: while anything in the window moves,
  the display link redraws every frame. So a draw that finds a value already heading where it
  should go must leave its glide alone. The caret used to snap on every such redraw, which is why
  it stopped gliding while an untitled tab's name grew with each letter (zig-editor#258w).
- `scenery()` says whether a window still has frames to draw. Each new animation adds its clause
  there; leaving it out shows as an animation that freezes until the next event.
- Layout uses where things end up, and only drawing and hit tests use where they are now. The
  sidebar's slide moves the cards' left edge (`Win.lx`) and a split springs each card's size, but
  text wraps once, to the card's final width (`Doc.fin`), and doesn't reflow every frame.
- State that every window shares, like a folder folding in the sidebar, animates in every window
  at once from one global value.
- The first draw of a window snaps, so a new window doesn't play its sidebar in.

## Timing

Short and ease-out, so nothing feels like it waits on the animation: 0.12 to 0.2 s for fades,
folds and the file fade-in, 0.24 s for the sidebar slide, 0.16 s for scroll glides. A click during
an animation acts at once: a closing folder keeps sliding and the click maps through its rows.

- Caret glide: `clamp(0.09 + 0.025 * log2(1 + dist / lineHeight), 0.09, 0.14)`. zig-editor#r6r2 cut a
  one-column step to 0.05 s, which at 120 Hz is about two visible frames and read as a jump, so
  Harsha lost the glide while typing (zag#me3c); don't go under 0.09 s. A move that extends a
  selection snaps. The glide time is set only when a glide starts, so redraws keep zig-editor#258w fixed.
- Blink: one 1 s keyframe animation, solid until 0.5, fade out to 0.62, dark until 0.9, fade in.
  The solid hold after a move is the first segment (zig-editor#r6r2).
- Find pill pop: spring k 600 c 22 kicked to v 6, peaks near 1.14, restarts on each jump. The old
  pill fades over 0.12 s. Opening find on prefilled text staggers the other matches 8 ms per row,
  capped at 120 ms.
- Flash on undo, redo, Replace All and big pastes: caret color at 0.28, 0.1 s hold, then 0.45 s
  ease-out. The next key clears it.
- Shake (no matches, refused split): `6 * sin(2 * pi * 3t) * (1 - t)` over 0.3 s. A card shake
  leaves the caret still (zig-editor#bdw5).
- Prompt band (zig-editor#tdry): 0.14 s in, 0.12 s out, the words 30 ms behind. Closing keeps
  drawing the last label and text held on the doc. Text layout uses the final height.
- Tab switch: the text fades from 0.35 to 1 over 0.12 s with no rise, and the caret layer fades in
  with it. Only a file freshly read from disk keeps the fade and rise.
- Empty-window shortcut hint: fades in over 0.3 s after a 0.4 s delay, out over 0.12 s when the
  card stops being blank or a prompt opens.
- Scroll bar: 0.08 s in, 0.25 s out. The 1 s hold is a one-shot timer (`holdRedraw:`), not display
  link frames, so `scenery()` doesn't wait on it. Sidebar-only motion (selection, hover, the +
  button, the list's scroll glide, folders folding in every window) redraws only the sidebar strip
  through the dirty rect, and a card the strip reaches only by its shadow draws just that shadow;
  other motion redraws the window.
- Palette and quick open (zig-editor#fjkf): the first six rows stagger in 12 ms apart, and rows
  that move while filtering crossfade over 0.08 s.
- Split share spring k 260 c 30. The gap drag snaps to 1/2, 1/3 and 2/3 within 6 pt, and past a
  limit it rubber-bands at 0.3 of the pull, up to 24 pt, then springs back on mouse-up. A drop
  that splits starts at the previewed half with a kick of 0.3, the preview ring and the new ring
  crossfade over 0.15 s, and the copy flies to the new card's title.
- Sidebar edge: same rubber band as splits (0.3, 24 pt) with its own spring k 380 c 33, and
  dragging below 100 pt collapses it with the normal slide, restoring the saved width after.
- Zen: a `z` spring k 200 c 28 blends the text padding, header, card rings and the traffic
  lights' alpha. The sidebar material is covered by opaque chrome, not hidden.
- Tabs (zig-editor#gw33): grow spring c 25, with the tab's contents scaling 0.92 to 1 on it. Each
  tab's name width rides a spring k 420 c 34, so renames glide. Ink and weight follow the
  highlight spring as it lands. A button's click fill shows at once and fades over 0.15 s.
- Sidebar hover: spring k 700 c 53 (critically damped, no bounce). The selection fades its bold
  name in and out on the selection spring's distance (zig-editor#jpd4).
- Theme and appearance change: 0.25 s ease-in-out layer crossfade, skipped for Zen alone
  (zig-editor#ms1x). The drag ghost lifts to 1.04 on a spring k 500 c 28 with a real shadow, and
  the card shadow halves over 0.2 s when the window stops being key.
- Folds keep two records, the latest click's and the one before it, so clicks map through
  sliding rows and never snap a folder that's still opening or closing. Only a third folder
  folding at once, or a click on a folder that overlaps a folding folder's rows, finishes the
  older one early (zag#g0r3).
- Haptics (trackpad taps): alignment taps when a split gap or the sidebar edge reaches a snap
  point or limit, and when a dragged tab swaps places; a level tap when the drop zone changes
  kind. Never on typing, clicks or scrolling.

## Reduce Motion is not followed

Decided by Harsha on 2026-11-05: "I do not want to cater to Reduced Motion at all." The audit
(docs/design/2026-11-05-design-audit.md) suggested a crossfade-only mode, and we're not building
it. Increase Contrast is followed (zig-editor#ms1x). Don't add a Reduce Motion branch to any
animation.
