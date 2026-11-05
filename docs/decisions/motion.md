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

Short and ease-out, so nothing feels like it waits on the animation: 0.09 s for the caret, 0.12 to
0.2 s for fades, folds and the file fade-in, 0.24 s for the sidebar slide, 0.16 s for scroll
glides. A click during an animation acts at once: a closing folder finishes shutting first.
