# Notes

## Mermaid: ELK layout asserts crash the app (2026-09-14)

**Symptom:** `open build/mdv.app` crashes on launch with `EXC_BREAKPOINT` /
`Assertion failed` in `ElkGraphImporter.findCoordinateSystemOrigin`. It
recurs on every launch because mdv reopens the last document from history.

**Cause:** the `beautiful-mermaid-swift` parser lets a node be claimed by
several sibling subgraphs — e.g. `CL --> PD` inside `subgraph Surface` plus a
`PD` declaration inside `subgraph Orchestration`. Its layout builder then
emits the node under both compound nodes with duplicate IDs, and the ELK
port (`elk-swift`) trips an `assert` on the edge/container mismatch. Swift
asserts are uncatchable, so the `try?` around rendering cannot save it.
Mermaid.js resolves this as "last subgraph wins"; the Swift port does not.

**Fix:** `MDVMermaidPipeline` in `mdv/MermaidRenderer.swift` runs the
library's public steps separately (parse → layout → render) and, in
between, normalizes subgraph ownership so each node belongs only to the
last subgraph that mentioned it. Applies to flowcharts and state diagrams.

**Also handled in `MDVMermaidPipeline.sanitize`:** YAML front matter
(`---\nconfig: …\n---`) is dropped — the parser fails with
`invalidHeader("---")` and the library has no wrapping-width option to
honour anyway — and inline HTML formatting tags in labels (`<b>`, `<i>`,
`<code>`, …) are stripped, since they otherwise render literally. Diagram
types the library lacks (`timeline`, `gantt`, `pie`, `mindmap`, …) show the
"could not be rendered" fallback with the source.

**LaTeX in labels.** Mermaid.js renders `$$…$$` in labels with KaTeX. A
node whose label is exactly one `$$` span is typeset with SwiftMath: the
label is replaced by a blank placeholder that `measureMultilineText`
sizes like the math image, ELK lays the node out at that size, and
`composite` draws the image centred on the node rect afterwards (node
coordinates map 1:1 onto the image in points). Math mixed with text, and
math in edge labels, uses the Unicode approximation (`MathMarkdown.plainText`).

**Resolution.** Diagrams used to be rasterised once at natural size and
then stretched to the column by SwiftUI — upscaled and resampled at
fractional offsets, which reads as "washed out". `MDVMermaidPrepared` now
keeps the ELK layout, and `MDVMermaidPipeline.rasterize` redraws it with
CoreText at the exact display width (never wider than natural, whole
points) whenever the column or committed zoom changes. Rasters are
cached per width. Same for math: SwiftMath's handler-backed NSImages are
baked to bitmaps in `MathImageCache` — SwiftUI treats handler images
inside `Text` as dynamic and re-resolves the paragraph continuously
(10–20 % idle CPU on any page with inline math until this).

**xychart.** The parser only knows `line [...]`; Mermaid's named form
`line "interest" [...]` is rewritten to it in `sanitize`. Series names
are lost — the library's legend is hardcoded "Line 1/2", and there is no
model field to carry them. `themeCSS` in front matter (dashes, widths)
is dropped with the front matter.

**Still true:**
- Other ELK `assert`s may exist for other malformed diagrams. `make` builds
  debug (asserts on); a release build strips them.
- Subgraph labels containing spaces/parentheses, e.g.
  `subgraph Roles["… may use httpx (I-002)"]`, get mis-tokenized into stray
  nodes (`may`, `gate`, `---`). Cosmetic, upstream parser bug, not fixed.
- To find the offending document after a crash: parse the latest
  `~/Library/Logs/DiagnosticReports/mdv-*.ips` and query
  `~/Library/Application Support/mdv/mdv.db`
  (`select path from articles order by indexed_at desc`).

## LaTeX math (2026-09-14)

`$…$` / `$$…$$` are rendered by rewriting each span into an image
reference (`![](mdv-math://inline|display/<base64url>?s=<pt>&c=<rrggbbaa>)`)
before the block reaches MarkdownUI, then typesetting those URLs with
SwiftMath in `MathInlineImageProvider` (spans inside text) and
`MathDisplayView` (image-only paragraphs, via `LocalImageProvider`). See
the header comment in `mdv/MathRenderer.swift`.

**SwiftMath is vendored** (`Vendor/SwiftMath`, MIT) rather than a package
dependency: upstream ships fonts as a SwiftPM resource bundle whose
generated `Bundle.module` only looks at the *root* of the app bundle, and
codesign refuses to sign anything there ("unsealed contents present in the
bundle root"). The vendored copy loads `mathFonts.bundle` from
`Contents/Resources` instead (`build.sh` copies it). Only Latin Modern
Math is shipped. Details in `Vendor/SwiftMath/README.md`.

**Known limitation — inline baseline.** SwiftUI puts a `Text(Image)` with
its bottom on the text baseline and MarkdownUI's `TextInlineRenderer`
builds inline images as bare `Text(image)`, so inline math with descenders
(`$x_i$`, `$\frac{1}{2}$`) sits `descent` points too high. Verified that
`NSImage.alignmentRect` is ignored and that `Text(image).baselineOffset(-descent)`
would fix it — but that needs a one-line patch inside MarkdownUI
(`Sources/MarkdownUI/Renderer/TextInlineRenderer.swift`, `renderImage`),
i.e. a fork or a vendored copy. Display math is unaffected.

**Coverage.** SwiftMath lacks a fair amount of amssymb/amsmath. `MathSymbols`
in `mdv/MathRenderer.swift` registers extra symbols with
`MTMathAtomFactory.add` (`\gtrsim`, `\therefore`, `\implies`, `\iint`,
`\dots`, …) and regex-rewrites commands whose *syntax* the parser lacks
(`\operatorname{}` → `\mathrm{}`, `\bmod`/`\pmod`, `\dfrac`, `align*` →
`aligned`, `equation` stripped, `\big`/`\Bigl`/`\biggr`… size hints dropped). Still unsupported: `\boxed`,
`\underbrace`/`\overbrace`, `\stackrel`, `\substack`, `\&` (the parser
treats `&` as a column separator everywhere). To find what a document
needs, the scratch harness's `--check` mode runs each line through
SwiftMath and prints `FAIL <cmd>`; adding a symbol is one dictionary line.

Math inside ATX headings is sized by the heading's em (`MDVTheme.headingSizeEms`),
so `# Monte Carlo $\pi$` gets an h1-sized π.

The TOC sidebar and bookmark titles are plain strings, so
`MathMarkdown.plainText` turns spans into Unicode there (`$\pi$` → π,
`$x^2 \le y_1$` → x² ≤ y₁). `TOCHeading.slugText` keeps the un-converted
text so `#monte-carlo-pi-estimator` fragment links still resolve the way
GitHub slugs them.

**Delimiter rules** follow Pandoc's `tex_math_dollars`: opening `$` needs a
non-space after it, closing `$` needs a non-space before it and no digit
after it, no bare `$` inside, and a span never crosses a backtick. So
"$5 and $10", "$5-$10", `\$`, and `$HOME` in code all stay literal.
`ParsedDocument.parseBlocks` treats an unclosed `$$` line like a code fence
so blank lines inside a display block don't split it.
