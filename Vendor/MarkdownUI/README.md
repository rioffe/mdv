# MarkdownUI (vendored)

Upstream: https://github.com/gonzalezreal/swift-markdown-ui — v2.4.1
(revision `5f613358148239d0292c0cef674a3c2314737f9e`), MIT (see LICENSE).

Vendored rather than pulled in as a SwiftPM dependency because of one
patch, described below. Only `Sources/` is vendored; tests, examples and the
upstream `Package.swift` are not — the target is declared in the root
`Package.swift`, and MarkdownUI's own dependencies (swift-cmark, NetworkImage)
still come from the network. `Sources/MarkdownUI/Documentation.docc` (4 MB of
doc images) is not vendored either.

## Local changes vs upstream

- `Views/Environment/Environment+ResolvedInlineImages.swift` (new) and
  `Views/Inlines/InlineText.swift`: a new
  `markdownResolvedInlineImages(_:)` modifier publishes a `[String: Image]`
  of images the caller has *already* resolved, keyed by image source, via
  `EnvironmentValues.resolvedInlineImages`. `InlineText` merges them into the
  images it renders.

  Why: upstream resolves inline images only in `.task`, which
  `ImageRenderer` never runs — an inline image that has not been loaded is
  silently skipped by `TextInlineRenderer.renderImage`. mdv's print pipeline
  renders blocks with `ImageRenderer`, so without this hook every inline
  LaTeX formula (`$…$`, and a `$$…$$` that sits mid-sentence) would print as
  nothing. With it, the print path typesets the formulas up front, hands them
  over synchronously, and keeps text as vector glyphs in the PDF.

  The environment value is empty by default, so on-screen rendering is
  untouched: the `.task` still loads images, and a loaded image wins over a
  supplied one for the same key.

Keep this list in sync when re-vendoring from a newer upstream release.
