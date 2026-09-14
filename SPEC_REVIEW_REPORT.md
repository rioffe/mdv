# Specification Review Report

> - **Subject:** `SPEC.md` v0.1 — mdv (Markdown viewer, native macOS GUI + CLI launcher)
> - **Reviewed at:** commit `d23015a`, 2026-09-14
> - **Method:** four passes (comprehension, local precision, cross-consistency, implementation simulation) per the `spec-review` skill; the as-built source was consulted where the spec cites it, to distinguish "the spec is imprecise" from "the spec contradicts the system it claims to describe".

## 1. Executive Summary

`SPEC.md` is an as-built specification of a mature application, and it reads like one: the contracts in §4 pin the things a re-implementer would otherwise reverse-engineer (block split, FTS query construction, the math URL scheme and delimiter rules, the full Mermaid sanitise/repair tables), every requirement cites a source, and every I/K/E id has a test. The traceability matrix is complete.

The weaknesses are of two kinds. First, a handful of **contradictions between sections** — the document lifecycle table says an unreadable file leads to `EMPTY` while E-03 and C-14 say the previous document stays; R-27 says a bookmark anchors at "the block at the top of the viewport" while the implementation anchors at the hovered block; R-01 says links navigate only within the same directory while R-19 resolves any relative path. Second, a set of **semantic gaps** where two competent implementers would diverge: what *Copy Without Prompts* does with non-prompt lines, whether the file watcher must survive atomic-rename saves, which heading wins when two have the same slug, how "*n* of *m*" counts multiple matches in one block, what the persisted history JSON looks like. None of these is hard to fix; most are one sentence.

- **Maturity:** Level 2 (Implementable), close to Level 3 — the contracts are Level-3 quality; the gaps are in behaviour that the tables around them leave implicit.
- **Readiness:** READY WITH MINOR FIXES. One P0 (the lifecycle contradiction, F-001) and eleven P1s, all resolvable inside the existing structure.
- **Findings:** 0 CRITICAL · 4 HIGH · 15 MEDIUM · 12 LOW (31 total).
- **Strengths:** §4 contracts, §8 edge cases drawn from real failures, complete I/K/E → T coverage, an honest §12.
- **Weaknesses:** F-001 (lifecycle vs E-03), F-002 (*Copy Without Prompts*), F-003 (watcher semantics), F-004 (bookmark anchor block); the test corpus that T-13/T-17 depend on is not in the repository.

## 2. Overall Maturity

**Level 2 — Implementable.** A competent engineer can build the system from this document, and for the renderer pipeline (C-05..C-07) they would build something materially equivalent. The areas that would diverge are user-interaction details (§2.3, §2.4) whose rows describe *what* the feature is but leave a rule or a tie-break unstated, and the four contradictions listed in §16. Resolving the P0/P1 items in §20 would move the document to Level 3.

## 3. Findings Summary

