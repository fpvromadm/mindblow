# MindBlow

A native macOS mind-mapping app in the spirit of MindMeister. Built with SwiftUI — no dependencies.

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![license](https://img.shields.io/badge/license-MIT-green)

## Features

- Classic mind-map layout: central topic, branches balanced left/right, auto-layout as you type
- MindMeister-style visuals: colored branches, curved connectors, filled level-1 topics
- Map and outline views of the same document, with find (⌘F) and tag filtering
- Keyboard-first editing:
  - **Tab** — add a child topic
  - **Return** — add a sibling topic
  - **Space** or **double-click** — edit the selected topic
  - **Just start typing** — replaces the selected topic's text
  - **⌫** — delete a topic (and its subtree)
  - **Arrow keys** — navigate the map
  - **⌘↩** — close a topic (and reopen it)
  - **Esc** — cancel editing / deselect
- Per-topic detail: notes (Markdown), due dates with an agenda sidebar, tags, links,
  an emoji icon, and an inline image
- **Cross-links** — ⌥-drag from one topic to another to connect them; dashed,
  labelled connectors that live outside the hierarchy
- **Focus mode** — ⌘↓ drills into a branch and treats it as the whole map,
  ⌘↑ steps back out; a breadcrumb shows where you are
- **Multi-select** — ⇧/⌘-click, ⇧-drag a marquee, or ⌘A; then recolor, tag,
  close, delete, or drag the whole set at once
- **Copy & paste as an outline** — ⌘C/⌘X/⌘V move whole subtrees, and pasting
  Markdown or indented text from anywhere else builds a map from it
- **Export** — PNG, PDF, Markdown, or OPML (toolbar ⋯ menu)
- **Progress rings** — a branch shows how much of its subtree is closed
- Collapse/expand branches (badge shows hidden topic count)
- Pan (drag the canvas), pinch to zoom, zoom controls + Center in the toolbar
- Document-based: multiple windows, autosave prompts, **Undo/Redo (⌘Z / ⇧⌘Z)**, Open Recent
- Saves as `.mindblow` files (plain JSON — easy to inspect, diff, or script)

## Build & run

Requires macOS 14+ and Swift 6 (Xcode 16 or the matching command-line tools).

```sh
git clone https://github.com/fpvromadm/mindblow.git
cd mindblow
./scripts/make-app.sh     # builds and installs /Applications/MindBlow.app
open /Applications/MindBlow.app
```

The bundle is ad-hoc signed, so on first launch macOS may ask you to confirm
opening it (right-click → Open, or System Settings → Privacy & Security).

For development: `swift build`, `swift run`, and `swift test` (running from the
bundle is recommended so the `.mindblow` file type is registered).

## Project layout

```
Sources/MindBlow/
  MindBlowApp.swift      — app entry (DocumentGroup scene)
  Model.swift            — MindNode tree, cross-links, FileDocument (JSON)
  Layout.swift           — mind-map layout engine + palette/metrics
  EditorView.swift       — canvas, gestures, keyboard handling, toolbar
  NodeView.swift         — one topic bubble with its badges and affordances
  OutlineView.swift      — the outline presentation of the same document
  OutlineText.swift      — subtree ⇄ indented text (copy/paste, Markdown)
  MapCommands.swift      — clipboard, selection, and icon-palette helpers
  Export.swift           — Markdown/OPML text + a Core Graphics map renderer
  ImageStore.swift       — image downscaling on import, decode cache
  InlineTextEditor.swift — AppKit-backed inline node editor
scripts/
  Info.plist             — bundle metadata + .mindblow document type
  make-app.sh            — builds and installs the .app bundle
```

### File format

A `.mindblow` file is the root `MindNode` encoded as JSON. Once a map has
cross-links it becomes `{ "root": …, "links": [...] }` instead. Both forms are
read, and the wrapper is only written when there is something to wrap — so a map
without cross-links stays byte-identical to what earlier versions produced.
Topic images are stored inline (base64), downscaled to a 640px long edge on
import so the document stays small enough to diff and mail.

## License

MIT © 2026 [fpvromadm](https://github.com/fpvromadm) — free to use, modify, and
share. See [LICENSE](LICENSE).
