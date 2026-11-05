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
