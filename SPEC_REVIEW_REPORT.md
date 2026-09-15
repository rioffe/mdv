# Specification Review Report

> - **Subject:** `SPEC.md` v0.2 — mdv (Markdown viewer, native macOS GUI + CLI launcher)
> - **Reviewed at:** commit `faf1085`, 2026-09-14 — second pass, after all v0.1 findings (F-001..F-031) were applied
> - **Method:** four passes per the `spec-review` skill. Because v0.2 added a number of precise behavioural claims, this pass checked each new claim against the cited implementation. Finding ids continue from F-032; F-001..F-031 are listed as resolved in §3 and not re-argued.

## 1. Executive Summary

v0.2 resolved every v0.1 finding, and most of the resolutions hold up: the lifecycle contradiction is gone, the interaction rules in §2.3–§2.4 are now explicit, the history JSON and the ink metric are pinned, and the id/coverage/traceability checks all pass. The document is now close to implementation-grade for the renderer, persistence, and packaging surfaces.

This pass found three things the first one missed, all of the same kind — **the spec asserts behaviour the cited implementation does not have** — and they are the most important findings so far:

1. **R-22 specifies a feature that was removed.** Block-level drag selection, double-click section select, ⌘A/⌘C-as-Markdown and Esc-to-clear were deleted in commit `c50817a` ("restore normal text selection"), which R-22 itself cites. What remains is the single-click section copy and ordinary text selection. R-05, §3.1, §5.1, E-19, I-004, T-30 and §11 all carry the stale machinery.
2. **CRLF documents are never split into blocks.** C-02 rule 6 (added in v0.2) says a trailing `\r` counts as whitespace for the blank-line test; in the implementation it does not (`CharacterSet.whitespaces` excludes `\r`), so a Windows-authored file becomes a single block — find, TOC, bookmarks and heading-copy all degrade. Verified with a two-line Swift check.
3. **Deleting the displayed file blanks the window.** R-05/E-21 (v0.2) say content is kept; the watcher callback reads the missing file as `""` and assigns it.

The first is a specification defect (P0 — an implementer would build a removed feature). The other two are implementation defects that the spec now correctly prohibits; they need "not yet realised" markers in §11 and issues filed, not spec changes.

- **Maturity:** Level 2, one fix away from Level 3.
- **Readiness:** READY WITH MINOR FIXES.
- **Findings this pass:** 0 CRITICAL · 3 HIGH · 3 MEDIUM · 4 LOW (10). Cumulative: 41, of which 31 resolved.
- **Strengths:** §4 contracts, §7.1 metric, complete traceability, an honest §12 with 15 decisions awaiting the owner.
- **Weaknesses:** the three implementation-vs-spec divergences above; T-30 tests a feature that no longer exists.

## 2. Overall Maturity

**Level 2 — Implementable**, held there only by F-032. With R-22 and its dependents rewritten to the as-built behaviour, and F-033/F-034 marked as open implementation defects in §11, the document meets the Level 3 bar: a coding agent could build it with minimal semantic inference and every requirement has an objective test.

## 3. Findings Summary

### Resolved from v0.1

F-001..F-031 — all applied in v0.2 (see `SPEC.md` revision history). Spot-checked in this pass: F-001 (§3.1 now matches E-03), F-002 (*Copy Without Prompts* output matches `copyWithoutPrompts`), F-004 (bookmark anchor matches `addBookmarkAtCurrentSpot`), F-007/F-012/F-017 (verified against `scrollToFragment`, `NavSnapshot`, the new §7.1). F-008's "wrapping at the ends" was verified (`nextMatch` uses modulo).

### New in v0.2