| ID | Severity | Location | Title |
| -- | -------- | -------- | ----- |
| F-001 | HIGH | §3.1, E-03, C-14 | Lifecycle table contradicts E-03 on an unreadable file |
| F-002 | HIGH | R-08 | *Copy Without Prompts* semantics undefined |
| F-003 | HIGH | R-05 | Watcher must survive atomic-rename saves and deletion — unstated |
| F-004 | HIGH | R-27 | Bookmark anchor block and title rule contradict the implementation |
| F-005 | MEDIUM | R-01 vs R-19 | "Same-directory" link navigation vs "any existing local file" |
| F-006 | MEDIUM | R-06 vs §3.3 | Scroll position persisted on file switch — R-06 omits it |
| F-007 | MEDIUM | C-11, R-19 | Duplicate heading slugs: no tie-break |
| F-008 | MEDIUM | R-24 | Find counter: occurrences vs blocks; image-bearing blocks excluded from character highlight |
| F-009 | MEDIUM | R-20, C-04 | `mdv_history` JSON shape not pinned |
| F-010 | MEDIUM | R-25, R-26 | Index membership when a history row is deleted |
| F-011 | MEDIUM | R-11, K-07 | "The screen's backing scale" — which screen |
| F-012 | MEDIUM | R-18 | Back/forward: what a history entry restores |
| F-013 | MEDIUM | R-21, E-06 | `#fragment` to an h4–h6 or setext heading is unresolvable |
| F-014 | MEDIUM | C-06.1 rule 3 | CSS colour-name list given as "…" |
| F-015 | MEDIUM | R-22 | Single-click copy vs double-click select vs drag start on a heading |
| F-016 | MEDIUM | T-13, T-17, §9.0 | Test corpus and harness are not in the repository |
| F-017 | MEDIUM | T-17, I-009 | Ink-weight metric has no formula, population, or region |
| F-018 | MEDIUM | E-03, R-04 | Non-UTF-8 files: abort vs lossy decode is a product decision |
| F-019 | MEDIUM | C-02 rules 2–3 | Fence closing, unclosed fences, indented code blocks |
| F-020 | LOW | R-35 vs T-36 | T-36 pass condition contradicts R-35's allowance |
| F-021 | LOW | I-001 | Purity inputs omit column width and backing scale |
| F-022 | LOW | I-003 | "never reaches a URL" vs the internal `mdv-math://` scheme |
| F-023 | LOW | R-34, §5.3 | `VERSION=` override vs "MUST refuse without a tag" |
| F-024 | LOW | C-04 | Two preference defaults left as "—" |
| F-025 | LOW | R-37 vs §5.3 | "every push" vs CI's `push` to `main` only |
| F-026 | LOW | R-09 | "Highlighted source view" — no mermaid grammar exists |
| F-027 | LOW | R-30, K-06 | HUD rounding and "~0.9 s" in a precision section |
| F-028 | LOW | C-07.1 | base64url padding not stated |
| F-029 | LOW | §2.6, §12 | Row ordering R-38/R-37/R-36 and D-15/D-14 |
| F-030 | LOW | E-16, R-02 | Editorial: garbled E-16; "sibling" undefined; "column width" undefined |
| F-031 | LOW | §3.3, notation | Unicode `≤` in a table cell; `~` and `≈` in constraints |

## 4. Detailed Findings

### F-001 — Lifecycle table contradicts E-03 on an unreadable file

**Severity:** HIGH

**Location:** §3.1 (`LOADING` row and Figure 3.1), E-03, C-14

**Observation**

§3.1 says `LOADING` → `EMPTY` on an unreadable file ("unreadable file → `EMPTY` (E-03)"), and the diagram draws `LOADING --> EMPTY : unreadable (E-03)`. E-03 says "Load aborted; window keeps its previous document; no history entry added," and C-14 repeats "unreadable file → the window stays on its previous content." The implementation (`loadFile` guards) keeps the previous document.

**Why it matters**

Two conforming implementations differ on a visible behaviour: one blanks the window, the other keeps the page the reader was on. The diagram is also the only place the `LOADING → EMPTY` edge exists, which the skill treats as a defect in its own right.

**Potential consequence**

T-04 ("the window keeps its previous document") fails on an implementation that followed §3.1.

**Recommended resolution**

Make §3.1 agree with E-03: `LOADING` leaves via "success → `VIEWING`; unreadable → *previous state* (`VIEWING` of the prior document, or `EMPTY` if there was none) (E-03)". Replace the diagram edge with `LOADING --> VIEWING : unreadable, previous document kept (E-03)` and add `LOADING --> EMPTY : unreadable, no previous document (E-03)`.

### F-002 — *Copy Without Prompts* semantics undefined

**Severity:** HIGH

**Location:** R-08

**Observation**

R-08 requires a *Copy Without Prompts* action for shell blocks where at least half the lines are `$ `/`# `-prompted, but does not say what the copied text is. The as-built behaviour (`copyWithoutPrompts`) strips the two-character prefix from prompted lines and **keeps every other line unchanged** (output lines are copied verbatim).

**Why it matters**

The two obvious readings — "strip prompts, keep output" and "copy only the command lines" — produce different pasteboard contents; the second is what several terminal emulators do.

**Potential consequence**

T-06's "the copy has no prompts" passes for both readings; a user pasting into a shell gets output lines executed as commands under the as-built reading and not under the other.

**Recommended resolution**

Add to R-08 (or a new C row): "The copied text is the block with the leading `$ ` or `# ` removed from each prompted line; all other lines are copied unchanged; line count is preserved." Extend T-06 with a block that has an output line and assert the output line is present.

### F-003 — Watcher must survive atomic-rename saves and deletion — unstated

**Severity:** HIGH

**Location:** R-05, §3.1 `RELOADING`, E-20

**Observation**

