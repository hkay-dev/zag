---
type: guide
summary: How agents check changes in zag.
---

# Working here

## How to check

- **Check:** `deckhand app check zag` runs the registered debug-build check.
- **Build wrapper:** Agents run `qm with build zag -- ./repo/scripts/check.sh` from `~/Development/incubator/zag`.
- **Quirks:** Stable Zag and Zag Dev have separate identities. Only Ship it changes stable Zag. Zag Dev stores its settings and session under `ZE_DEV_HOME`, which defaults to `/tmp/ze-dev-home`.
- **Zig rules:** Write Zig 0.17, not older Zig: grep `~/.local/share/mise/installs/zig/0.17.0/lib/std` before you call an unfamiliar std function. Release builds have no safety checks, so run the debug dev build on every new path. Save files through libc in `src/files.zig` only: atomic write, symlinks resolved, regular files only. Type every `objc.msg` literal (`@as(isize, 1)`); retain what you keep, release what you create. Build with `mise exec zig@0.17.0 -- zig build`; ReleaseFast or a new dependency needs Harsha's yes.
- **More Zig:** Read `skill://zig` only when your brief doesn't name a reference, then only the row you need: `reference/zig-0.17.md` (spellings), `data.md` (files), `safety.md` (UB, crashes), `appkit.md` (objc), `perf.md` (idle cost). Skip the rest.
- **Hot paths:** Agents ask `reviewer` to review `src/files.zig` when changing file saves, replacement, permissions, extended attributes or ACL handling.
- **Devices:** The build needs no phone, Mac VM or browser. Harsha tests editing behavior on the Mac.
