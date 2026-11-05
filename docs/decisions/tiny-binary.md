---
type: decision
status: accepted
summary: Why ze talks to AppKit and libc directly and turns off Zig's default panic handler and debug Io.
---

# How ze stays small

ze is meant to be the smallest, fastest editor that still feels like a Mac app (zig-editor#mxc3).
Zikky, which it takes ideas from, runs on gooey's Metal renderer, embeds a font and links
Ghostty's terminal core. ze drops all three.

## Choices

- **No UI framework.** Windows, menus and events go through the Objective-C runtime
  (`objc_msgSend` cast to the real signature; Apple Silicon only, so there is no `_stret`).
- **CoreText glyph runs on a monospace grid**, drawn into the view's CGContext. One glyph per
  codepoint, one cell wide (two for East Asian wide and emoji), tabs to four. Layout is
  arithmetic, so a 1 MB line costs a walk, not a shaping pass. Missing glyphs fall back to the
  font CoreText picks for that character. No ligatures.
- **System font** (SF Mono through `monospacedSystemFontOfSize:`), nothing embedded.
- **libc for file I/O.** Taking `std.process.Init.Minimal` keeps `std.Io.Threaded` out of
  `main`, and reading, saving and the quick open walk use `open`, `read`, `mkstemp`, `rename`
  and `readdir` directly.
- **`panic = std.debug.no_panic` and `std_options_debug_threaded_io = null`** in the root file,
  release builds only. The defaults pull in a DWARF reader and every `std.Io.Threaded` function
  through its vtable. Together they were about half the binary: 218 KB before, 107 KB after.
- `main` returns `void`. An error return makes `start.zig` log through `std.log`, which needs the
  debug Io and brings it all back.
- **The caret is a `CALayer`** (zig-editor#scw1). Its glide is an implicit animation in a
  `CATransaction` and its blink is a repeating opacity animation, so both run in the window
  server: ze redraws nothing while the caret moves or blinks, and the code is about 2.6 KB.
- **`headerpad_size = 0`.** The binary's size moves in 16 KB pages. Zig's default padding after
  the load commands was enough to push `__TEXT` past 64 KB when the caret code went in
  (107 KB to 123 KB on disk for 2.6 KB of code). Check `size -m` when the file jumps by a page.

## Gotchas

- In a flipped view the text matrix flips glyphs upright, and `CTFontDrawGlyphs` runs the
  positions through it too, so y goes in negated.
- `[NSApp activate]` only runs when there is no bundle. From `ze.app`, Launch Services brings the
  window forward, and `open -g` can keep it in the background for screenshots.