R-05 says the application "MUST watch [the file] and reload its content when the file changes on disk." Most macOS editors save by writing a temporary file and renaming it over the original (VS Code, BBEdit, Sublime, Vim with backup), which replaces the inode. A watcher built on a file descriptor (`DispatchSource.makeFileSystemObjectSource`) fires once and then watches a dead inode. The implementation deliberately uses a path-based FSEvents watcher on the parent directory for exactly this reason (its comment says so), but the spec does not require it. Deletion and re-creation of the file, and the file being moved away, are also unspecified.

**Why it matters**

A faithful re-implementation that watches the vnode passes T-29 (five writes in 50 ms to the same inode) and fails for every user of an atomic-save editor — the common case.

**Potential consequence**

Live reload silently stops after the first save in VS Code.

**Recommended resolution**

R-05: "The watch MUST be by *path*: a save that replaces the file by rename, or deletes and re-creates it, MUST trigger a reload of the new content. If the file is deleted and not re-created within the coalescing window, the window keeps its content and shows no error; the watch remains armed for the path." Add E-21 (file deleted while viewing) and T-29b (save via `mv tmp file` triggers a reload).

### F-004 — Bookmark anchor block and title rule contradict the implementation

**Severity:** HIGH

**Location:** R-27

**Observation**

R-27: "⌘D MUST add a bookmark at the block currently at the top of the viewport, titled by the nearest preceding heading (or the filename)." The implementation anchors at the **hovered block if the mouse is over one**, else the topmost visible block; the title is the nearest preceding ATX heading within a 40-block look-back, else the block's own first 40 characters — the filename is not used. "Block at the top of the viewport" is itself undefined (first block intersecting the top edge? first fully visible?); the implementation uses `visibleBlocks.min()`.

**Why it matters**

The hover rule is the feature's main affordance (the hover highlight is documented in code as "the *you'll bookmark here* indicator"); a re-implementation from the spec would bookmark a different block than the one the reader is pointing at, and would title bookmarks differently.

**Potential consequence**

T-26 passes on both, because it doesn't exercise hover; users get different bookmarks.

**Recommended resolution**

R-27: "…at the block under the pointer if any, else the topmost block whose frame intersects the viewport; titled by the nearest preceding ATX heading within the previous 40 blocks, else the first 40 characters of the block's source, else `(empty)`." Add the hover case to T-26.

### F-005 — "Same-directory" link navigation vs "any existing local file"

**Severity:** MEDIUM

**Location:** R-01 ("a same-directory Markdown link"), R-19, §1 *External editor* row

**Observation**

R-01 lists "a same-directory Markdown link clicked inside a document" as an open route; R-19 says navigation happens for any target that "resolves to an existing local file with extension md/markdown/mdown," with relative paths resolved by path arithmetic — which includes `../other/doc.md` and absolute paths.

**Recommended resolution**

Drop "same-directory" from R-01 (R-19 is the normative rule); if same-directory is intended as a security restriction, say so in R-19 and E-05 instead.

### F-006 — Scroll position persisted on file switch — R-06 omits it

**Severity:** MEDIUM

**Location:** R-06, §3.3 (Scroll positions row), §3.1

**Observation**

R-06 requires persistence "on window close or quit." §3.3 lists "window close / quit / file switch." §3.1's `VIEWING → LOADING` transition does not mention persisting the outgoing document's position. Without a file-switch write, T-28's "scroll to the middle, quit, relaunch" passes but "scroll, open another file, come back" loses the position — a common path (bookmark, search hit, link, ⌘←).

**Recommended resolution**

R-06: "…persist the current position on window close, quit, and before loading a different file into the window." Add the write to the `VIEWING → LOADING` transition in §3.1 and a step to T-28.

### F-007 — Duplicate heading slugs: no tie-break

**Severity:** MEDIUM

**Location:** C-11, R-19, I-010

**Observation**

"Equality selects the target" — with two headings that slug identically (common: several `### Example` sections; GitHub disambiguates with `-1`, `-2`), the spec does not say which one wins. The implementation selects the first in document order and does not implement GitHub's numeric suffixes, so `#example-1` is a no-op (E-06).

**Recommended resolution**

C-11: "When several headings share a slug, the first in document order is the target. Numeric disambiguation suffixes (`-1`, `-2`) are not generated; a fragment carrying one resolves only if a heading's own slug equals it." Or adopt GitHub's suffix rule — either way, decide (add D-16).

