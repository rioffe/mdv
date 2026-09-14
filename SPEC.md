# SPECIFICATION — mdv (Markdown viewer, native macOS GUI + CLI launcher, Swift/SwiftUI)

> - **Status:** v0.1 — as-built specification of the system at commit `a6feb14` (branch `main`, 2026-09-14), drafted for review
> - **Language / stack:** Swift 5.9 (SwiftPM, no Xcode project) | SwiftUI + AppKit | MarkdownUI 2.4.1 (cmark-gfm) · SwiftTreeSitter 0.8 + nine vendored tree-sitter grammars · beautiful-mermaid-swift 1.0.4 (ELK layout) · SwiftMath 1.7.3 (vendored, patched) · SQLite (FTS5) | surfaces: macOS app bundle, `bin/mdv` shell launcher, `make` targets
> - **Sources:** `README.md`; `mdv/Help.md` (user-facing behaviour); `NOTES.md` (library gaps and their work-arounds); `TYPOGRAPHY.md` (theme conventions); `plans/CODEVIEW.md` (code-block design); `Vendor/SwiftMath/README.md`; the implementation in `mdv/*.swift`, `bin/mdv`, `build.sh`, `Makefile`, `Package.swift`, `.github/workflows/build.yml`; git history through `a6feb14`
> - **Scope of this document:** the observable behaviour of the mdv application and its launcher — file opening, rendering (Markdown, code, Mermaid, LaTeX), navigation, find and search, history, bookmarks, persistence, theming, packaging and release. It does **not** specify the internals of the third-party renderers beyond the contracts mdv relies on, nor the visual design values of individual themes (those live in `TYPOGRAPHY.md`).
> - **Normative language:** MUST/MUST NOT/SHALL/SHALL NOT = normative; SHOULD = strong recommendation; MAY = optional.
> - **Principle:** *Native and honest.* Every pixel is drawn by AppKit/SwiftUI/CoreText — no WebView, no JavaScript bridge — and when a renderer cannot handle an input, the user sees the source, never a blank.

---

## 0. Intent and purpose

mdv is a macOS application for *reading* Markdown. It renders a `.md` file the way a good document viewer renders a PDF: typographically deliberate, fast to open, with the navigation aids a long technical document needs (table of contents, in-document find, cross-file full-text search, bookmarks, back/forward history) and without any editing surface. It is meant to be the default handler for `.md` files on a developer's Mac, reachable from Finder, from the terminal (`mdv FILE`), and from other Markdown files via links.

The renderer is a pipeline of native components: cmark-gfm (via MarkdownUI) for Markdown, tree-sitter for code syntax highlighting, an ELK-based layout library for Mermaid diagrams, and a CoreText math typesetter for LaTeX. Each of those libraries has gaps relative to what real documents contain (Mermaid.js syntax, amssymb, `<br/>` in labels, …); mdv owns a **sanitising and repair layer** in front of each one so that documents written for GitHub or Mermaid.js render faithfully, and a **fallback rule** so that anything the layer cannot repair is shown as its source text with an explanation rather than dropped.

**Non-goals.** mdv does not edit Markdown (it hands off to an external editor); it does not render HTML blocks beyond what cmark-gfm passes through as text; it does not fetch remote images unless the user opts in; it does not sync anything off the machine; it is not sandboxed for the App Store (it reads arbitrary user files and installs a CLI symlink).

**Trust boundary.** Everything the application processes — file contents, link targets, image URLs, Mermaid and LaTeX source — is untrusted document content. The only network activity is the user-enabled remote-image fetch (R-16) and the release pipeline (§10). The application never executes document content.

## 1. Actors and goals

| Actor | Goals |
| ----- | ----- |
| **Reader** (human, GUI) | Open Markdown files by any route, read them with good typography, move around them quickly, find text within and across files, keep places, and get back to files read before. |
| **Terminal user** (human, `bin/mdv`) | Open one or more files, a directory, or stdin from a shell in the running application; query the version; install the launcher once. |
| **Finder / LaunchServices** (`com.mdv.app` document-type registration) | Route double-clicks, drag-onto-icon, and `open -a` of `.md`/`.markdown`/`net.daringfireball.markdown`/`public.plain-text` items into the application. |
| **External editor** (any macOS app the reader chooses) | Receive the current file on ⌘E; its saves are picked up by the live-reload watcher. |
| **Document author** (indirect) | Their GitHub-flavoured Markdown, Mermaid.js diagrams, and LaTeX math render as they would on GitHub / mermaid.live, or degrade visibly. |
| **Release engineer** (human, `make dist`, CI) | Produce a signed, notarised, stapled `.zip` from an exact `vX.Y.Z` tag; CI builds every push to `main` and publishes a rolling `latest` prerelease. |
| **Persistence store** (SQLite at `~/Library/Application Support/mdv/mdv.db`, `UserDefaults`) | Durably hold history, the full-text index, bookmarks, per-file scroll positions, and preferences across launches. |

