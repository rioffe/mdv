@preconcurrency import AppKit
import MarkdownUI
import SwiftMath
import SwiftUI

// LaTeX math: `$…$` inline and `$$…$$` display.
//
// MarkdownUI (cmark-gfm underneath) has no math extension, so we don't try to
// teach it one. Instead, before a block reaches `Markdown(...)`, every math
// span is rewritten into an image reference —
//
//     ![](mdv-math://inline/<base64url latex>?s=<pt>&c=<rrggbbaa>)
//
// — and our image providers (`MathInlineImageProvider` for spans inside
// text, `MathDisplayView` via `LocalImageProvider` for a paragraph that is
// nothing but a `$$` block) recognise that scheme and typeset the LaTeX with
// SwiftMath. Size and colour ride along in the URL so the provider is
// stateless and MarkdownUI's `task(id: inlines)` re-renders on theme change.
//
// Known limitation: SwiftUI places an inline `Text(Image)` with its bottom
// on the baseline, and MarkdownUI gives us no hook to apply a baseline
// offset, so inline math with descenders (subscripts, fractions) sits a few
// points high. Display math is unaffected.

/// One math span, as encoded in an `mdv-math://` URL.
struct MathSpec: Hashable {
    static let scheme = "mdv-math"

    let latex: String
    let display: Bool
    let fontSize: CGFloat
    /// sRGB, packed 0xRRGGBBAA.
    let colorRGBA: UInt32

    var color: NSColor {
        NSColor(
            srgbRed: CGFloat((colorRGBA >> 24) & 0xFF) / 255,
            green: CGFloat((colorRGBA >> 16) & 0xFF) / 255,
            blue: CGFloat((colorRGBA >> 8) & 0xFF) / 255,
            alpha: CGFloat(colorRGBA & 0xFF) / 255
        )
    }

    var url: String {
        let payload = Data(latex.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let size = String(format: "%.1f", fontSize)
        let color = String(format: "%08X", colorRGBA)
        return "\(Self.scheme)://\(display ? "display" : "inline")/\(payload)?s=\(size)&c=\(color)"
    }

    init(latex: String, display: Bool, fontSize: CGFloat, colorRGBA: UInt32) {
        self.latex = latex
        self.display = display
        self.fontSize = fontSize
        self.colorRGBA = colorRGBA
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let host = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var payload = String(url.path.dropFirst())   // strip leading "/"
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let latex = String(data: data, encoding: .utf8) else { return nil }
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        guard let size = query["s"].flatMap(Double.init),
              let color = query["c"].flatMap({ UInt32($0, radix: 16) }) else { return nil }
        self.latex = latex
        self.display = host == "display"
        self.fontSize = CGFloat(size)
        self.colorRGBA = color
    }
}

// MARK: - Source rewriting

enum MathMarkdown {
    /// Replaces `$…$` / `$$…$$` spans in one markdown block with
    /// `mdv-math://` image references. Fenced code blocks and inline code
    /// spans are left alone; `\$` stays a literal dollar.
    ///
    /// Delimiter rules follow Pandoc's `tex_math_dollars`: an opening `$`
    /// must be followed by non-whitespace, a closing `$` must be preceded by
    /// non-whitespace and not followed by a digit, and a span can't contain
    /// a bare `$`. That keeps "$5 and $10" prose intact.
    static func rewrite(_ block: String, fontSize: CGFloat, color: NSColor) -> String {
        guard block.contains("$") else { return block }
        let trimmed = block.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return block }

        let rgba = Self.rgba(color)
        let chars = Array(block)
        let n = chars.count
        var out = ""
        out.reserveCapacity(block.count)
        var i = 0
        var codeRun = 0   // length of the open inline-code backtick run, 0 outside

        func spec(_ latex: String, display: Bool) -> String {
            let s = MathSpec(latex: latex, display: display, fontSize: fontSize, colorRGBA: rgba)
            return "![](\(s.url))"
        }

