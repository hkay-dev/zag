# Zag 0.1.1

This release strengthens file saving, draft recovery, and editing, and reduces repeated work during drawing and navigation.

## Saved work

- Zag checkpoints drafts before quitting and pauses quit when a checkpoint fails.
- Duplicate Tab and Show Changes snapshots restore with the next session.
- Tab moves preserve unsaved text when Zag runs short of memory.
- Save As protects the saved file when its destination matches a draft’s backing file.
- File saves check replacement identity and preserve permissions, extended attributes, and ACLs. External-change detection also checks replacements that share a file’s size and timestamp.
- Session saving prepares every window before writing the session, and restores paths that contain tabs.
- Settings changes merge into edited configuration tabs across windows. Reset Settings puts a backup in Trash.

## Editing and navigation

- Editing, undo, and redo preserve text and history when memory allocation fails.
- Delete Line handles the last terminated line correctly. Cursor movement, deletion, and Find respect character boundaries around malformed UTF-8.
- Syntax highlighting handles multiline HTML attributes, Markdown fences, unfinished strings, and language-specific hash comments.
- Quick Open scans new folders in the background and refreshes after hidden-file changes.
- Sidebar and picker clicks follow the rows as they animate. Folder folds preserve their target through directory refreshes.
- Markdown Preview updates relative links after Save As and supports navigation through documents with more than 256 headings.

## Less repeated work

- Zag reuses syntax colors, wrapped-line indentation, caret-row calculations, and preview colors between draws.
- Find markers calculate row positions directly. Horizontal scrolling uses displayed columns for tabbed text.
- Sidebar highlights finish their animation when the sidebar closes.

## Install

Download `Zag-0.1.1-arm64.dmg`, open it, and drag Zag into Applications. Zag runs on Apple Silicon with macOS 15 or later.

Zag uses a self-signed certificate. Run this once if macOS blocks the first launch:

```sh
xattr -dr com.apple.quarantine /Applications/Zag.app
```