### F-008 — Find counter: occurrences vs blocks; image-bearing blocks excluded from character highlight

**Severity:** MEDIUM

**Location:** R-24, E-17

**Observation**

"*n* of *m*" — *m* is per occurrence (a block with three hits contributes three), which the spec does not say; an implementer counting matching blocks would show a different number and step differently. Also, the character-highlight path is skipped for any prose block that contains an image (`![`) because that path cannot render images; R-24 lists only "code, table, and image blocks" as tinted-whole, which reads as *image-only* blocks.

**Recommended resolution**

R-24: "*m* counts occurrences; ⌘G steps per occurrence in document order. Character highlighting applies to paragraph, heading, list and blockquote blocks that contain no image; all other blocks are tinted as a whole." Adjust E-17.

### F-009 — `mdv_history` JSON shape not pinned

**Severity:** MEDIUM

**Location:** R-20, C-04 (`mdv_history` row), §3.3

**Observation**

History is persisted as JSON in `UserDefaults` and read back on launch, but the record shape (`path`, `filename`, timestamp? id?) is not specified, unlike the SQLite tables in C-03/C-08. Two implementations would write incompatible preferences, and a future version cannot promise to read old ones.

**Recommended resolution**

Add C-15 with the `HistoryEntry` encoding (field names, types, ordering = most recent first) and a compatibility rule (unknown fields ignored; a malformed value → empty history, not a crash).

### F-010 — Index membership when a history row is deleted

**Severity:** MEDIUM

**Location:** R-25 ("every file in history"), R-26, C-03

**Observation**

R-25 defines the search population as "every file in history," but nothing says what happens to the `articles` row when the reader swipe-deletes a history entry or clears history. The implementation removes it (`Database.removeFile`), so search results and the sidebar stay consistent; a re-implementation that only indexes would keep returning deleted files.

**Recommended resolution**

R-26: "Removing a file from history (swipe-delete, clear) MUST remove its row from the index; the search population is exactly the current history." Add to T-25.

### F-011 — "The screen's backing scale" — which screen

**Severity:** MEDIUM

**Location:** R-11, K-07, C-07.2 ("the screen scale"), I-008

**Observation**

Rasters are made "at the screen's backing scale." On a two-display Mac with mixed densities the window's screen and `NSScreen.main` (the screen of the key window, or the primary display when the app is inactive) can differ; the implementation reads `NSScreen.main`. A diagram rendered at $1\times$ and shown on a $2\times$ display is exactly the "washed-out" defect the spec's I-005 exists to prevent.

**Recommended resolution**

State the rule and the re-render trigger: "the backing scale of the screen the window is on; when the window moves to a screen of different scale, rasters are regenerated (the cache key includes the scale)."

### F-012 — Back/forward: what a history entry restores

**Severity:** MEDIUM

**Location:** R-18

**Observation**

R-18 defines the stacks as "visited files" and says a snapshot is pushed before a fragment jump "so ⌘← returns to the previous position." It does not say whether a file-to-file ⌘← restores the scroll position (via C-08) or lands at the top, whether the forward stack is cleared on a new navigation, or whether opening the current file again pushes an entry.

**Recommended resolution**

Specify the entry as `(path, block anchor)`; ⌘← restores the anchor; a new navigation clears the forward stack; re-opening the current path is not pushed.

### F-013 — `#fragment` to an h4–h6 or setext heading is unresolvable

**Severity:** MEDIUM

**Location:** R-21, C-02 rule 5, R-19, E-06

**Observation**

TOC entries, and therefore fragment targets (R-19 resolves against `tocHeadings`), are only `#`/`##`/`###` single-line ATX headings. A link to a `####` heading, or to a setext (`===`/`---`-underlined) heading, is a silent no-op. This is a real behavioural difference from GitHub that the spec presents only implicitly.

**Recommended resolution**

Either extend C-02 to collect h4–h6 for slug purposes (TOC display can still stop at h3) or add an explicit E-row and a §12 decision. Add the case to T-22.

### F-014 — CSS colour-name list given as "…"

**Severity:** MEDIUM

**Location:** C-06.1 rule 3, E-14

**Observation**

"map CSS colour names (white, black, red, … transparent) to hex" — the ellipsis hides the normative list (the implementation has ~50 names). An implementer mapping the 16 basic CSS names would render `fill:lavender` black; one mapping all 148 would not.