## 2. Requirements (intent, high level)

Sources are cited as `[Help §…]`, `[README]`, `[NOTES]`, or a file path in `mdv/`.

### 2.1 Opening and loading

| ID | Statement |
| -- | --------- |
| **R-01** | The application MUST open a Markdown file from every one of: File → Open… (⌘O), Open in New Window… (⌘⇧O), a LaunchServices open event (Finder double-click, drag onto the icon, `open -a`), a file dropped onto the window, a same-directory Markdown link clicked inside a document, a history-sidebar row, a search hit, and a bookmark. All routes MUST load the file into the active window's content view; only ⌘⇧O creates a window. `[Help §Opening files; mdv/mdvApp.swift application(_:open:)]` |
| **R-02** | When the opened path is a **directory**, the application MUST load `README.md` (case-insensitive match on the stem) if present, else the alphabetically-first file whose extension is `md`, `markdown`, or `mdown`, and MUST add every other such file in that directory to history as a sibling (R-20). `[Help §Opening files; ContentView.loadDirectory]` |
| **R-03** | A dropped item MUST be accepted only when its extension (case-insensitive) is one of `md`, `markdown`, `txt`, `mdown`, `mkd`; other drops MUST be ignored without error. `[ContentView.handleDrop]` |
| **R-04** | The file MUST be read as UTF-8. The document MUST be split into **blocks** once per load (C-02) and every per-frame consumer (rendering, find, TOC, bookmarks) MUST read the cached split, never re-parse. `[ParsedDocument; commit 38df878]` |
| **R-05** | While a file is displayed, the application MUST watch it and reload its content when the file changes on disk, coalescing bursts of change events within 50 ms into one reload. A reload MUST keep the reader's scroll position. `[FileWatcher; Help §Editor integration]` |
| **R-06** | On load, the application MUST restore the reader's last scroll position for that path (C-08) when the stored anchor still resolves (E-08); otherwise it MUST start at the top. On window close or quit it MUST persist the current position. `[ContentView.persistScrollPosition]` |

### 2.2 Rendering

