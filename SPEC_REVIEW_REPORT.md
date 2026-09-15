# Specification Review Report

> - **Subject:** `SPEC.md` v0.4 — mdv (Markdown viewer, native macOS GUI + CLI launcher)
> - **Reviewed at:** commit `fb5794b`, 2026-09-14 — third pass, after F-001..F-041 were applied and F-033/F-034 were fixed in the code (`f3c94de`)
> - **Method:** four passes per the `spec-review` skill. As in the second pass, every precise behavioural claim that had not yet been checked was verified against the cited implementation; two of the checks were run as small Swift scripts (`stripInlineMarkdown`, `headingSlug`). Finding ids continue from F-042; F-001..F-041 are listed as resolved in §3 and not re-argued.

## 1. Executive Summary

v0.4 closed the second pass cleanly: R-22 now describes the as-built heading-click model, the *open defect* convention exists in §11 and was used and then retired correctly, and the F-033/F-034 fix in `f3c94de` matches the rule the spec asked for (a failed read keeps the page; an empty read is re-checked after 0.5 s). The renderer, persistence, packaging and launcher surfaces are implementation-grade.

This pass swept the surfaces the first two did not verify line-by-line — window management, launch, menus, the find-bar internals, bookmark titles, the inline-Markdown stripper, the DB migration, the help file — and found the same class of defect as before, **the spec asserts behaviour the tree does not have**, in two places that matter and eleven that are smaller:

1. **Every command and every open event is broadcast to every window.** Menu items post `NotificationCenter` notifications; every `ContentView` subscribes with no key-window check (`mdv/ContentView.swift:3124-3162`), and `application(_:open:)` does the same (`mdv/mdvApp.swift:188-199`). With a second window open (⌘⇧O), `open -a mdv x.md` loads `x.md` into both windows, ⌘O raises two open panels in sequence, ⌘D creates two bookmarks and ⌘← walks both back-stacks. R-01's "into the active window's content view" and R-18's "per-window" stacks are not as built.
2. **A no-argument launch reopens the most recent history entry**, not the empty drop target (`mdv/ContentView.swift:525-530`). §3.1 says launch with no file enters `EMPTY`; no requirement states the restore; T-28 ("quit, relaunch: same position") depends on it without saying so. An implementer following the spec builds a different first screen.

The MEDIUM findings are precision items an implementer would otherwise guess: which block is a "heading block" (R-22), which in-document jumps push a back-snapshot (R-18), what happens when the displayed history row is swipe-deleted (§3.1), how find counts versus how it highlights (R-24), the bookmark title fallback (R-27, wrong constants), `_emphasis_` stripping (C-12, implementation bug), C-14's "never modally" (two modal alerts exist), the DB migration "same transaction" claim (no transaction), and a slug rule that diverges from GitHub on `a - b` (C-11).

- **Maturity:** Level 2 — the same one-fix-away position as v0.2, with a different pair of fixes.
- **Readiness:** READY WITH MINOR FIXES.
- **Findings this pass:** 0 CRITICAL · 2 HIGH · 11 MEDIUM · 7 LOW (20). Cumulative: 61, of which 41 resolved.
- **Strengths:** §4 contracts, §7.1 metric, the *open defect* convention, a §11 that now names symbols that exist; the F-034 fix is exactly the rule D-18 chose.
- **Weaknesses:** window/launch behaviour is specified from the single-window mental model the code comments admit to ("Single-window app, so a global `@AppStorage` matches"); the find bar and bookmark-title rules were written from intent rather than from the code.

## 2. Overall Maturity

**Level 2 — Implementable.** The document stays at Level 2 because a coding agent would build a materially different first screen (F-043) and a different multi-window behaviour (F-042) from the one shipped, and because eleven MEDIUM rules would be guessed differently by two implementers. Each is a sentence or a status marker away; with F-042/F-043 resolved and the MEDIUM rules pinned to the as-built behaviour, the document meets the Level 3 bar.

## 3. Findings Summary

### Resolved from earlier passes

F-001..F-041 — all applied (see `SPEC.md` revision history). Spot-checked this pass: F-032 (R-22 matches `isHeadingBlock`/`copySection`/`BlockTextSelection`; the 0.6 s flash and `NSCursor.pointingHand` are real), F-033 (`parseBlocks` normalises `\r\n` and `\r` before splitting, `mdv/ContentView.swift:2878-2881`), F-034 (a failed read returns without touching `rawMarkdown`; an empty read is re-checked after `transientReadWindow` = 0.5 s, `mdv/ContentView.swift:2752-2776`), F-036 (front-matter definition and §11 statuses present), F-038 (K-13 names the 8 pt handles), F-041 (rule citations by name).

### New in v0.4