**Recommended resolution**

Either enumerate the list in an appendix or adopt a standard by reference ("the CSS Color Module Level 4 named colours plus `transparent` and `none`") and make the implementation match it.

### F-015 — Single-click copy vs double-click select vs drag start on a heading

**Severity:** MEDIUM

**Location:** R-22

**Observation**

A single click on a heading copies the section; a double-click selects it; a drag selects blocks. The spec does not say whether the first click of a double-click also copies (as built: yes — the copy fires on click 1, then click 2 selects), whether a drag that starts on a heading copies, or whether a click with a modifier (⇧ for extending selection) is excluded. The pasteboard is a side effect, so this matters.

**Recommended resolution**

State the precedence: "the single-click copy fires on mouse-up without movement; a double-click performs the copy on its first click and the selection on its second; a drag never copies."

### F-016 — Test corpus and harness are not in the repository

**Severity:** MEDIUM

**Location:** T-13, T-17, T-19, §9.0, §10

**Observation**

T-13 refers to "the 52-diagram set used during development," and T-17/T-19 to offscreen measurements made with "the harness described in `NOTES.md`" — a scratch package outside the tree. A verifier cannot reproduce these tests from the repository.

**Recommended resolution**

Check in a diagram corpus under `test-docs/mermaid/` (the 52 diagrams, or a curated subset with licences cleared) and the harness under `tools/render-harness/` (or fold it into the §9.0 render-snapshot target). Reword T-13 to name the checked-in path.

### F-017 — Ink-weight metric has no formula, population, or region

**Severity:** MEDIUM

**Location:** T-17, I-009

**Observation**

"The node math's mean ink over pixels darker than 200 is within 10 % of the same expression typeset for the document" — the region compared (the whole node? a crop the size of the math image?), the colour channel, the denominator, and what "within 10 %" is relative to are unstated. Two testers would compute different numbers.

**Recommended resolution**

Define it. With $P$ the set of pixels in the crop of size equal to the math image (plus 4 px margin) and $g(p)$ the 8-bit luminance of pixel $p$ after compositing on white:

$$
D = \{\, p \in P : g(p) < 200 \,\}, \qquad
\mathrm{ink} = \frac{1}{|D|} \sum_{p \in D} \bigl(255 - g(p)\bigr), \qquad
\mathrm{ink}_{\mathrm{node}} \geq 0.9\, \mathrm{ink}_{\mathrm{doc}}
$$

with $\mathrm{ink} = 0$ when $D = \varnothing$ (test fails: no ink found). Put the formula in I-009 or a K row and have T-17 cite it.

### F-018 — Non-UTF-8 files: abort vs lossy decode is a product decision

**Severity:** MEDIUM

**Location:** R-04, E-03

**Observation**

R-04 "MUST be read as UTF-8" and E-03 treats "not UTF-8" as unreadable (load aborted, no error shown). Latin-1 and Windows-1252 Markdown files exist; a viewer that silently refuses them, showing nothing, is a defensible choice but not an obvious one, and §12 does not list it.

**Recommended resolution**

Add D-16: keep strict UTF-8 (default) vs decode with replacement characters vs try UTF-8 then ISO-8859-1. Whatever is chosen, E-03 should specify that the reader gets *some* feedback (currently "no error" — the file appears not to open).

### F-019 — Fence closing, unclosed fences, indented code blocks

**Severity:** MEDIUM

**Location:** C-02 rules 2–3

**Observation**

(a) Rule 2 closes a fence "at the next line starting with the same marker" — CommonMark requires the closing run to be at least as long as the opener, so a ` ```` ` block containing a ` ``` ` line splits differently in the block splitter than in cmark, and the two halves render as broken fences. (b) An unclosed fence or `$$` runs to end of file — unstated. (c) Indented code blocks (4 spaces) are not recognised, so a blank line inside one splits it into two blocks, which cmark then renders as two code blocks — visible as a gap. These are the splitter's own semantics, not cmark's, so they belong in the contract.

**Recommended resolution**

State (a) as built or fix it to CommonMark's rule; state (b) "runs to end of input"; state (c) as a known deviation with an E row (indented code containing a blank line renders as two blocks) or fix the splitter.

### F-020 — T-36 pass condition contradicts R-35's allowance

**Severity:** LOW

**Location:** R-35, T-36

**Observation**

R-35 permits SwiftMath's font-registration lines; those lines contain a file path (`mathFonts bundle resource: latinmodern-math…`). T-36 requires "no line contains … a path other than in the `[mdv]` failure message," so a conforming build fails its own test.

**Recommended resolution**

T-36: exempt lines beginning `"mathFonts bundle resource:`.