| ID | Statement |
| -- | --------- |
| **R-07** | Markdown MUST be rendered as GitHub-flavoured Markdown (cmark-gfm: tables, task lists, strikethrough, autolinks, footnotes) using the active theme's typography (R-27). `[README; ThemeManager.markdownTheme]` |
| **R-08** | Fenced code blocks MUST be syntax-highlighted with tree-sitter for the languages in K-05 (with the alias map in C-05), and MUST render as plain monospaced text — never an error — for any other or missing language hint. The block MUST show a language label, a hover-revealed toolbar (wrap toggle, copy), and a context menu; blocks in a shell language whose lines are at least half `$ `/`# `-prompted MUST additionally offer *Copy Without Prompts*. `[CodeRenderer; CodeBlockChrome]` |
| **R-09** | A ` ```mermaid ` fence MUST render as a diagram image drawn natively (C-06). The block MUST offer: a style menu (Document, Light, Dark, Tokyo Night, Catppuccin — the choice persisted document-wide in `mdv.mermaid.style`), *Show Mermaid source* (toggles to a highlighted source view), *Export diagram as PNG*, copy source, and pinch-to-zoom between $0.5\times$ and $4\times$. `[Help §Diagrams and math; MermaidCodeBlockChrome]` |
| **R-10** | Before parsing, Mermaid source MUST be sanitised per C-06.1 so that the Mermaid.js constructs listed there render; after layout, the corrections in C-06.2 MUST be applied. A diagram whose source the library cannot parse (e.g. `timeline`, `gantt`, `pie`, `mindmap`) MUST render the fallback: the text "Mermaid diagram could not be rendered" and the source in monospace. `[NOTES §Mermaid]` |
| **R-11** | A diagram MUST be rasterised at the exact width it is displayed at — its natural width, or the column width minus 36 pt if narrower, floored to whole points — at the screen's backing scale, and re-rasterised when that width or the committed zoom changes. It MUST NOT be drawn wider than its natural width. `[NOTES §Resolution; MDVMermaidDiagramView]` |
| **R-12** | LaTeX math delimited by `$…$` (inline) and `$$…$$` (display) MUST be typeset natively with SwiftMath in every block type — paragraphs, headings, list items, blockquotes, table cells — following the delimiter rules in C-07. Display math on its own paragraph MUST be centred and MUST offer *Copy LaTeX* in its context menu. `[Help §Diagrams and math; MathRenderer]` |
| **R-13** | Math inside an ATX heading MUST be sized by that heading's em factor (C-09); elsewhere by the body size times the zoom factor (R-30). Math colour MUST be the theme's text colour. `[MathMarkdown.rewrite]` |
| **R-14** | LaTeX that SwiftMath rejects MUST render as its source (`$…$` delimiters included) in monospace; a display block MUST additionally show the parser's message. Before typesetting, the command rewrites and symbol registrations of C-07.2 MUST be applied. `[MathImageCache.typeset; MathSymbols]` |
| **R-15** | A node label in a Mermaid flowchart or state diagram that is exactly one `$$…$$` span MUST be typeset with SwiftMath and composited centred in the node at the same pixel weight as document math (I-009). Math mixed with text, and math in edge labels, MUST be rendered as the Unicode approximation of C-07.3. `[NOTES §LaTeX in labels]` |
| **R-16** | Images MUST resolve `data:` URIs inline and relative paths against the document's directory. `http(s)` images MUST NOT be fetched unless View → *Load Remote Images* is on; when off, a clickable "Remote image blocked" placeholder MUST be shown instead. A missing local image MUST show an "image not found" placeholder naming the file. An image MUST NOT be scaled above its intrinsic size. `[LocalImageProvider; mdvApp View menu]` |
| **R-17** | When View → *Smart Typography* is on **and** the active theme allows it, prose blocks MUST be rendered with curly quotes, en/em dashes, and ellipses per C-10; fenced/inline code, GFM table blocks, thematic-break lines, link URLs, and `<…>` spans MUST be left verbatim. Math spans MUST be rewritten to image references *before* smartening so LaTeX is never altered. `[SmartTypography.swift; ContentView.blockView]` |

### 2.3 Navigation and selection

| ID | Statement |
| -- | --------- |
| **R-18** | The application MUST maintain per-window back/forward stacks of visited files (⌘← / ⌘→, Navigate menu) and MUST push a snapshot before a same-document fragment jump so ⌘← returns to the previous position. `[Help §Moving around]` |
| **R-19** | Clicking a link MUST: navigate in-app when the target resolves to an existing local file with extension `md`/`markdown`/`mdown`; scroll to the heading whose GitHub-style slug (C-11) equals the fragment when the link is `#fragment`; and otherwise hand the URL to the system opener. Relative targets MUST be resolved by path arithmetic against the document's directory. `[ContentView.handleLinkClick]` |
| **R-20** | The history sidebar MUST list every file opened, most recent first, capped at 100 entries, persisted across launches; a row MUST support swipe-to-delete. The sidebar MUST be collapsible (⌃⌘S, View menu, hover chevron) with the collapsed state persisted, and resizable by dragging its divider between 180 and 400 pt. `[HistoryManager; Help §Sidebars]` |
| **R-21** | The inspector MUST show a table of contents of the document's single-line ATX `#`, `##`, `###` headings (C-02), each row jumping to its block, with a search field that filters rows; and a collapsible bookmarks pane with a draggable height. The inspector's visibility and width (180–520 pt, dragged at its left edge) MUST persist. Heading text in the TOC MUST show math as Unicode (C-07.3), not as LaTeX source. `[Help §Sidebars; commit bcd2150]` |
| **R-22** | Reader text selection MUST work as in any text view, and additionally: a single click on a heading MUST copy that heading's section (C-12) as Markdown to the pasteboard and flash the section for 0.6 s; a double-click MUST select the section; a drag across blocks MUST select whole blocks, expanding to include any section whose heading falls in the range; ⌘A MUST select every block; ⌘C MUST copy the selected blocks' source joined by blank lines; Esc MUST clear the selection. `[commits bae06a7, c50817a]` |
| **R-23** | ⌘E MUST open the current file in the chosen external editor; File → Edit → *Choose Editor…* picks one and *Forget Editor* clears it; with no editor set, ⌘E MUST prompt to choose. `[Help §Editor integration]` |

