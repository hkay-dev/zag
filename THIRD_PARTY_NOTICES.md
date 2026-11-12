# Third-Party Notices and Acknowledgments

Zag links only macOS system frameworks (`AppKit`, `QuartzCore`, `CoreGraphics`, `CoreText`, `CoreFoundation`, `Foundation`) and `libSystem` (`libc` / `libobjc`), and ships no third-party source code or runtime libraries.

## Inspirations

- **[Zikky](https://github.com/wielenmaker/Zikky)** by wielenmaker (MIT License) inspired several early product ideas for building a native Zig editor on macOS. Zag implements its own `objc_msgSend` bridge, `CoreText`/`CoreGraphics` renderer, gapless buffer, lexer, and UI from scratch.
- **Ayu** and **Atom One** color palettes inspired Zag's built-in `ayu-light`, `ayu-dark`, `one-light`, and `one-dark` color schemes in `src/settings.zig`.