### F-021 — Purity inputs omit column width and backing scale

**Severity:** LOW

**Location:** I-001

**Observation**

"The same file bytes, theme, zoom, and preferences produce the same … rendered output" — Mermaid rasters also depend on column width (R-11) and backing scale (F-011). As written the invariant is false.

**Recommended resolution**

Add "window content width and backing scale" to the inputs.

### F-022 — "Never reaches a URL" vs the internal `mdv-math://` scheme

**Severity:** LOW

**Location:** I-003, C-07.1

**Observation**

Document content (LaTeX) is base64-encoded into `mdv-math://` URLs that never leave the process. I-003 should say "an external URL / network request."

### F-023 — `VERSION=` override vs "MUST refuse without a tag"

**Severity:** LOW

**Location:** R-34, §5.3, K-11

**Observation**

The Makefile documents `VERSION=...` as an override "to test individual release targets without tagging first"; the spec says `make dist` MUST refuse without an exact tag. State whether the override applies to `dist` (as built, `check-version` compares `VERSION` — an override may bypass it).

### F-024 — Two preference defaults left as "—"

**Severity:** LOW

**Location:** C-04 (`mdv_bookmarks_expanded`, `mdv_bookmarks_height`)

**Recommended resolution**

Fill in the defaults from the `@AppStorage` declarations.

### F-025 — "Every push" vs CI's push to `main` only

**Severity:** LOW

**Location:** R-37, §5.3

**Recommended resolution**

R-37: "on every push to `main` and on every pull request."

### F-026 — "Highlighted source view" — no mermaid grammar exists

**Severity:** LOW

**Location:** R-09

**Observation**

The source view passes the hint `mermaid` to `CodeRenderer`, which has no such grammar (K-05), so the view is plain monospace. Say "monospace source view" or add a grammar.

### F-027 — HUD rounding and "~0.9 s" in a precision section

**Severity:** LOW

**Location:** R-30, K-06

**Recommended resolution**

"HUD shows $\lfloor 100 \cdot \mathrm{scale} + 0.5 \rfloor$ %"; replace "~0.9 s" with the actual constant.

### F-028 — base64url padding not stated

**Severity:** LOW

**Location:** C-07.1

**Recommended resolution**

"base64url without `=` padding; decoders MUST re-pad to a multiple of 4."

### F-029 — Row ordering

**Severity:** LOW

**Location:** §2.6 (R-38, R-37 before R-36), §12 (D-15 before D-14)

**Recommended resolution**

Reorder; ids stay.

### F-030 — Editorial: garbled E-16; undefined "sibling" and "column width"

**Severity:** LOW

**Location:** E-16, R-02, R-11

**Recommended resolution**

E-16: "Math that is the *entire* content of a table cell or list item …". R-02: replace "as a sibling" with "as history rows (not opened)". Define *column width* once (article width after `articleHorizontalPadding`, capped by `articleMaxWidth`).

### F-031 — Notation

**Severity:** LOW

**Location:** §3.3 (`≤ 100` in a table cell), K-06 (`~0.9`), C-06.2 (`(n-1) × 13 + 4` inline is fine; `r = 8 pt` bare)

**Recommended resolution**

`$\leq 100$`; `$r = 8$ pt`. Batch fix.

## 5. Requirements Review

The 38 requirements are observable and use normative verbs throughout; each cites a source. They are grouped sensibly and the two forward-looking rows (R-37, R-38) are clearly marked *not yet built*, which is the right way to carry roadmap items in an as-built spec. Precision is high for rendering (§2.2) and packaging (§2.6); it drops in §2.3–§2.4 where several rows name a feature and its shortcut but leave a rule implicit — the bookmark anchor (F-004), find counting (F-008), back/forward payload (F-012), click precedence (F-015), history persistence shape (F-009). Two rows contradict others (F-001, F-005). No requirement introduces out-of-scope functionality; R-35 and R-36 give the cross-cutting concerns (diagnostics, robustness) ids of their own, as the template asks.

## 6. Interface and Data-Contract Review

