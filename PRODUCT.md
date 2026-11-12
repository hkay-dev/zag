# Product

<!-- impeccable:product-schema 1 -->

## Platform

web (the landing page). Zag itself is a native macOS app.

## Stack

Landing page: Next.js with Tailwind CSS v4 and React Bits Pro components, static export, in `site/`. Harsha chose this on 2026-11-11.

## Users

Developers and writers on a Mac (macOS 15+, Apple Silicon) who write and edit plain text, code and Markdown and want a small, fast native editor.

## Product Purpose

Zag is a free, MIT-licensed text editor for macOS, written from scratch in Zig. It edits text that you write. Success: a visitor understands what Zag is in one look and downloads the `.dmg`.

## Positioning

Zag is a text editor, not a text creator. It has no AI, no autocomplete, no snippets and no plugins: it doesn't write anything for you. It is opinionated (US English typing, Apple Silicon, system fonts, one way to do each thing) and tiny: the release binary is about 360 KB, links only Apple's system frameworks and libc, and still has splits, tabs, a sidebar, Quick Open, a command palette, Markdown preview, focus modes and themes.

## Operating Context

People open Zag from the Dock, Finder or a terminal (`zag notes.txt`, `zag .`), keep folders open in a sidebar, split cards, and write Markdown with a live preview window.

## Capabilities and Constraints

- macOS 15 (Sequoia) or newer, Apple Silicon only. No input methods (US English only).
- Release binary about 360 KB; `.dmg` about 306 KB.
- Features: cards and splits (⌘D, ⇧⌘D), draggable tabs, folder sidebar (⌘\), Quick Open (⌘P), Command Palette (⌘K), Find and Replace, Go to Line, Markdown Preview (⇧⌘M), Typewriter Scrolling, Focus dimming, Zen Mode (⌃⌘Z), Late-Night Focus (⌃⌘N), Format JSON, syntax highlighting for about 25 languages, safe atomic saves, drafts, session restore, VoiceOver, Increase Contrast.
- Themes: Paper, Ayu Light, One Light (light); Ink, Ayu Dark, One Dark, Black (dark).
- Version 0.1.0. Download link: a GitHub release URL, filled in when the repo goes public.

## Brand Commitments

- Free and open source: no selling, no pricing, no hype, no explaining basics (offline use, privacy and the like).
- Brag about size and lightness while staying full featured.
- Say plainly that Zag is opinionated and edits text rather than creating it, and explain that difference.
- Name: Zag (formerly ze). Icon: `AppIcon.icon`.

## Evidence on Hand

- Screenshot: `docs/assets/zag-hero.png` (Paper theme, sidebar and `editor.zig`).
- Real numbers: binary size, `.dmg` size, frameworks linked, from README and `docs/decisions/tiny-binary.md`.
- No testimonials, users, benchmarks or press exist. Don't invent any.

## Product Principles

1. Edit, don't generate.
2. Small on purpose: every feature pays for its bytes.
3. Feel like a Mac app: system fonts, system icons, native materials.
4. Motion with purpose: things glide instead of jumping.