        while i < n {
            let c = chars[i]

            if c == "`" {
                var run = 0
                while i < n, chars[i] == "`" { out.append("`"); run += 1; i += 1 }
                if codeRun == 0 { codeRun = run } else if run == codeRun { codeRun = 0 }
                continue
            }
            if codeRun > 0 {
                out.append(c); i += 1; continue
            }
            if c == "\\", i + 1 < n {
                out.append(c); out.append(chars[i + 1]); i += 2; continue
            }
            if c != "$" {
                out.append(c); i += 1; continue
            }

            // `$$…$$`
            if i + 1 < n, chars[i + 1] == "$" {
                if let close = findDisplayClose(chars, from: i + 2) {
                    let latex = String(chars[(i + 2)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if latex.isEmpty {
                        out.append("$$"); i += 2; continue
                    }
                    let after = close + 2
                    if isLineStart(out), isLineEnd(chars, at: after) {
                        // Own paragraph, so MarkdownUI's block-image path picks
                        // it up and it renders centred, not inline in a sentence.
                        // Keep the line's indentation (list continuation).
                        let lineStart = out.lastIndex(of: "\n").map { out.index(after: $0) } ?? out.startIndex
                        let indent = String(out[lineStart...])
                        var head = String(out[..<lineStart])
                        if !head.isEmpty {
                            while !head.hasSuffix("\n\n") { head.append("\n") }
                        }
                        out = head + indent + spec(latex, display: true)
                        i = after
                        while i < n, chars[i] == " " || chars[i] == "\t" { i += 1 }
                        if i < n, chars[i] == "\n" { i += 1 }
                        if i < n { out.append("\n\n") }
                    } else {
                        out.append(spec(latex, display: true))
                        i = after
                    }
                    continue
                }
                out.append("$$"); i += 2; continue
            }

            // `$…$`
            if let close = findInlineClose(chars, from: i + 1) {
                let latex = String(chars[(i + 1)..<close])
                out.append(spec(latex, display: false))
                i = close + 1
                continue
            }
            out.append("$"); i += 1
        }
        return out
    }

    private static func findDisplayClose(_ chars: [Character], from start: Int) -> Int? {
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "`" { return nil }
            if chars[j] == "$", chars[j + 1] == "$" { return j }
            j += 1
        }
        return nil
    }

    private static func findInlineClose(_ chars: [Character], from start: Int) -> Int? {
        guard start < chars.count, !chars[start].isWhitespace, chars[start] != "$" else { return nil }
        var j = start
        while j < chars.count {
            let c = chars[j]
            if c == "\\" { j += 2; continue }
            if c == "`" { return nil }   // ran into a code span — not math
            if c == "$" {
                let prevOK = !chars[j - 1].isWhitespace
                let nextOK = j + 1 >= chars.count || !chars[j + 1].isNumber
                return (prevOK && nextOK && j > start) ? j : nil
            }
            j += 1
        }
        return nil
    }

    /// True when everything emitted since the last newline is whitespace.
    private static func isLineStart(_ out: String) -> Bool {
        for c in out.reversed() {
            if c == "\n" { return true }
            if c != " " && c != "\t" { return false }
        }
        return true
    }

    private static func isLineEnd(_ chars: [Character], at index: Int) -> Bool {
        var j = index
        while j < chars.count {
            if chars[j] == "\n" { return true }
            if chars[j] != " " && chars[j] != "\t" { return false }
            j += 1
        }
        return true
    }

    private static func rgba(_ color: NSColor) -> UInt32 {
        let c = color.usingColorSpace(.sRGB) ?? .black
        func byte(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return byte(c.redComponent) << 24 | byte(c.greenComponent) << 16 | byte(c.blueComponent) << 8 | byte(c.alphaComponent)
    }
}

// MARK: - Typesetting + cache

final class MathRendered {
    let image: NSImage
    let ascent: CGFloat
    let descent: CGFloat
    /// Parse error message, if SwiftMath rejected the LaTeX. `image` then
    /// holds a plain-text rendering of the source so the span isn't lost.
    let error: String?

    init(image: NSImage, ascent: CGFloat, descent: CGFloat, error: String?) {
        self.image = image
        self.ascent = ascent
        self.descent = descent
        self.error = error
    }
}

final class MathImageCache {
    static let shared = MathImageCache()