§4 is the strongest part of the document. C-02, C-03, C-05, C-06, C-07, C-08, C-10, C-11, C-12 pin behaviour precisely enough to test, and the Mermaid tables record *why* each rule exists — valuable for maintenance. Gaps: the history JSON (F-009); two preference defaults (F-024); the colour-name list (F-014); fence-closing semantics (F-019); base64url padding (F-028). C-09 pins only the theme fields behaviour depends on, which is correct restraint. §5 tabulates every surface with shortcuts, effects, and disabled states; the CLI table includes exit codes and stderr text.

## 7. State and Failure Review

The lifecycle in §3.1 is small and mostly right, but it contradicts E-03 (F-001), omits the file-switch persistence step (F-006), and has no row for the file disappearing or being replaced while viewed (F-003). Failure semantics elsewhere are good: every renderer failure has a defined fallback, persistence failure degrades feature-by-feature (E-12), and C-14 states the "in place, never modally" rule. Retry is not applicable. Cancellation of in-flight rendering (a document switched while a large diagram lays out) is unspecified but the as-built `.task(id:)` cancellation makes it benign — worth one sentence.

## 8. Determinism and Algorithm Review

Algorithms that matter are specified: the block splitter (with the gaps in F-019), FTS query construction, delimiter rules, the fingerprint and anchor resolution (with tie order stated), the slug (missing its tie-break, F-007), section ranges, sequence-diagram row expansion with its formula. The Mermaid repair layer is deterministic and ordered. Nothing in the system is probabilistic; the only nondeterminism is the screen scale (F-011) and column width (F-021), which the purity invariant should name as inputs.

## 9. Edge-Case Review

§8 is drawn from real failures rather than invented, which shows; E-01, E-07, E-13, E-14 are exactly the cases that broke. Missing: file deleted or replaced while viewing (F-003); duplicate slugs (F-007); h4+/setext fragment targets (F-013); non-UTF-8 input (F-018); an unclosed fence and indented code (F-019); an empty search query; the same file bookmarked twice at the same block (as built: `toggleBookmark` — allowed? removed?); a diagram or math image wider than the column at minimum window width.

## 10. Non-Functional Requirement Review

K-01..K-12 are measurable except K-06's "~0.9 s". Performance is covered by construction (R-04 once-per-load, R-11 re-raster on change, cache sizes) and one measured target (T-32, idle CPU). There is no bound on document size or on time-to-first-render for a large document; given the LazyVStack design this is probably fine, but a single K row ("a 1 MB document renders its first screen within 1 s on the reference machine") would make regressions visible.

## 11. Security and Trust-Boundary Review

The boundary is stated (untrusted document content; the only network activity is opt-in). The launcher installs a symlink with sudo and the app is unsandboxed — both stated as non-goals. Two things worth a sentence: (1) R-19 hands *any* non-Markdown URL to the system opener on click, including `file://` paths to executables and custom schemes that launch other apps; that is what browsers do too, but the spec should say it is deliberate. (2) When remote images are enabled, a document can make the reader's machine fetch arbitrary URLs (tracking pixels) — the default-off decision D-14 covers it; the spec could add that the fetch sends no cookies or referrer.

## 12. Observability and Provenance Review

By design the application logs almost nothing (R-35), and the spec is explicit about the two exceptions. What an engineer cannot reconstruct after the fact: which build a user is running (D-13 — the bundle version is constant), and whether a scroll/bookmark anchor was resolved by fingerprint or by clamped index. Neither is a defect for a viewer; D-13 is the one to fix. `mdv.db` has a `meta` table (seen in the schema) that the spec does not mention — if it holds a schema version, say so; migrations need one.

## 13. Testing and Verification Review

Every I/K/E id has at least one T id and the pass conditions are mostly unambiguous. Two structural weaknesses: the corpus and harness that the strongest tests depend on are outside the repository (F-016), and the one numeric metric lacks a definition (F-017). §9.0's migration plan to an automated suite is concrete and correctly identifies the `mdvCore` split as the prerequisite. T-36 contradicts R-35 (F-020). T-06 does not exercise the ambiguity in F-002; T-26 does not exercise the hover rule in F-004.

## 14. Metrics and Evaluation Review

There is one metric (ink weight, T-17/I-009) and it is under-defined (F-017). Everything else is a count, a limit, or a pass/fail. The sequence-row formula $(n-1)\times 13 + 4$ appears in both C-06.2 and K-08 with the same value, and T-19's "30 pt taller" agrees with it for $n = 3$.

