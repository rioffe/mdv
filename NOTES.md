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