    private let entries: NSCache<NSString, MathRendered> = {
        let cache = NSCache<NSString, MathRendered>()
        cache.countLimit = 2048
        return cache
    }()

    func cached(for spec: MathSpec) -> MathRendered? {
        entries.object(forKey: spec.url as NSString)
    }

    func rendered(for spec: MathSpec) async -> MathRendered {
        if let hit = cached(for: spec) { return hit }
        let result = await Task.detached(priority: .userInitiated) {
            SendableRendered(value: Self.typeset(spec))
        }.value.value
        entries.setObject(result, forKey: spec.url as NSString)
        return result
    }

    private static func typeset(_ spec: MathSpec) -> MathRendered {
        var math = MathImage(
            latex: spec.latex,
            fontSize: spec.fontSize,
            textColor: spec.color,
            labelMode: spec.display ? .display : .text,
            textAlignment: .left
        )
        let (error, image, layout) = math.asImage()
        if error == nil, let image, let layout {
            return MathRendered(image: image, ascent: layout.ascent, descent: layout.descent, error: nil)
        }
        let message = error?.localizedDescription ?? "LaTeX could not be rendered"
        return MathRendered(image: fallbackImage(for: spec), ascent: spec.fontSize, descent: 0, error: message)
    }

    /// The raw source in monospace, so a span SwiftMath can't parse still
    /// reads as what the author wrote instead of vanishing.
    private static func fallbackImage(for spec: MathSpec) -> NSImage {
        let delimiter = spec.display ? "$$" : "$"
        let text = NSAttributedString(
            string: delimiter + spec.latex + delimiter,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: spec.fontSize * 0.9, weight: .regular),
                .foregroundColor: spec.color.withAlphaComponent(0.8),
            ]
        )
        let size = text.size()
        return NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { rect in
            text.draw(at: .zero)
            return true
        }
    }
}

private struct SendableRendered: @unchecked Sendable {
    let value: MathRendered
}

// MARK: - MarkdownUI providers

/// Inline images: math URLs are typeset here, everything else goes to
/// MarkdownUI's default loader as before.
struct MathInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        guard let spec = MathSpec(url: url) else {
            return try await DefaultInlineImageProvider().image(with: url, label: label)
        }
        let rendered = await MathImageCache.shared.rendered(for: spec)
        return Image(nsImage: rendered.image)
    }
}

/// A `$$` block on its own paragraph: centred, capped at its natural width,
/// scaled down to fit narrow columns. Right-click copies the LaTeX.
///
/// Also reached when an inline `$…$` is the *entire* content of a list item
/// or table cell — MarkdownUI routes image-only paragraphs here — in which
/// case it stays text-sized and leading-aligned like the prose around it.
struct MathDisplayView: View {
    let spec: MathSpec
    @State private var rendered: MathRendered?

    init(spec: MathSpec) {
        self.spec = spec
        _rendered = State(initialValue: MathImageCache.shared.cached(for: spec))
    }

    var body: some View {
        Group {
            if let rendered {
                if rendered.error == nil {
                    let size = rendered.image.size
                    Image(nsImage: rendered.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: size.width > 0 ? size.width : nil)
                        .accessibilityLabel(spec.latex)
                } else {
                    fallback(rendered)
                }
            } else {
                Color.clear.frame(height: spec.fontSize * 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: spec.display ? .center : .leading)
        .padding(.vertical, spec.display ? 4 : 0)
        .contextMenu {
            Button("Copy LaTeX") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(spec.latex, forType: .string)
            }
        }
        .task(id: spec) {
            if rendered == nil {
                rendered = await MathImageCache.shared.rendered(for: spec)
            }
        }
    }

    private func fallback(_ rendered: MathRendered) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rendered.error ?? "LaTeX could not be rendered")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: spec.color).opacity(0.7))
            Text(spec.latex)
                .font(.system(size: max(spec.fontSize * 0.85, 11), design: .monospaced))
                .foregroundStyle(Color(nsColor: spec.color))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
