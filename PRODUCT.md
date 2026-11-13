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

Zag is a text editor, not an IDE. Developers and writers get split views, Quick Open, a command palette, syntax highlighting and Markdown preview without a debugger, build system or extension setup. Zag has no AI, autocomplete, snippets or plugins. Its 0.1.0 release executable measures 370,400 bytes (362 KiB rounded) and links only Apple's system frameworks and libc. The site distinguishes executable size from the compressed download and avoids competitor rankings.

## Operating Context

People open Zag from the Dock, Finder or a terminal (`zag notes.txt`, `zag .`), keep folders open in a sidebar, split cards, and write Markdown with a live preview window.

## Capabilities and Constraints

- macOS 15 (Sequoia) or newer, Apple Silicon only. No input methods (US English only).
- Version 0.1.0 executable: 370,400 bytes (362 KiB rounded). Download: 313,068 bytes (306 KiB rounded).
- Features: cards and splits (⌘D, ⇧⌘D), draggable tabs, folder sidebar (⌘\), Quick Open (⌘P), Command Palette (⌘K), Find and Replace, Go to Line, Markdown Preview (⇧⌘M), Typewriter Scrolling, Focus dimming, Zen Mode (⌃⌘Z), Late-Night Focus (⌃⌘N), Format JSON, syntax highlighting for about 25 languages, safe atomic saves, drafts, session restore, VoiceOver, Increase Contrast.
- Themes: Paper, Ayu Light, One Light (light); Ink, Ayu Dark, One Dark, Black (dark).
- Version 0.1.0. Download link: a GitHub release URL, filled in when the repo goes public.

## Brand Commitments

- Free and open source: no selling, no pricing, no hype, no explaining basics (offline use, privacy and the like).
- Show size alongside the editing features. Explain that fuller development tools serve needs that Zag doesn't cover.
- Say plainly that Zag is an editor, not an IDE. Show code editing and writing as equally valid uses.
- Name: Zag (formerly ze). Icon: `AppIcon.icon`.
- Site appearance: follow the system theme by default and offer explicit Light and Dark choices.
- Site motion: use sparse animated ASCII backgrounds and licensed React Bits interactions. Respect reduced motion and offer a pause control.
- Site design: compact editorial layout, system typography and real interactive screenshots. Emphasize size and deliberate choices without a feature tour or sales copy. Harsha approved this direction in zag#k842.

## Evidence on Hand

- Screenshot: `docs/assets/zag-hero.png` (Paper theme, sidebar and `editor.zig`).
- Real numbers: binary size, `.dmg` size, frameworks linked, from README and `docs/decisions/tiny-binary.md`.
- No testimonials, users, benchmarks or press exist. Don't invent any.

## Product Principles

1. Support code and writing without becoming a full development environment.
2. Small on purpose: every feature pays for its bytes.
3. Feel like a Mac app: system fonts, system icons, native materials.
4. Motion with purpose: things glide instead of jumping.