| ID | Severity | Location | Title |
| -- | -------- | -------- | ----- |
| F-042 | HIGH | R-01, R-18, §5.1, E-20, §3.1 | Every command and open event is delivered to every window |
| F-043 | HIGH | §3.1 `EMPTY`, R-01, R-06, T-28 | No-argument launch reopens the most recent history entry; the spec says `EMPTY` |
| F-044 | MEDIUM | R-27 | Bookmark-title fallback is the first line stripped to 60 characters, `(line n)` when blank |
| F-045 | MEDIUM | C-12, R-21, R-27 (implementation) | `stripInlineMarkdown` removes only the opening `_` of `_emphasis_` |
| F-046 | MEDIUM | C-14, §5.1, R-23 | "Never modally" is false: CLI installer and editor-failure raise `NSAlert` |
| F-047 | MEDIUM | R-24, E-17 | Find counts occurrences on block source but highlights on rendered inline text; the current occurrence is not distinguished within a block |
| F-048 | MEDIUM | R-24, E-17 | Inline-highlight versus tint is decided by exclusion in the code, by inclusion in the spec |
| F-049 | MEDIUM | R-18, R-21, R-27, R-28 | Which in-document jumps push a back-snapshot is unspecified (TOC row: yes; bookmark, placeholder, find: no) |
| F-050 | MEDIUM | §3.1, R-20, R-26 | Swipe-deleting the displayed row switches document or empties the window; "history cleared" has no UI |
| F-051 | MEDIUM | §3.3 | `migrate()` does not run in a transaction |
| F-052 | MEDIUM | C-11, I-010, R-19 | Slug: whitespace adjacent to a hyphen yields no hyphen; `a - b` and `C++ & Rust` differ from GitHub |
| F-053 | MEDIUM | R-01, R-03, §5.2 | Several files in one open event, or several items in one drop: which is shown is unspecified |
| F-054 | MEDIUM | R-22, C-02 | "Heading block" is undefined; as built it means a `tocHeadings` block (h1–h3 single-line ATX) |
| F-055 | LOW | §5.1, E-09, T-26 | Back/Forward and Jump to Placeholder are never disabled; empty jumps beep, not no-op |
| F-056 | LOW | R-35, T-36 | Diagnostics list omits the font-registration and editor-failure `NSLog` lines |
| F-057 | LOW | R-05, E-21, T-29, K-06 | FSEvents `NoDefer` makes a burst up to two reloads, not one; the transient rule as built defers every empty read |
| F-058 | LOW | §3.3, R-31 | `Help.md` is rewritten on every ⌘?, so its scroll position is never restored |
| F-059 | LOW | front matter, §10, C-01, §1, §5.3 | Dependency, extension, and provenance details drifted from the tree |
| F-060 | LOW | R-02, R-26 | Directory ordering collation and filters; siblings are indexed although never "opened" |
| F-061 | LOW | §4, §12, §3.3, revision history | Editorial: C-15 before C-13, D-18 before D-17, v0.4 above v0.3, Unicode `≤` in a table row |

## 4. Detailed Findings

### F-042 — Every command and open event is delivered to every window

**Severity:** HIGH

**Location:** R-01 ("All routes MUST load the file into the active window's content view"); R-18 ("per-window back/forward stacks"); §5.1 (every row); E-20; §3.1 ("A window holds at most one current document")

**Observation**

Menu items in `mdvApp.swift` post process-wide notifications (`.openFile`, `.openURLInWindow`, `.findInDocument`, `.toggleBookmark`, `.navigateBack`, …). `NotificationHandlers` (`mdv/ContentView.swift:3124-3162`) subscribes every `ContentView` to every one of them with no check that its window is key; `AppDelegate.application(_:open:)` (`mdv/mdvApp.swift:188-199`) posts `.openURLInWindow` once per URL to the same audience. A second window is created by ⌘⇧O (`spawnNewWindow`, `mdv/ContentView.swift:2486-2500`) with its own `ContentView`. Consequences with two windows open: a Finder double-click, `open -a`, or `bin/mdv FILE` loads the file into **both** windows; ⌘O runs `NSOpenPanel.runModal()` twice in sequence; ⌘F opens both find bars; ⌘D adds a bookmark from each window's hovered/top block; ⌘← pops each window's stack; ⌘E opens the file twice. The comment at `mdv/mdvApp.swift:24-26` states the design assumption: "Single-window app".

**Why it matters**

R-01, R-18, R-24, R-27 and §5.1 all describe per-window behaviour that only holds while one window exists. A verifier running T-35 (same file in two windows) sees the reload half work and, on the next ⌘D, sees two bookmarks. An implementer building from the spec would add key-window routing that the tree lacks — or, reading E-20, might assume multi-window is a first-class mode.

**Potential consequence**

Duplicate bookmarks, duplicate history entries, stacked modal panels, and a file "opened" into a window the reader was not looking at.

**Recommended resolution**

