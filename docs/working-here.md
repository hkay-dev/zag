---
type: guide
summary: How agents check changes in zag.
---

# Working here

## How to check

- **Check:** `deckhand app check zag` runs the registered debug-build check.
- **Build wrapper:** Agents run `qm with build zag -- ./repo/scripts/check.sh` from `~/Development/incubator/zag`.
- **Quirks:** Stable Zag and Zag Dev have separate identities. Only Ship it changes stable Zag. Zag Dev stores its settings and session under `ZE_DEV_HOME`, which defaults to `/tmp/ze-dev-home`.
- **Hot paths:** Agents ask `reviewer` to review `src/files.zig` when changing file saves, replacement, permissions, extended attributes or ACL handling.
- **Devices:** The build needs no phone, Mac VM or browser. Harsha tests editing behavior on the Mac.
