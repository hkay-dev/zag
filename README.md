# ze

A tiny native text editor for macOS on Apple Silicon, written in Zig, with tabs, split cards and
a file sidebar. The release binary is about 300 KB and links only Apple's own frameworks and
libc.

![ze](docs/assets/mxc3-after-light.png)

## Build

Needs Zig 0.17 and macOS 15 or later.

```sh
zig build --release          # zig-out/bin/ze
zig build test
scripts/dev.sh [files...]    # builds "ze Dev" and starts it in the background
scripts/ship.sh              # Ship it: installs the stable ze at ~/Applications/ze.app
```

Stable and dev builds are explained in [AGENTS.md](AGENTS.md).

The guide is in [docs/guide](docs/guide/index.md).