| ID | Severity | Location | Title |
| -- | -------- | -------- | ----- |
| F-032 | HIGH | R-22, R-05, §3.1, §5.1, E-19, I-004, T-30, §9.0, §11 | Block-selection feature specified but removed in `c50817a` |
| F-033 | HIGH | C-02 rule 6 (implementation) | CRLF documents are never split into blocks |
| F-034 | HIGH | R-05, E-21 (implementation) | Deleting the displayed file blanks the window |
| F-035 | MEDIUM | R-22 | "No modifier" and double-click semantics not as built |
| F-036 | MEDIUM | §11 | No convention for requirements the implementation violates |
| F-037 | MEDIUM | E-21, R-05 | Atomic save's transient states: empty file, non-UTF-8 write |
| F-038 | LOW | K-13 | Column width omits the 8 pt drag handles |
| F-039 | LOW | §2.6 → §3 | Missing blank line between the R-39 table row and the §3 heading |
| F-040 | LOW | §9.0, T-30 | §9.0 migration table still maps T-30 to "sections" |
| F-041 | LOW | C-02 rule 5, T-39 | Rule renumbering left "rules 2–4" citations that now include the indented-code rule |

## 4. Detailed Findings

### F-032 — Block-selection feature specified but removed in `c50817a`

**Severity:** HIGH

**Location:** R-22; R-05 ("MUST clear any block selection"); §3.1 `RELOADING` ("selection cleared"); §5.1 rows *Edit · Copy / Select All* and *Document · Esc*; E-19; I-004 ("block indices used by … selection"); T-30; §9.0 (T-30 → "sections"); §11 R-22 row (`BlockFramePreferenceKey`, "Esc monitor")

**Observation**

R-22 requires: double-click selects a section; a drag across blocks selects whole blocks with section expansion; ⌘A selects every block; ⌘C copies selected blocks' source joined by blank lines; Esc clears. Commit `c50817a` — which R-22 cites as its source, alongside `bae06a7` that introduced the feature — removed all of it: "Block-level drag-select turned out to be annoying in practice … Revert the LazyVStack to `.textSelection(.enabled)` … Removes the block-select drag gesture, `BlockFramesKey` PreferenceKey, `SelectionEscapeMonitor`, the custom Edit > Cut/Copy/Paste/Select-All command group, the Esc-to-clear plumbing." `grep` for `selectSection`, `selectedBlocks`, `count: 2` in `ContentView.swift` finds nothing. What exists: standard text selection on prose blocks (drag, ⌘C copies rendered text via the system pasteboard group), headings with text selection disabled, and the single-click section copy with the 0.6 s flash.

**Why it matters**

An implementer would build a substantial interaction subsystem the maintainers deliberately deleted; a verifier running T-30 would fail a conforming build. This is the one finding that blocks handing the spec to `spec-build`.

**Potential consequence**

Re-introduction of a feature judged "annoying in practice"; T-30 unfailable/unpassable depending on reading.

**Recommended resolution**

Rewrite R-22 to the as-built behaviour: "Prose blocks MUST support standard macOS text selection (drag, ⌘C copies the rendered text). Heading blocks MUST NOT be text-selectable; a click on a heading MUST copy that heading's section (C-12) as Markdown source to the pasteboard and flash the section for 0.6 s (a re-click restarts the flash); the pointer over a heading MUST be the pointing hand." Then: drop "MUST clear any block selection" from R-05 and "selection cleared" from §3.1/E-19 (replace with "text selection is not preserved across a reload"); remove the two §5.1 rows; drop "selection" from I-004; rewrite T-30 to test heading copy + TOC/find/bookmark index agreement; fix the §11 R-22 row (`copySection`, `BlockTextSelection`, `isHeadingBlock`).

### F-033 — CRLF documents are never split into blocks

**Severity:** HIGH

**Location:** C-02 rule 6 (spec); `ParsedDocument.parseBlocks` (implementation)

**Observation**

Rule 6 says a trailing `\r` "is whitespace for the blank-line test." The implementation tests `line.trimmingCharacters(in: .whitespaces).isEmpty`; `CharacterSet.whitespaces` contains only space and tab, so a CRLF blank line (`"\r"`) is *not* blank. Checked directly: `"\r".trimmingCharacters(in: .whitespaces).isEmpty` is `false`. Consequently a CRLF file produces **one block** for the whole document: MarkdownUI still renders it (cmark handles CRLF), but the TOC lists at most the first heading, find tints the whole document, bookmarks and scroll anchors all resolve to block 0, and heading-click copies everything.