Choose one and say it: (a) keep R-01/R-18 as the requirement and mark them *open defect* in §11 with the fix (route notifications to the key window's `ContentView`, e.g. by including the target `NSWindow` in the notification and comparing to `NSApp.keyWindow`, or by moving the commands to `@FocusedValue`); or (b) re-scope the spec to the as-built single-window model: state in §0 that multi-window (⌘⇧O) is a secondary surface in which menu commands and open events act on **every** window, and reword E-20/T-35 to match. Either way add an E row for "command issued with two windows open" and a T step for it.

### F-043 — No-argument launch reopens the most recent history entry; the spec says `EMPTY`

**Severity:** HIGH

**Location:** §3.1 `EMPTY` row ("Enters via: launch with no file"); R-01; R-06; T-28

**Observation**

`ContentView`'s appear handler (`mdv/ContentView.swift:525-530`): with no `initialURL`, `selectedEntry = history.entries.first` and the document is loaded. `EMPTY` is entered on launch only when history is empty. No requirement says the last-read file is restored at launch, yet T-28 ("scroll to the middle, quit, relaunch: same position") passes only because it is.

A likely secondary effect (not run, inferred from `onChange(of: selectedEntry)` at `mdv/ContentView.swift:318-340`): on a cold `open -a mdv x.md`, the main window first loads the history head, then receives `x.md`, so the previous session's file is pushed onto the back stack — ⌘← after a cold start goes to a file the reader did not open this session. Worth a T step.

**Why it matters**

The first screen is the most observable behaviour an application has; two implementers reading §3.1 would build the drop target, and T-28 would fail for them.

**Recommended resolution**

Add to R-01 (or a new R-40): "On launch with no file argument the application MUST load the first history entry (the most recently opened path) into the main window; it MUST show the `EMPTY` state only when history is empty." Change the `EMPTY` row's *Enters via* to "launch with empty history; deletion of the last history row (F-050)". Add the cold-start-with-argument case to T-22 or T-28 and say what ⌘← does afterwards.

### F-044 — Bookmark-title fallback is the first line stripped to 60 characters, `(line n)` when blank

**Severity:** MEDIUM

**Location:** R-27 ("else the block's own first 40 characters of source, else `(empty)`")

**Observation**

`bookmarkTitle(forBlockAt:)` (`mdv/ContentView.swift:2565-2593`): after the 40-block heading look-back, the fallback is the block's **first line**, passed through `stripInlineMarkdown` and trimmed, then `prefix(60)`; if that is empty the title is `(line <index+1>)`. `(empty)` is returned only when the document has no blocks at all. Headings found by the look-back are also passed through `MathMarkdown.plainText` and `stripInlineMarkdown` (R-27 does not say the title is the *display* text of C-02 rule 7, though R-21's TOC rule implies it).

**Why it matters**

Titles are user-visible and T-26 checks them; a verifier would expect 40 characters of raw source.

**Recommended resolution**

Rewrite the clause: "…else the block's first line with inline Markdown stripped (C-12), truncated to 60 characters; `(line n)` (1-based block index) when that is blank; `(empty)` when the document has no blocks. A heading title is its C-02 rule-7 display text." Move 60 into K-06.

### F-045 — `stripInlineMarkdown` removes only the opening `_` of `_emphasis_`

**Severity:** MEDIUM (implementation; spec wording also unclear)

**Location:** C-12 ("word-internal `_…_` markers"); `mdv/ContentView.swift:2962-2981`

**Observation**