### 2.4 Find, search, bookmarks

| ID | Statement |
| -- | --------- |
| **R-24** | ⌘F MUST open an in-document find bar. Matching MUST be case-insensitive substring over each block's source; the bar MUST show "*n* of *m*" (or "No matches"), ⌘G / ⇧⌘G MUST step forward/back and scroll the match into view, Esc MUST close. Blocks that are paragraphs, headings, lists, or blockquotes MUST highlight the matched characters; code, table, and image blocks MUST instead be tinted as a whole. When the sidebar (not the document) was last focused, ⌘F MUST route to the global search field. `[Help §Find; ContentView find]` |
| **R-25** | ⌘⇧F MUST focus a search field that queries the full-text index of every file in history (C-03): tokens are prefix-matched and ANDed; results (at most 80) MUST show the filename and a snippet with matched terms highlighted; choosing a result MUST open the file. `[Help §Find; Database.search]` |
| **R-26** | The application MUST index a file's content into the full-text index when it is opened and re-index history on launch, skipping any file whose modification time is unchanged since its last indexing. `[Database.indexFile]` |
| **R-27** | ⌘D MUST add a bookmark at the block currently at the top of the viewport, titled by the nearest preceding heading (or the filename), anchored by block index *and* fingerprint (C-08). Bookmarks MUST persist in order; the first five MUST be bound to ⌘1…⌘5 (Bookmarks menu shows their titles); rows MUST be reorderable by drag and removable. Opening a bookmark MUST load its file if needed and scroll to the resolved anchor (E-08). `[Help §Bookmarks; BookmarksManager]` |
| **R-28** | ⌘⇧0 MUST set a transient in-memory placeholder at the current spot and ⌘0 MUST return to it; the placeholder MUST NOT survive relaunch. `[Help §Bookmarks]` |

### 2.5 Appearance and preferences

| ID | Statement |
| -- | --------- |
| **R-29** | The reader MUST be able to choose one of the nine named themes or *System* from the toolbar; *System* MUST resolve to `high-contrast` in Light appearance and `twilight` in Dark and MUST switch live when macOS appearance changes. Each theme MUST restyle the article pane, code palette, and the diagram *Document* style; the choice MUST persist (`mdv_theme_id`). `[ThemeManager; TYPOGRAPHY.md]` |
| **R-30** | ⌘= / ⌘- MUST scale body text by $\pm 0.10$ per step, clamped to $[0.60, 2.50]$; View → Actual Size MUST reset to $1.0$; the factor MUST persist (`mdv_font_scale`) and MUST also scale document math (R-13). A zoom HUD MUST show the percentage for about 0.9 s after each change. `[ThemeManager fontScale]` |
| **R-31** | ⌘? (Help → mdv Help) MUST open the bundled `Help.md`, copied on demand to `~/Library/Application Support/mdv/Help.md` so it has a stable path for history and bookmarks. `[HelpManager]` |
| **R-32** | Every preference in C-04 MUST persist via `UserDefaults` under the listed key and MUST be honoured on the next launch. |

### 2.6 Launcher, packaging, diagnostics

| ID | Statement |
| -- | --------- |
| **R-33** | `bin/mdv` MUST implement the surface in §5.2: locate the app bundle per the documented search order, open files/directories by absolute path, read stdin into a temporary `.md` for `-`, print the bundle version for `--version`, and exit `1` with `mdv: no such file: <path>` on stderr for a missing argument. `[bin/mdv]` |
| **R-34** | `make` (default) MUST build a runnable `build/mdv.app` from a clean checkout with only the Swift toolchain, copying every resource the app needs (C-13); `make install` MUST place it in `/Applications`, register it with LaunchServices, and symlink the CLI; `make dist` MUST refuse to run unless `HEAD` carries an exact `vX.Y.Z` tag. `[Makefile; build.sh]` |
| **R-35** | The application MUST NOT print document content, file contents, or query strings to any log at any verbosity. The only diagnostics it emits are `NSLog` lines on persistence-store failures (E-12) and the font-registration lines SwiftMath prints once per font on first use. |
| **R-36** | The application MUST NOT crash on any document: a repair layer failure MUST degrade to the fallback of R-10/R-14, and every path that reaches a third-party parser MUST be preceded by the sanitisation that keeps that parser inside its asserted invariants (E-01). `[NOTES §Mermaid: ELK layout asserts]` |