**Why it matters**

The spec's rule is right and the implementation is wrong; an as-built spec that presents the rule as built misleads the verifier, and Windows-authored Markdown is common.

**Potential consequence**

Every block-indexed feature degrades silently on CRLF input; T-08/T-23/T-26 pass only on LF files.

**Recommended resolution**

Keep rule 6 as the requirement; mark it *not yet realised* in §11 (see F-036) and file the defect: normalise `\r\n` → `\n` (and lone `\r`) before splitting, or test blank lines with `.whitespacesAndNewlines`. Add to T-39: "the same file with CRLF line endings produces the same block count and TOC as the LF version."

### F-034 — Deleting the displayed file blanks the window

**Severity:** HIGH

**Location:** R-05, E-21 (spec); the `fileWatcher.watch` callback in `ContentView` (implementation)

**Observation**

R-05/E-21 (v0.2): "If the file is deleted and not re-created, the window MUST keep its content, show no error, and keep the watch armed." The callback does `let fresh = (try? String(contentsOfFile:…)) ?? ""` and assigns it when it differs — so a deletion, a rename *away*, or a transient non-UTF-8 write replaces the document with an empty string. The watch does stay armed (FSEvents, path-based), so re-creation reloads — that half of E-21 holds.

**Why it matters**

A reader whose editor deletes-then-writes (some do, outside the 50 ms window) or who moves a file sees the page vanish; the spec promises otherwise.

**Recommended resolution**

Spec stays; mark E-21 *not yet realised* in §11; fix: on read failure keep `rawMarkdown` unchanged (`guard let fresh = try? … else { return }`). Extend T-29's `rm file` step to assert the content is still displayed (it already says so — the test would currently fail, which is the point).

### F-035 — "No modifier" and double-click semantics not as built

**Severity:** MEDIUM

**Location:** R-22

**Observation**

v0.2 added "(mouse-up without movement, no modifier)" and "a double-click MUST select the section (its first click performs the copy, its second the selection)." The implementation uses a plain `.onTapGesture`, which fires regardless of modifier keys, and there is no double-click handler (F-032): a double-click is two single taps — two copies, the second restarting the flash. Neither claim is backed by code.

**Recommended resolution**

Fold into the F-032 rewrite: "a click (tap without drag; modifier keys are not distinguished) copies …; repeated clicks copy again and restart the flash."

### F-036 — No convention for requirements the implementation violates

**Severity:** MEDIUM

**Location:** §11, front matter ("as-built")

**Observation**

An as-built spec needs a way to say "this row is the requirement; the code does not meet it yet" without weakening the row. §11 has *not yet realised* for R-37..R-39 (features never built) but nothing for a row the code contradicts (F-033, F-034). Without a marker, a verifier cannot tell an accepted deviation from a bug, and the next as-built revision will be tempted to bend the row to the code.

**Recommended resolution**

