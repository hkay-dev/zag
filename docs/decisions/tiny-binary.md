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
- **System font** (SF Mono through `monospacedSystemFontOfSize:`) unless the settings file names
  another installed one. Nothing embedded.
- **libc for file I/O.** Taking `std.process.Init.Minimal` keeps `std.Io.Threaded` out of
  `main`, and reading, saving and the quick open walk use `open`, `read`, `mkstemp`, `rename`
  and `readdir` directly.
- **`panic = std.debug.no_panic` and `std_options_debug_threaded_io = null`** in the root file,
  release builds only. The defaults pull in a DWARF reader and every `std.Io.Threaded` function
  through its vtable. Together they were about half the binary: 218 KB before, 107 KB after.
- `main` returns `void`. An error return makes `start.zig` log through `std.log`, which needs the
  debug Io and brings it all back.
- **The caret is a `CALayer`** (zig-editor#scw1), so moving it never redraws the text, and its
  blink is a repeating opacity animation that runs in the window server.
- **One display link drives all motion** (zig-editor#hpsf, #rccc, #c3kx, #kf52). Each moving
  value is a small tween (from, to, start time, ease-out cubic). The link runs only while
  something moves and pauses itself after. When only the caret is gliding, a frame moves the
  caret layer and draws nothing; scrolling, the line band, a selection fade or the quick open
  list redraw the view. The caret used to glide by Core Animation's implicit animation, but its
  position has to follow the scroll as it eases, so it moved to the same tweens.
- **No float parsing or printing from std.** The settings file only needs numbers like `14` and
  `1.75`, and `std.fmt`'s float code was 16 KB of the binary, so `settings.zig` has a few lines of
  its own. The session's split shares came back in later through `{d:.3}` and `parseFloat`;
  writing thousandths as integers and reading them with `settings.number` took the file from
  349,552 to 332,224 bytes (zag#pg9f). Grep for both before adding a float to any text.
- **`headerpad_size = 0`.** The binary's size moves in 16 KB pages. Zig's default padding after
  the load commands was enough to push `__TEXT` past 64 KB when the caret code went in
  (107 KB to 123 KB on disk for 2.6 KB of code). Check `size -m` when the file jumps by a page.
  With settings, wrap, replace, motion, sessions and the sidebar in, the binary was about 162 KB;
  the command palette, appearance and the sidebar's system font took it to 183 KB (6 KB of code,
  the rest a page step).
- **Icons come from macOS.** Files and folders show the Mac's own icons from `NSWorkspace`
  (`iconForContentType:`, one per extension, kept) and the chevrons and buttons are SF Symbols
  tinted with the theme's muted color, so ze ships no images for them (zig-editor#a8g8).
- **The sidebar's names are off the grid** (zig-editor#5teh). They are `CTLine`s in the
  system font, made once per row and kept until the tree or the font changes, so a scroll frame
  draws them without laying anything out. They take the context's fill color, so a theme change
  keeps them. `CTLineDraw` leaves its position in the text matrix, which the grid's glyph runs
  also read, so drawing one resets the matrix after.
- **The command palette reads the menu bar** (zig-editor#2eb7). It lists the menus' items as it
  opens and runs a pick through `performActionForItemAtIndex:`, so every menu command is in it
  with no second list to keep in step.
- **Focus fades glyph colors, not the page** (zig-editor#r2cb). Two existing tweens move the
  range's byte endpoints; the glyph batch blends outside colors toward the background and leaves
  selection alone. No overlay or second text pass. Line means the logical line, so wrapping
  does not split it. On the split-card layout, release `__text` goes from 114,416 to 115,952
  bytes (+1,536); the file goes from 221,488 to 221,968 bytes.
- **Typewriter reuses the scroll tween** (zig-editor#ftkg). Its bounds let the first and last
  rows reach the middle, so the scroll goes negative at the top. The caret and line band take
  the scroll's timing so they move with the page. A wheel scroll alone doesn't recenter; a
  caret move, an edit or a new card height does. Release `__text` goes from 115,952 to 116,684
  bytes (+732); the file goes from 221,968 to 221,760 bytes.
- **Zen draws from a second, grey copy of the themes** (zig-editor#ge34), made only when the
  settings load, so the saved colors and the wrap and sidebar settings stay as they were. Zen hides
  the traffic lights with `setHidden:` and keeps the window's titled style, so ⌘W, zoom and
  dragging the top strip still work. The header's room stays as a plain top margin, so nothing
  else in the layout moves. Each split card centers its own 80 columns. Release `__text` goes
  from 116,684 to 117,640 bytes (+956); the file goes from 221,760 to 222,112 bytes.
- **Markdown preview uses Foundation's CommonMark parser and an NSTextView** (zig-editor#jfh1).
  Unlike md4c, cmark-gfm or WebKit, it adds no library and starts no web process. Release
  `__text` goes from 117,932 to 122,568 bytes (+4,636); the file goes from 222,240 to 223,248
  bytes.
- **No input methods.** ze is for US English typing on Apple Silicon only. It has no input
  method support (Chinese, Japanese or accented-letter composing), and none is planned. Harsha
  set this on 2026-11-05. VoiceOver came later (zig-editor#1xsq): `access.zig` makes its
  stand-in elements only when VoiceOver asks for them, so it does no work while VoiceOver is off.

## Gotchas

- In a flipped view the text matrix flips glyphs upright, and `CTFontDrawGlyphs` runs the
  positions through it too, so y goes in negated.
- `[NSApp activate]` only runs when there is no bundle. From `ze.app`, Launch Services brings the
  window forward, and `open -g` can keep it in the background for screenshots.