The underscore rule is `(?<![A-Za-z0-9])_(?=[^_]+_)` — it matches the *opening* underscore of an `_…_` pair when not preceded by an alphanumeric, and nothing else. Run against the real function: `"_foo_ bar"` → `"foo_ bar"`; `"snake_case_name"` → unchanged (correct). So a heading `## _Draft_ notes` shows in the TOC and in bookmark titles as `Draft_ notes`. The slug is unaffected only by luck (`foo_` → `foo` after C-11's trailing-`_` strip; but `_Draft_ notes` → `draft_-notes`, which GitHub renders as `draft-notes` — a fragment written for GitHub misses).

The spec's phrase "word-internal `_…_` markers" describes the opposite of what the regex targets (it *excludes* word-internal underscores).

**Recommended resolution**

Spec: "…and `_…_` emphasis markers whose opening `_` is not preceded by a letter or digit (word-internal underscores are kept)". Implementation: also remove the closing underscore (e.g. `(?<![A-Za-z0-9])_([^_]+)_` → `$1`). Mark C-12 *open defect* in §11 until fixed; add `_Draft_ notes` to T-08 and to the T-22 slug cases.

### F-046 — "Never modally" is false: CLI installer and editor-failure raise `NSAlert`

**Severity:** MEDIUM

**Location:** C-14 ("User-visible failures are reported in place, never modally"); §5.1 *Install Command Line Tool…* ("failure: system beep, symlink untouched"); R-23

**Observation**

`CLIInstaller.install()` (`mdv/CLIInstaller.swift:17-48,100`) shows four different `NSAlert`s: "CLI helper missing", "Already installed", "Install failed" (with the AppleScript error), and a success alert "Command line tool installed"; the admin-rights path is an AppleScript `with administrator privileges` dialog. There is no beep. `openCurrentFileInEditor` (`mdv/ContentView.swift:1099-1112`) shows a modal alert "Couldn't open in external editor" with a *Choose Different Editor…* button. PNG-export failure does beep (`mdv/MermaidRenderer.swift:1093,1100`), and missing bookmarks beep (F-055).

**Why it matters**

C-14 is the cross-cutting rule a verifier applies everywhere; two counter-examples make it unusable as written, and §5.1's row is simply wrong.

**Recommended resolution**

Narrow C-14 to *document-derived* failures ("failures arising from document content are reported in place, never modally") and list the two modal cases as intended: "CLI-install outcomes and an external-editor launch failure are reported with an `NSAlert`". Fix the §5.1 row: "outcome alerts: helper missing / already installed / failed (message) / installed; admin auth via AppleScript; cancel leaves the symlink untouched".

### F-047 — Find counts on block source, highlights on rendered inline text, and never distinguishes the current occurrence within a block

**Severity:** MEDIUM

**Location:** R-24 ("Matching MUST be case-insensitive substring over each block's source … MUST highlight the matched characters … ⌘G MUST step per occurrence … and scroll the match into view")

**Observation**

`recomputeMatches` (`mdv/ContentView.swift:2339-2355`) counts occurrences over the raw block source, but a `SearchMatch` carries only `blockIndex` (`:272-274`). `highlightedAttributedString` (`:2296-2337`) strips heading/blockquote/list markers, parses the block as inline Markdown with `AttributedString(markdown:)`, and highlights every occurrence of the query in **that** text at one of two alphas: 0.55 when the current match's block is this block, 0.32 otherwise. Consequences a verifier will observe: (1) a query that matches only markup (`**`, a link URL, `# `) or crosses markup (`bo**ld**` vs `bold`) is counted but not highlighted, or highlighted but counted differently; (2) stepping ⌘G through three hits in one block changes "*n* of *m*" but nothing on the page moves or changes tint; (3) in highlight mode a heading with `$…$` shows LaTeX source, and an ordered list loses its numbers.

**Why it matters**

T-23 says "⌘G visits each" — a tester would expect a visible cursor. Two implementations (source-highlighting vs render-highlighting) both satisfy the R-24 sentence and behave differently.

**Recommended resolution**

State the as-built split: "*m* and the *n*-th step are computed on block source; the highlight is applied to the block's inline-rendered text (block markers stripped, inline Markdown interpreted, math shown as source), so a match inside markup may be counted but not highlighted. All occurrences in the current match's block share the stronger tint; the current occurrence is not otherwise distinguished; ⌘G scrolls the block into view." Or, if the intent is per-occurrence focus, mark R-24 *open defect* and store the source range in `SearchMatch`.

### F-048 — Inline-highlight versus tint is decided by exclusion in the code, by inclusion in the spec

**Severity:** MEDIUM

**Location:** R-24 ("Paragraph, heading, list, and blockquote blocks that contain no image MUST highlight…; every other block (code, table, and any block containing an image) MUST instead be tinted"); E-17

**Observation**

`shouldInlineHighlight` (`mdv/ContentView.swift:2275-2294`) inline-highlights **every** matching block except: a block starting with ` ``` ` or `~~~`; a block whose first line contains `|` and whose second line consists only of `-:| `; a block containing `![` anywhere. So a `$$` math-fence block, an HTML block, a thematic break, a setext heading, or a `<details>` block is inline-highlighted (rendered as inline text — display math becomes LaTeX source while the find bar is open), whereas the spec says "every other block" is tinted. The table test also differs from C-10's ("a `|---|` separator row").

**Recommended resolution**

Restate R-24/E-17 by exclusion: "A matching block is tinted as a whole when it is a code fence, a GFM table (first line contains `|`, second line only `-`, `:`, `|`, space), or contains `![`; every other matching block is inline-highlighted (F-047)". Decide whether a `$$` math-fence block should be tinted (it probably should — add it to the exclusion list and mark *open defect*, or accept and add it to E-17).

### F-049 — Which in-document jumps push a back-snapshot is unspecified

**Severity:** MEDIUM

**Location:** R-18 ("A same-document fragment jump MUST push a snapshot"); R-21 (TOC rows); R-27 (opening a bookmark); R-28 (⌘0)

**Observation**

`pushSameDocSnapshot` is called from two places: the TOC row button (`mdv/ContentView.swift:1962`) and a same-document `#fragment` click (`:2123`). A same-file bookmark jump (`jumpTo`, `:2679-2695`), ⌘0 (`:2719`), and ⌘G do **not** push, so ⌘← after ⌘1 does not return to where the reader was. R-18 names only the fragment case; R-21 is silent; the code comment calls a TOC click "like a same-doc fragment click". Also R-28: the placeholder is captured with the same `hoveredBlock ?? topVisibleBlock` rule as ⌘D and carries a path, so ⌘0 loads the placeholder's file if another is displayed — R-28's "at the current spot … return to it" does not say either.

**Recommended resolution**

R-18: "A same-document jump from a `#fragment` link **or a TOC row** MUST push a snapshot; jumps from a bookmark, the placeholder, or find stepping MUST NOT." R-28: "the placeholder anchor is chosen by the R-27 rule (hovered block, else topmost visible) and records the path; ⌘0 loads that file first if it is not displayed." Add the ⌘1-then-⌘← case to T-22 or T-26.

### F-050 — Swipe-deleting the displayed row switches document or empties the window; "history cleared" has no UI

**Severity:** MEDIUM

**Location:** §3.1 (`EMPTY` "Enters via: … history cleared"; `VIEWING` "Leaves via"); R-20; R-26 ("swipe-delete, clear")

**Observation**

`delete(_:)` (`mdv/ContentView.swift:953-959`): if the deleted row is the displayed one, `selectedEntry = history.entries.first` — the next most recent file is loaded (through the normal `LOADING` path, with a back-stack push and a scroll-position persist for the leaving file), or the window becomes `EMPTY` when the list is now empty. Neither transition is in §3.1. `HistoryManager.clear()` exists (`mdv/HistoryManager.swift:50-55`) but nothing calls it: there is no *Clear History* menu item or button, so the `EMPTY` row's "history cleared" and R-26's "clear" describe an unreachable path.

**Recommended resolution**

§3.1 `VIEWING` *Leaves via*: add "swipe-delete of the displayed row → `LOADING` of the new first history entry, or `EMPTY` if none". `EMPTY` *Enters via*: replace "history cleared" with "deletion of the last history row" (and F-043's launch case). R-26: drop "clear" or add the menu item to §5.1 and R-20. Add the deleted-current-row case to T-25.

### F-051 — `migrate()` does not run in a transaction

**Severity:** MEDIUM

**Location:** §3.3 ("`migrate()` MUST apply forward migrations by comparing it and bump it in the same transaction")

**Observation**

`Database.migrate()` (`mdv/Database.swift:174-213`) issues its `DROP`/`CREATE`/`ALTER`/`INSERT` statements as separate `exec` calls; the only `BEGIN`/`COMMIT` in the file wraps bookmark reordering (`:307,317`). A crash between the `ALTER TABLE` and the version bump leaves the schema at 4 and `schema_version` at 3; the next launch re-runs the `ALTER`, which fails ("duplicate column"), is logged, and the bump then succeeds — so the outcome is benign, but the "as-built MUST" is false and I-007's spirit (no partial state) is not what the code provides here.

**Recommended resolution**

Either wrap the migration block in `BEGIN IMMEDIATE … COMMIT` and keep the sentence, marking it *open defect* until then, or change the sentence to the as-built rule: "migrations are idempotent statements applied in order; the version is bumped last; a failed statement is logged (E-12) and does not stop the sequence".

### F-052 — Slug: whitespace adjacent to a hyphen yields no hyphen; `a - b` and `C++ & Rust` differ from GitHub

**Severity:** MEDIUM

**Location:** C-11; I-010; R-19; T-22

**Observation**

`headingSlug` (`mdv/ContentView.swift:2252-2273`) emits `-` for a whitespace run only when the previous emitted character is not `-`, and drops every other character silently. Run against the real function: `a - b` → `a--b` (GitHub: `a---b`); `a -- b` → `a---b`; `C++ & Rust` → `c-rust` (GitHub: `c--rust`); `a_ b` → `a_-b`. Because both the fragment and the heading go through the same function, links written **in mdv's dialect** resolve; links written for GitHub (`#a---b`, `#c--rust`) do not, and C-11's prose ("collapse runs of whitespace into one `-`") reads as the GitHub rule, not the code's. I-010 promises that "`#fragment` links written for GitHub resolve identically".

**Recommended resolution**

Decide: (a) match GitHub — every whitespace run becomes one `-` even after a `-` or a dropped character, and mark C-11 *open defect*; or (b) keep the code and write its rule precisely: "a whitespace run emits `-` only if the output is non-empty and does not already end in `-`". Add `a - b` and `C++ & Rust` to T-22 with the expected slugs.

### F-053 — Several files in one open event, or several items in one drop: which is shown is unspecified

**Severity:** MEDIUM

**Location:** R-01; R-03; §5.2 (`mdv FILE…`)

**Observation**

`application(_:open:)` posts one notification per URL in order; each `loadFile` adds a history row and sets `selectedEntry`, so all files land in history and the **last** URL is displayed (and, per F-042, in every window). `handleDrop` (`mdv/ContentView.swift:2813-2819`) reads `providers.first` only — a multi-item drop opens the first item and ignores the rest without error. R-03 says "a dropped item"; R-01 says "a file"; §5.2 says the app "receives them via LaunchServices" and stops.

**Recommended resolution**

R-01: "When an open event carries several URLs, each is added to history in the order received and the last is displayed." R-03: "Only the first item of a multi-item drop is considered." Add both to T-03/T-04.

### F-054 — "Heading block" is undefined; as built it means a `tocHeadings` block

**Severity:** MEDIUM

**Location:** R-22 ("Heading blocks MUST NOT be text-selectable; the pointer over a heading MUST be the pointing hand; a click on a heading…"); C-02

**Observation**

`isHeadingBlock(idx)` is `tocHeadings.contains { $0.blockIndex == idx }` (`mdv/ContentView.swift:1437`), i.e. only single-line ATX `#`–`###` blocks (C-02 rule 7). An `####` heading, a setext heading, or an ATX heading followed on the next line by a paragraph (same block, rule 7 uses the first line only — this one *is* a heading block) behave as prose: selectable, no hand cursor, no section copy. R-22 does not say which headings it means; a reader of R-07 ("GitHub-flavoured Markdown") would assume all six levels.

**Recommended resolution**

In R-22 replace "Heading blocks" with "TOC heading blocks (the blocks listed in `tocHeadings`, C-02 rule 7)"; add to E-22: "an h4–h6 or setext heading is also not clickable and is text-selectable like prose". Add an `####` click to T-30.

### F-055 — Back/Forward and Jump to Placeholder are never disabled; empty jumps beep, not no-op

**Severity:** LOW

**Location:** §5.1 rows *Navigate · Back / Forward* ("disabled when empty"), *Set Placeholder / Jump to Placeholder* ("Jump disabled when none"); E-09 ("opening it is a no-op"); T-26, T-27

**Observation**

The Back/Forward and Jump-to-Placeholder buttons in `mdvApp.swift:88-98,155-163` carry no `.disabled`; `goBack`/`goForward` return silently on an empty stack and `jumpToPlaceholder` beeps (`mdv/ContentView.swift:2719-2722`). A bookmark whose file is missing beeps (`:2634-2640`), as does an empty slot (`:2652-2656`) — though the slot buttons *are* disabled (`mdvApp.swift:173`), so the slot beep is unreachable from the menu. Zoom In/Out are disabled at the clamps, which §5.1 does not say.

**Recommended resolution**

Fix the three cells: Back/Forward "always enabled; no-op when the stack is empty"; Jump "always enabled; beeps when no placeholder"; E-09 "opening it beeps". Add "disabled at the limits" to the Zoom row. T-27: "⌘0 beeps" rather than "is disabled".

### F-056 — Diagnostics list omits the font-registration and editor-failure `NSLog` lines

**Severity:** LOW

**Location:** R-35 ("The only diagnostics it emits are `NSLog` lines on persistence-store failures (E-12) and the font-registration lines SwiftMath prints"); T-36

**Observation**

Other `NSLog` sites: `FontRegistration.swift:38,46` (`[mdv] missing bundled font: …`, `[mdv] register <font>: <error>`) and `ContentView.swift:1101` (`[mdv] failed to open in editor: <error>` — the `NSError` description can include the document path). `Database.swift:453` logs `indexFile insert failed for <path>` — a path, which R-35 does not forbid but T-36 tolerates only inside a `[mdv]` line (it is one). All start with `[mdv]`, so T-36 passes; R-35's "only" does not.

**Recommended resolution**

R-35: "…are `NSLog` lines prefixed `[mdv]` (persistence-store failures, E-12; bundled-font registration failures; external-editor launch failure, which may include the file path) and the SwiftMath font-registration lines."

### F-057 — FSEvents `NoDefer` makes a burst up to two reloads; the transient rule as built defers every empty read

**Severity:** LOW

**Location:** R-05 ("coalescing bursts of change events within 50 ms into one reload"; "within 500 ms of a previous change event"); E-21; T-29 ("five times within 50 ms: one reload"); K-06

**Observation**

The stream is created with `kFSEventStreamCreateFlagNoDefer` and latency 0.05 (`mdv/ContentView.swift:3200-3227`): the first event of a burst is delivered immediately and later events within 50 ms are batched into at most one more delivery. A five-save burst therefore produces up to two callbacks and — if the first read sees intermediate content — two reloads. The F-034 fix does not measure "500 ms since a previous event": it treats **every** zero-byte read (while the page is non-empty) as transient and re-reads after 0.5 s (`:2760-2772`); a genuinely emptied file is shown empty 0.5 s later, which is indistinguishable in practice but not what R-05 literally says. A file that becomes and stays undecodable keeps the old page indefinitely (until the next event); R-05 covers the 500 ms window only.

**Recommended resolution**

R-05: "events within 50 ms after the first are batched (at most two reloads per burst); a zero-byte read while content is displayed is re-read after 500 ms and whatever is read then is shown; an undecodable read is ignored and the page is kept until a later event yields a decodable file." T-29: "at most two reloads; the final content is displayed".

### F-058 — `Help.md` is rewritten on every ⌘?, so its scroll position is never restored

**Severity:** LOW

**Location:** §3.3 Help file row ("Written when: first ⌘? per launch"); R-31 ("copied on demand")

**Observation**

`HelpManager.openHelp()` (`mdv/HelpManager.swift:14-31`) deletes and re-copies the file on every call ("Always overwrite — keeps the content in sync with the running build"). Side effects: the file's mtime changes on each ⌘?, so the C-08 mtime check fails and Help always opens at the top; and if Help is already displayed, the overwrite fires the watcher and reloads it.

**Recommended resolution**

§3.3: "every ⌘? (overwritten)". Add to R-31 or E: "Help.md's scroll position is therefore not restored across ⌘? invocations." Or copy only when the bundled file differs (compare size/hash) and keep the §3.3 wording.

### F-059 — Dependency, extension, and provenance details drifted from the tree

**Severity:** LOW

**Location:** front matter; §10; C-01; §1 (Finder actor); §5.3; D-03

**Observation**

- Front matter says "SwiftTreeSitter 0.8"; `Package.resolved` has `swifttreesitter` 0.25.0 and `tree-sitter` 0.25.10 (§10's "from 0.8.0" is the manifest floor, not the pin).
- §10 and D-03 say "four documented patches"; `Vendor/SwiftMath/README.md` lists five code changes (new `MathFontBundle.swift`, `MathFont`/`MTFont` edits, public `MTMathAtom.init`, `\boxed` across four files) plus the font-bundle trim — T-34 uses the README, so state "the patches listed in the README" rather than a count.
- C-01 says document-type extensions `[md, markdown]`; `Info.plist` has `md, markdown, mdown`. §1's Finder row lists `.md`/`.markdown`.
- Front matter *Sources*: "git history through `a6feb14`" — the tree is at `fb5794b` and the spec cites `f3c94de`'s fix.
- §5.3: CI also runs on `pull_request` and `workflow_dispatch` (build only; the `latest` publish is push-to-`main`); `clean` also removes `build_icon/`.

**Recommended resolution**

Correct each; cite resolved versions in §10 alongside the floors.

### F-060 — Directory ordering collation and filters; siblings are indexed although never "opened"

**Severity:** LOW

**Location:** R-02 ("alphabetically-first"); R-26 ("index a file's content … when it is opened")

**Observation**

`loadDirectory` (`mdv/ContentView.swift:2519-2548`) skips hidden files, drops unreadable files, and sorts with `localizedCaseInsensitiveCompare` on the last path component — `B.md` sorts after `a.md`, which a byte-order implementation would not do. Sibling rows are added through `history.add`, which indexes them (`HistoryManager.swift:38`), so files that were never displayed are searchable; R-26's "when it is opened" should read "when it is added to history".

**Recommended resolution**

R-02: "…the first file by case-insensitive localized comparison of the filename, ignoring hidden and unreadable files…". R-26: "when it is added to history (open or directory sibling)".

### F-061 — Editorial

**Severity:** LOW

**Location:** §4 (C-15 sits between C-12 and C-13); §12 (D-18 sits between D-16 and D-17); revision history (v0.4 listed above v0.3); §3.3 Render caches row (Unicode `≤` in a normative table row — use `$\leq$`)

**Recommended resolution**

Reorder; replace the symbol.

## 5. Requirements Review

Requirements remain observable and, for the renderer and persistence surfaces, precise. The gap this pass exposes is **coverage of the shell**: launch (F-043), windows (F-042), multi-URL events (F-053), history deletion (F-050), and the back-stack policy for each kind of jump (F-049) are behaviours every reader meets on day one and none is written down. Two constants were written from memory rather than the code (F-044). Recommend, for v0.5, the same rule the second pass proposed and extend it: every R row that names a number or a menu-state is checked against the symbol §11 cites, and every §5.1 "disabled" cell is checked against a `.disabled` modifier.

## 6. Interface and Data-Contract Review

C-01 extension list is stale (F-059). C-03, C-04, C-05, C-08 (fingerprint 80, resolve rule, mtime `< 1.0`), C-13, C-15 and §5.2 were re-verified this pass and hold. One precision note on C-08: `file_mtime` is stored as `Int64(mtime)` (truncated to whole seconds) while the comparison uses the fractional current mtime, so the tolerance is effectively "same or next second" — within the 1 s the spec states, but a second write inside the same second is not detected; not a finding, worth a sentence.

## 7. State and Failure Review

§3.1 is missing the launch-restore entry (F-043), the delete-current-row transitions (F-050), and describes an unreachable "history cleared" entry. The F-034 rule is implemented as D-18 chose; its literal wording differs slightly from the code (F-057). C-14's universal "never modally" has two counter-examples (F-046). The multi-window case has no failure model at all (F-042).

## 8. Determinism and Algorithm Review

Verified deterministic and as specified: block split (incl. CRLF), TOC extraction, FTS query construction, fingerprint/resolve, language alias resolution, zoom clamps. Diverging from spec: `stripInlineMarkdown` (F-045), `headingSlug` around hyphens (F-052), find highlighting (F-047/F-048). §7.1 is unchanged and adequate.

## 9. Edge-Case Review

E-01..E-25 hold. New cases surfaced: two windows and one command (F-042); cold start with a file argument and the back stack (F-043); several URLs in one open event, several items in one drop (F-053); `####`/setext heading click (F-054); swipe-delete of the displayed row (F-050); a `$$` block matching a find query (F-048); an undecodable file that stays undecodable (F-057).

## 10. Non-Functional Requirement Review

Unchanged: K-03..K-13 values re-verified where they are code constants (256/2048/96/192/192 MB, 0.10/0.60/2.50, 0.05 s, 0.6 s, 40 blocks, 80 chars). K-06 should gain the bookmark-title 60-character cap (F-044) and the 0.5 s transient window is already there via D-18. No time-to-first-render bound — still an accepted omission.

## 11. Security and Trust-Boundary Review

Nothing new. R-19's click-opens-anything policy is as built. The CLI installer's AppleScript-with-admin path is worth one sentence in §5.1 (F-046) because it is the only privileged operation the GUI performs.

## 12. Observability and Provenance Review

R-35's inventory is incomplete but every line is `[mdv]`-prefixed (F-056). D-13 (bundle version fixed at 1.0.0) remains the provenance gap; `bin/mdv --version` therefore reports 1.0.0 for every build.

## 13. Testing and Verification Review

T-28 depends on unstated launch behaviour (F-043). T-23's "⌘G visits each" is not observable within a block (F-047). T-26/T-27 say "no-op"/"disabled" where the app beeps (F-055). T-35 does not exercise the command-routing half of multi-window (F-042). T-22 has no GitHub-dialect slug case (F-052). The suite (R-37) and harness (R-39) remain unbuilt, as §9.0 states.

## 14. Metrics and Evaluation Review

§7.1 unchanged; adequate.

## 15. Traceability Review

Scripted check at `fb5794b`: no id gaps (R-01..R-39, C-01..C-15, I-001..I-013, K-01..K-13, E-01..E-25, T-01..T-39, D-01..D-18), no dangling references, every I/K/E cited by a test, a §11 row for every R/C/I/K/E. §11's symbols were spot-checked and exist. §11 will need *open defect* rows again for whichever of F-042, F-045, F-051, F-052 the owner decides are code bugs.

## 16. Internal-Consistency Review

Contradictions: §3.1 `EMPTY` vs the launch code and T-28 (F-043); R-01 "active window" vs the broadcast design (F-042); C-14 vs two `NSAlert`s and §5.1's "beep" (F-046); §3.3 "first ⌘? per launch" vs always-overwrite (F-058); §3.3 "same transaction" vs no transaction (F-051); C-01 `[md, markdown]` vs `Info.plist` (F-059); R-27's 40/`(empty)` vs 60/`(line n)` (F-044). Numeric agreement across sections otherwise holds.

## 17. Architecture Review

Sound for the single-window product the code was written as. The notification-broadcast command bus is the one architectural choice that contradicts the spec's per-window language; the fix (route to the key window, or adopt `@FocusedValue`/`FocusedBinding` commands) is local. The `mdvCore` split for R-37 is still the enabling change and would also give the harness (R-39) a real library to link.

## 18. Implementation-Agent Readiness

**YES — WITH MINOR CLARIFICATIONS.**

Minimum blocking questions:

1. What does the application show when launched without a file — the most recent history entry (as built) or the empty drop target (§3.1)? (F-043)
2. With two windows open, do menu commands and open events act on the key window (R-01/R-18 as written) or on every window (as built)? (F-042)

Non-blocking but to be recorded before claiming conformance: F-044..F-054 (pin each rule to the as-built behaviour or mark it *open defect*).

## 19. Quality Scorecard

| Dimension | Score |
| --------- | ----: |
| Scope clarity | 4 |
| Terminology | 4 |
| Requirement precision | 4 |
| Interface completeness | 4 |
| Data-contract completeness | 4 |
| State/lifecycle definition | 3 |
| Algorithm precision | 4 |
| Failure semantics | 3 |
| Edge-case coverage | 3 |
| Non-functional requirements | 3 |
| Security specification | 3 |
| Observability/provenance | 3 |
| Testability | 4 |
| Evaluation/metrics | 4 |
| Traceability | 4 |
| Internal consistency | 3 |
| Architecture consistency | 4 |
| Implementation readiness | 3 |

Internal consistency rises from 2 to 3: the v0.2 divergences are gone, and the new ones are narrower in scope (window/launch shell, find internals) though one of them (F-042) is as consequential. State/lifecycle drops from 4 to 3 for the two missing transitions and the wrong `EMPTY` entry.

## 20. Remediation Plan

### P0 — Blocking

- **F-043** — state the launch-restore rule in R-01 and fix the `EMPTY` row; add the cold-start-with-argument case to a test.
- **F-042** — decide key-window routing (open defect) or single-window scope (respecify); either way add an E row and a T step.

### P1 — Important

- **F-044**, **F-054** — pin R-27's title rule and R-22's "heading block" to the code.
- **F-045**, **F-052** — decide GitHub-compatibility for `_emph_` stripping and hyphen-adjacent slugs; mark *open defect* or respecify; add T cases.
- **F-046** — narrow C-14; fix the §5.1 CLI-install row.
- **F-047**, **F-048** — restate R-24/E-17 as built (count on source, highlight on rendered text, exclusion list), or mark *open defect* for per-occurrence focus and `$$` tinting.
- **F-049**, **F-050**, **F-053** — enumerate which jumps push a snapshot; add the delete-current-row transitions; define multi-URL/multi-drop.
- **F-051** — wrap `migrate()` in a transaction (open defect) or reword §3.3.

### P2 — Improvement

- **F-055..F-061** — editorial and inventory corrections.

## 21. Final Verdict

```text
Specification maturity:
Level 2

Implementation readiness:
READY WITH MINOR FIXES

Primary blocker:
The launch and multi-window shell is specified from a single-window mental model the code does not fully share — a no-argument launch reopens the last file (§3.1 says EMPTY, F-043) and every command reaches every window (R-01 says the active one, F-042).

Most important improvement:
Pin the eleven MEDIUM rules (bookmark title, heading-block definition, find count-vs-highlight, snapshot policy, delete-current-row, slug hyphens, _emph_ stripping, migration transaction, C-14 modality, multi-URL open) to the as-built behaviour or to an open-defect marker, so that the next pass finds nothing left to verify by reading code.
```