Add a third §11 status — *open defect (issue #n)* — and use it for C-02 rule 6 and E-21. State in the front matter that "as-built" means "every row is true of the tree at the stated commit **except** rows marked *not yet realised* or *open defect* in §11."

### F-037 — Atomic save's transient states: empty file, non-UTF-8 write

**Severity:** MEDIUM

**Location:** E-21, R-05, E-03

**Observation**

Editors that truncate-then-write (rather than rename) produce a transient zero-length file; some write in chunks. With 50 ms coalescing this is usually invisible, but R-05 does not say what a reload of an *empty* or *non-UTF-8* intermediate state does. As built (F-034) both blank the page; after the F-034 fix a non-UTF-8 read would be ignored, but a genuinely empty file would still be shown as empty — which is correct for a real empty file and wrong for a transient one, and the two are indistinguishable.

**Recommended resolution**

Specify the as-intended rule: "a reload that reads an empty or undecodable file within 500 ms of a previous change event MUST be treated as transient and ignored; an empty file that stays empty past that window MUST be shown as empty." Or accept the simpler "empty is shown" and say so. Either way, add a T-29 step with a truncate-then-write save.

### F-038 — Column width omits the 8 pt drag handles

**Severity:** LOW

**Location:** K-13

**Observation**

"minus the sidebar and inspector when shown" — each pane also has an 8 pt drag handle (§ *dragHandle* / *inspectorDragHandle*) that the column does not include. T-18's equality check will be off by 8–16 pt.

**Recommended resolution**

"…minus the sidebar and inspector *and their 8 pt drag handles* when shown…".

### F-039 — Missing blank line before the §3 heading

**Severity:** LOW

**Location:** end of §2.6

**Observation**

The R-39 row is immediately followed by `## 3. Behavior and state model` with no blank line; cmark-gfm terminates the table correctly, but several renderers (and the `spec2pdf.sh` pipeline's pandoc) can absorb the heading into the table.

### F-040 — §9.0 migration table still maps T-30 to "sections"

**Severity:** LOW

**Location:** §9.0, unit-group row

**Recommended resolution**

After the F-032 rewrite T-30 covers `sectionRange`/`copySection` only; keep it in the unit group but drop the drag/⌘A wording from T-30 itself.

### F-041 — Rule renumbering left stale "rules 2–4" citations

**Severity:** LOW

**Location:** C-02 (rule 5 now is the trim rule; rule 7 is TOC), E-23 ("C-02 rules 2–4"), T-39

**Observation**

v0.2 inserted rules 4 (indented code) and 6 (CRLF) and renumbered; E-23 and T-39 cite "rules 2–4", which is still the right range (fence, math fence, indented code), but rule 5 in the E-23 text ("Splitter semantics of C-02 rules 2–4") was written before the insert — verify each citation. Also the `tocHeadings` rule is now 7 while C-02's `TOCHeading` comment still says "level 1…3, single-line ATX only" — consistent.

**Recommended resolution**

Cite rules by name ("the fence, math-fence, and indented-code rules") rather than number, or freeze the numbering.

## 5. Requirements Review

Requirements are observable and precise; v0.2's additions (R-05 watcher semantics, R-18 stack payload, R-24 counting, R-27 anchor rule) are the kind of sentence that separates Level 2 from Level 3. The defect class this pass surfaced is *stale accuracy*: R-22 and two v0.2 additions assert behaviour that is not in the tree. For an as-built spec, "cites a commit" must mean "checked against the tree at that commit" — R-22 cited the commit that removed the feature. Recommend a rule for future revisions: every R row that cites a commit or symbol is re-verified against `HEAD` when the version bumps.

## 6. Interface and Data-Contract Review

Unchanged from v0.1 except for improvements: C-15 pins history persistence; C-02 now states fence/CRLF/indented-code semantics (one of which the code fails, F-033); the colour list is enumerated; base64url padding is stated. No new interface gaps.

## 7. State and Failure Review

§3.1 is now consistent with E-03 and carries E-21 and E-25. Two failure semantics are specified but not implemented (F-033 is a parsing defect, F-034 a reload defect) and one transient case is unspecified (F-037). `RELOADING` still says "selection cleared" (F-032).

## 8. Determinism and Algorithm Review

Slug tie-break, find ordering, and the anchor rule are now deterministic. The block splitter's CRLF behaviour is deterministic but wrong (F-033). No other change.

## 9. Edge-Case Review

E-21..E-25 fill the v0.1 gaps. Remaining: the transient empty/undecodable file during an atomic save (F-037); a heading clicked twice quickly (F-035 — copies twice, harmless); a `.txt` dropped file that is not Markdown (renders as Markdown — acceptable, D-11 covers the extension policy).

## 10. Non-Functional Requirement Review

Unchanged; K-06 now has exact values and K-13 defines column width (F-038 minor). No size or time-to-first-render bound — still a reasonable omission for this product, noted in v0.1.

## 11. Security and Trust-Boundary Review

R-19 now states the click-opens-anything policy explicitly. Nothing new.

## 12. Observability and Provenance Review

`meta.schema_version` is now specified (§3.3). D-13 (bundle version) remains the provenance gap.

## 13. Testing and Verification Review

T-30 tests a removed feature (F-032). T-29 and T-39 would currently *fail* on F-034 and F-033 respectively — which is correct behaviour for tests of requirements the code violates, provided §11 says so (F-036). R-39 makes the corpus and harness a requirement, closing the reproducibility gap.

## 14. Metrics and Evaluation Review

§7.1 defines the only metric with population, formula, and degenerate case; I-009 and T-17 cite it. Adequate.

## 15. Traceability Review

Scripted check at `faf1085`: no id gaps in any family, no dangling references, every I/K/E cited by a test, a §11 row for every R/C/I/K/E. The R-22 row names symbols that no longer exist (F-032). §11 lacks the *open defect* status (F-036).

## 16. Internal-Consistency Review

Contradictions: R-22 vs `c50817a` (F-032); C-02 rule 6 vs the implementation (F-033); R-05/E-21 vs the implementation (F-034); R-22 modifier/double-click wording vs `.onTapGesture` (F-035). Numeric agreement across sections holds (checked 50 ms, 0.6 s, 0.9 s, 40 blocks, 13 pt, 36 pt, 80/100/5).

## 17. Architecture Review

Unchanged and sound. The `mdvCore` split remains the enabling change for R-37; the harness (R-39) should be a client of that library rather than a copy of the pipeline files.

## 18. Implementation-Agent Readiness

**YES — WITH MINOR CLARIFICATIONS.**

Minimum blocking question:

1. Is R-22 the removed block-selection model or the as-built heading-click model? (F-032 — answer: as built; rewrite.)

Non-blocking but must be recorded before claiming conformance: F-033 and F-034 as open defects in §11 (F-036).

## 19. Quality Scorecard

| Dimension | Score |
| --------- | ----: |
| Scope clarity | 4 |
| Terminology | 4 |
| Requirement precision | 4 |
| Interface completeness | 4 |
| Data-contract completeness | 4 |
| State/lifecycle definition | 4 |
| Algorithm precision | 4 |
| Failure semantics | 3 |
| Edge-case coverage | 4 |
| Non-functional requirements | 3 |
| Security specification | 3 |
| Observability/provenance | 3 |
| Testability | 4 |
| Evaluation/metrics | 4 |
| Traceability | 4 |
| Internal consistency | 2 |
| Architecture consistency | 4 |
| Implementation readiness | 3 |

Internal consistency drops from 3 to 2 this pass because the three divergences from the implementation are more consequential than v0.1's section-to-section contradictions; it returns to 4 once F-032 is rewritten and F-033/F-034 are marked.

## 20. Remediation Plan

### P0 — Blocking

- **F-032** — rewrite R-22 to the as-built behaviour and purge the block-selection references from R-05, §3.1, §5.1, E-19, I-004, T-30, §9.0, §11.

### P1 — Important

- **F-033** — keep rule 6; mark *open defect* in §11; file the CRLF issue; extend T-39.
- **F-034** — keep R-05/E-21; mark *open defect* in §11; file the issue; T-29 already covers it.
- **F-035** — fold into the R-22 rewrite.
- **F-036** — add the *open defect* status and the front-matter definition of "as-built".
- **F-037** — decide the transient-state rule (add D-18) and a T-29 step.

### P2 — Improvement

- **F-038**, **F-039**, **F-040**, **F-041** — editorial.

## 21. Final Verdict

```text
Specification maturity:
Level 2

Implementation readiness:
READY WITH MINOR FIXES

Primary blocker:
R-22 specifies the block-selection model that commit c50817a removed; rewrite it to the as-built heading-click model and purge its dependents (F-032).

Most important improvement:
Give §11 an "open defect" status and use it for the two requirements the code currently violates (CRLF block splitting, F-033; file deletion blanking the window, F-034), so the spec stays the source of truth while the bugs are fixed.
```
