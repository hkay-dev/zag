# Product

<!-- impeccable:product-schema 1 -->

## Platform

web (the landing page). Zag itself is a native macOS app.

## Stack

Landing page: Next.js with Tailwind CSS v4 and React Bits Pro components, static export, in `site/`. Harsha chose this on 2026-11-11.

## Users

Developers and writers on a Mac (macOS 15+, Apple Silicon) who write and edit plain text, code and Markdown and want a small, fast native editor.

## Product Purpose

Zag is a free, MIT-licensed text editor for macOS, written from scratch in Zig. Developers and writers use it for code, notes and Markdown. Success: a visitor understands what Zag is in one look and downloads the `.dmg`.

## Positioning

Zag is a text editor, not an IDE. Developers and writers get split views, Quick Open, a command palette, syntax highlighting and Markdown preview without a debugger, build system or extension setup. Zag has no AI, autocomplete, linting, snippets or plugins. Its signed 0.1.0 release executable measures 388,624 bytes (380 KiB rounded) and links only Apple's system frameworks and libc. The site draws that executable at one pixel per byte and compares each editor's measured size on disk at the same scale. Harsha asked for the comparison in zag#m53k, which reversed zag#k842's choice to avoid it.

## Operating Context

People open Zag from the Dock, Finder or a terminal (`zag notes.txt`, `zag .`), keep folders open in a sidebar, split cards, and write Markdown with a live preview window.

## Capabilities and Constraints

- macOS 15 (Sequoia) or newer, Apple Silicon only. No input methods (US English only).
- Version 0.1.0 executable at 6130cad (2026-11-13): 436,560 bytes with its code signature (426 KiB rounded). App bundle: 477,646 bytes. Download: 366,957 bytes (358 KiB rounded).
- Features: cards and splits (⌘D, ⇧⌘D), draggable tabs, folder sidebar (⌘\), Quick Open (⌘P), Command Palette (⌘K), Find and Replace, Go to Line, Markdown Preview (⇧⌘M), Typewriter Scrolling, Focus dimming, Zen Mode (⌃⌘Z), Late-Night Focus (⌃⌘N), Format JSON, syntax highlighting for about 25 languages, safe atomic saves, drafts, session restore, VoiceOver, Increase Contrast.
- Themes: Paper, Ayu Light, One Light (light); Ink, Ayu Dark, One Dark, Black (dark).
- Version 0.1.0. Download link: a GitHub release URL, filled in when the repo goes public.

## Brand Commitments

- Free and open source: no selling, no pricing, no hype, no explaining basics (offline use, privacy and the like).
- Show size alongside the editing features. Explain that fuller development tools serve needs that Zag doesn't cover.
- Say plainly that Zag is an editor, not an IDE. Show code editing and writing as equally valid uses.
- Name: Zag (formerly ze). Icon: `AppIcon.icon`.
- Site appearance: follow the system theme by default and offer explicit Light and Dark choices.
- Site motion: one orchestrated move per section, built from licensed React Bits components. Respect reduced motion and offer a pause control.
- Site design: monochrome with hairlines, Scoutie Sans for text and Paper Mono for numbers and labels. Orange marks only Zag's own bytes and the download button. The page leads with a real picture of the app, then the one-pixel-per-byte square, the size comparison, what Zag leaves out, speed, and real screenshots, without sales copy or text that explains the design. Harsha approved this direction in zag#m53k, zag#chbm and zag#5amt.

## Evidence on Hand

- Screenshot: `docs/assets/zag-hero.png` (Paper theme, sidebar and `editor.zig`).
- Real numbers: binary size, `.dmg` size, frameworks linked, from README and `docs/decisions/tiny-binary.md`.
- No testimonials, users, benchmarks or press exist. Don't invent any.

## Product Principles

1. Support code and writing without becoming a full development environment.
2. Small on purpose: every feature pays for its bytes.
3. Feel like a Mac app: system fonts, system icons, native materials.
4. Motion with purpose: things glide instead of jumping.