## 15. Traceability Review

Intent → R → C/I/K/E → T is complete in §11; every row names a realising component. Two rows cite "manual" instead of a T id (R-23, R-31) and R-03's "T-04 (drop variant)" points at a step T-04 does not contain. The diagrams carry captions naming their ids; the §3.1 diagram has one edge not backed by a row (F-001).

## 16. Internal-Consistency Review

Contradictions found: §3.1 vs E-03/C-14 (F-001); R-27 vs the cited implementation (F-004); R-01 vs R-19 (F-005); R-06 vs §3.3 (F-006); R-35 vs T-36 (F-020); R-34 vs the Makefile's `VERSION=` (F-023); R-37 vs §5.3 (F-025); I-001's claim vs R-11 (F-021). Terminology is stable ("block", "inspector", "sidebar", "column width" — the last undefined). Numbers agree across sections (100, 80, 14, 5, 0.6 s, 50 ms, 40 pt rows, 13 pt pitch, 180/400/520).

## 17. Architecture Review

The architecture described — MarkdownUI as the host, image-provider hooks as the extension seam for math, a sanitise/repair layer in front of each third-party parser, layout cached separately from rasters — supports the requirements, and the invariants (I-002, I-005, I-008) are the ones that protect its known weak points. The dependency direction is clean (app → repair layer → library). The one architectural item the spec should carry as a requirement rather than a §9.0 aside is the `mdvCore` library split, since R-37 depends on it.

## 18. Implementation-Agent Readiness

**YES — WITH MINOR CLARIFICATIONS.**

Minimum blocking questions for a from-scratch implementer:

1. Unreadable file: keep the previous document or blank the window? (F-001)
2. *Copy Without Prompts*: keep output lines? (F-002)
3. Must the watcher follow atomic-rename saves? (F-003)
4. Bookmark anchor: hovered block or top block; title rule? (F-004)
5. Duplicate slugs and h4+ targets: which heading, or none? (F-007, F-013)
6. What does `mdv_history` look like on disk? (F-009)

## 19. Quality Scorecard

| Dimension | Score |
| --------- | ----: |
| Scope clarity | 4 |
| Terminology | 3 |
| Requirement precision | 3 |
| Interface completeness | 4 |
| Data-contract completeness | 3 |
| State/lifecycle definition | 3 |
| Algorithm precision | 4 |
| Failure semantics | 3 |
| Edge-case coverage | 4 |
| Non-functional requirements | 3 |
| Security specification | 3 |
| Observability/provenance | 3 |
| Testability | 3 |
| Evaluation/metrics | 2 |
| Traceability | 4 |
| Internal consistency | 3 |
| Architecture consistency | 4 |
| Implementation readiness | 3 |

## 20. Remediation Plan

### P0 — Blocking

- **F-001** — reconcile §3.1 with E-03/C-14; fix the diagram edge.

### P1 — Important

- **F-002** — define *Copy Without Prompts* output; extend T-06.
- **F-003** — require path-based watching; add E-21 and a rename-save test.
- **F-004** — restate the bookmark anchor and title rule as built; extend T-26.
- **F-005**, **F-006**, **F-007**, **F-008**, **F-012**, **F-015** — one-sentence rule additions in §2.3/§2.4 and C-11.
- **F-009** — add C-15 (history JSON).
- **F-010** — index removal on history delete.
- **F-011** — name the screen; add scale to the cache key statement.
- **F-016** — check in the corpus and harness (or fold into the R-37 targets).
- **F-017** — define the ink metric (formula above).

### P2 — Improvement

- **F-013**, **F-014**, **F-018**, **F-019** — decide and record (new D rows or E rows).
- **F-020** … **F-031** — editorial and notation; batch in one commit.

None of these requires redesign; all fit inside the existing sections and id families.

## 21. Final Verdict

```text
Specification maturity:
Level 2

Implementation readiness:
READY WITH MINOR FIXES

Primary blocker:
§3.1 and E-03/C-14 disagree on what an unreadable file does to the window (F-001).

Most important improvement:
Turn the implicit interaction rules in §2.3–§2.4 (copy-without-prompts, watcher semantics, bookmark anchor, find counting, slug tie-break) into explicit sentences, then check the diagram corpus and harness into the repository so the strongest tests are reproducible.
```
