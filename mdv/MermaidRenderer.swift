@preconcurrency import AppKit
import BeautifulMermaid
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers

enum MermaidRenderStyle: String, CaseIterable, Hashable, Identifiable {
    case document
    case light
    case dark
    case tokyoNight
    case catppuccin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .document: return "Document"
        case .light: return "Light"
        case .dark: return "Dark"
        case .tokyoNight: return "Tokyo Night"
        case .catppuccin: return "Catppuccin"
        }
    }

    func diagramTheme(for theme: MDVTheme) -> DiagramTheme {
        switch self {
        case .document:
            return theme.mermaidDiagramTheme
        case .light:
            return .zincLight
        case .dark:
            return .zincDark
        case .tokyoNight:
            return .tokyoNight
        case .catppuccin:
            return theme.isDark ? .catppuccinMocha : .catppuccinLatte
        }
    }
}

struct MermaidCodeBlockChrome: View {
    let content: String
    let displayLanguage: String
    let theme: MDVTheme
    let palette: CodePalette

    @State private var hovering = false
    @State private var showSource = false
    @State private var wrap = false
    // Style is a document-wide appearance choice, not a per-block preference:
    // pick a palette once and every diagram updates and persists across launches.
    @AppStorage("mdv.mermaid.style") private var style: MermaidRenderStyle = .document
    @State private var copied = false
    @State private var copyGeneration = 0

    var body: some View {
        if showSource {
            sourceChrome
        } else {
            diagramChrome
        }
    }

    // Diagram view: the diagram fills the box; the toolbar floats top-right
    // as a translucent capsule, like Preview/Quick Look. Hover-revealed.
    private var diagramChrome: some View {
        MDVMermaidDiagramView(source: content, theme: theme, style: style)
            .frame(maxWidth: .infinity)
            .background(palette.background ?? theme.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) { floatingToolbar }
            .onHover { hovering = $0 }
            .contextMenu { contextMenuItems }
    }

    // Source view: matches the normal CodeBlockChrome look — language label
    // top-left, hover-revealed toolbar top-right, syntax-highlighted content.
    private var sourceChrome: some View {
        VStack(alignment: .leading, spacing: 0) {
            sourceChromeRow
            sourceContent
        }
        .background(palette.background ?? theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .contextMenu { contextMenuItems }
    }

    private var floatingToolbar: some View {
        HStack(spacing: 2) {
            styleMenu

            iconButton(
                systemName: "curlybraces",
                tinted: false,
                help: "Show Mermaid source"
            ) { showSource = true }

            iconButton(
                systemName: "square.and.arrow.down",
                tinted: false,
                help: "Export diagram as PNG"
            ) { MDVMermaidImage.exportPNG(source: content, theme: theme, style: style) }

            iconButton(
                systemName: copied ? "checkmark" : "doc.on.doc",
                tinted: copied,
                help: copied ? "Copied" : "Copy code"
            ) { copy() }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.thinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.secondaryText.opacity(0.18), lineWidth: 0.5)
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
        .opacity(hovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .animation(.easeInOut(duration: 0.18), value: copied)
    }

    private var sourceChromeRow: some View {
        HStack(spacing: 0) {
            Text(displayLanguage)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.tertiaryText)
                .opacity(displayLanguage.isEmpty ? 0 : 0.85)
                .padding(.leading, 14)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                iconButton(
                    systemName: wrap ? "text.alignleft" : "text.append",
                    tinted: wrap,
                    help: wrap ? "Disable wrap" : "Wrap long lines"
                ) { wrap.toggle() }

                iconButton(
                    systemName: "point.3.connected.trianglepath.dotted",
                    tinted: true,
                    help: "Show diagram"
                ) { showSource = false }

                iconButton(
                    systemName: copied ? "checkmark" : "doc.on.doc",
                    tinted: copied,
                    help: copied ? "Copied" : "Copy code"
                ) { copy() }
            }
            .padding(.trailing, 6)
            .opacity(hovering ? 1 : 0)
        }
        .frame(height: 26)
        .padding(.top, 4)
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.18), value: copied)
        .animation(.easeInOut(duration: 0.18), value: wrap)
    }

    @ViewBuilder
    private var sourceContent: some View {
        let body = Text(CodeRenderer.shared.render(code: content, languageHint: "mermaid", theme: theme))
            .fixedSize(horizontal: false, vertical: true)
            .relativeLineSpacing(.em(0.225))
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 14)

        if wrap {
            body.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                body
            }
        }
    }

    private var styleMenu: some View {
        Menu {
            stylePicker
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style == .document ? theme.secondaryText : theme.accent)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .help("Change Mermaid diagram style")
    }

    private var stylePicker: some View {
        Picker("Diagram style", selection: $style) {
            ForEach(MermaidRenderStyle.allCases) { candidate in
                Text(candidate.displayName).tag(candidate)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Copy Code") { copy() }
        Button(showSource ? "Show Diagram" : "Show Mermaid Source") {
            showSource.toggle()
        }
        if showSource {
            Button(wrap ? "Disable Wrap" : "Wrap Long Lines") { wrap.toggle() }
        } else {
            Menu("Diagram Style") {
                stylePicker
            }
            Button("Export Diagram as PNG") {
                MDVMermaidImage.exportPNG(source: content, theme: theme, style: style)
            }
        }
    }

    private func iconButton(
        systemName: String,
        tinted: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tinted ? theme.accent : theme.secondaryText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(content, forType: .string)
        flashCopied()
    }

    private func flashCopied() {
        copyGeneration &+= 1
        let myGeneration = copyGeneration
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if myGeneration == copyGeneration { copied = false }
        }
    }
}

struct MDVMermaidDiagramView: View {
    let source: String
    let theme: MDVTheme
    let style: MermaidRenderStyle

    @State private var prepared: MDVMermaidPrepared?
    @State private var image: NSImage?
    @State private var failed = false
    @State private var availableWidth: CGFloat = 0
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1

    private var renderKey: MDVMermaidRenderKey {
        MDVMermaidRenderKey(source: source, theme: theme, style: style)
    }

    /// Width the diagram is drawn at: its natural width, or the column if
    /// that's narrower. Never upscaled — a bitmap stretched past 1:1 is
    /// what "washed out" looks like. Whole points so the raster lands on
    /// the pixel grid.
    private var displayWidth: CGFloat {
        guard let prepared, availableWidth > 0 else { return 0 }
        return floor(min(prepared.size.width, max(availableWidth - 36, 1)))
    }

    private var displayHeight: CGFloat {
        guard let prepared, displayWidth > 0 else { return 0 }
        return ceil(displayWidth * prepared.size.height / prepared.size.width)
    }

    var body: some View {
        Group {
            if failed {
                MermaidFallbackView(source: source, theme: theme)
            } else if let image, prepared != nil {
                diagramBody(for: image)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { availableWidth = $0 }
            }
        )
        .task(id: renderKey) {
            failed = false
            prepared = nil
            image = nil
            zoom = 1
            committedZoom = 1
            if let result = await MDVMermaidImageCache.shared.prepared(source: source, theme: theme, style: style, key: renderKey) {
                if !Task.isCancelled { prepared = result }
            } else if !Task.isCancelled {
                failed = true
            }
        }
        // Re-rasterize when the column width or the committed zoom changes.
        // Layout is cached; this is just CoreText drawing at the new size.
        .task(id: RasterRequest(key: renderKey, width: displayWidth * committedZoom, ready: prepared != nil)) {
            guard let prepared, displayWidth > 0 else { return }
            let width = floor(displayWidth * committedZoom)
            let raster = await MDVMermaidImageCache.shared.raster(prepared, key: renderKey, width: width)
            if !Task.isCancelled { image = raster }
        }
    }

    private struct RasterRequest: Hashable {
        let key: MDVMermaidRenderKey
        let width: CGFloat
        let ready: Bool
    }

    @ViewBuilder
    private func diagramBody(for image: NSImage) -> some View {
        let baseImage = Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)

        if zoom > 1.01 {
            // Zoomed: inner ScrollView for panning. Pin the container height
            // to the unzoomed fit height so the document doesn't reflow during
            // pinch. The raster is redone at the committed zoom, so only the
            // in-flight gesture shows a scaled bitmap.
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                baseImage
                    .frame(width: displayWidth * zoom, height: displayHeight * zoom)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }
            .frame(height: min(displayHeight + 24, 540))
            .gesture(mermaidZoomGesture)
            .accessibilityLabel("Mermaid diagram")
        } else {
            // Unzoomed: drawn 1:1 at displayWidth, centred in the column. No
            // inner ScrollView, so wheel events bubble up to the document scroll.
            baseImage
                .frame(width: displayWidth * zoom, height: displayHeight * zoom)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .gesture(mermaidZoomGesture)
                .accessibilityLabel("Mermaid diagram")
        }
    }

    private var mermaidZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = clampedZoom(committedZoom * value)
            }
            .onEnded { value in
                committedZoom = clampedZoom(committedZoom * value)
                zoom = committedZoom
            }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.5), 4)
    }
}

struct MDVMermaidRenderKey: Hashable {
    let sourceHash: Int
    let sourceLength: Int
    let themeID: String
    let style: MermaidRenderStyle
    let scale: CGFloat

    init(source: String, theme: MDVTheme, style: MermaidRenderStyle) {
        self.sourceHash = source.hashValue
        self.sourceLength = source.count
        self.themeID = theme.id
        self.style = style
        self.scale = NSScreen.main?.backingScaleFactor ?? 2
    }

    var cacheID: NSString {
        "\(themeID)|\(style.rawValue)|\(scale)|\(sourceLength)|\(sourceHash)" as NSString
    }
}

/// Layout output, kept so the diagram can be re-drawn at any width without
/// running ELK again. `math` holds typeset `$$` node labels (block-based
/// NSImages, so they re-rasterize crisply at whatever scale they're drawn).
final class MDVMermaidPrepared: @unchecked Sendable {
    let positioned: PositionedGraph
    let theme: DiagramTheme
    let math: [String: NSImage]
    /// Natural size in points.
    let size: CGSize

    init(positioned: PositionedGraph, theme: DiagramTheme, math: [String: NSImage]) {
        self.positioned = positioned
        self.theme = theme
        self.math = math
        self.size = CGSize(width: max(1, positioned.width), height: max(1, positioned.height))
    }
}

final class MDVMermaidImageCache {
    static let shared = MDVMermaidImageCache()

    private let layouts: NSCache<NSString, MDVMermaidPrepared> = {
        let cache = NSCache<NSString, MDVMermaidPrepared>()
        cache.countLimit = 96
        return cache
    }()

    private let rasters: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 192
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    func prepared(source: String, theme: MDVTheme, style: MermaidRenderStyle, key: MDVMermaidRenderKey) async -> MDVMermaidPrepared? {
        if let cached = layouts.object(forKey: key.cacheID) { return cached }
        let diagramTheme = style.diagramTheme(for: theme)
        let result = await Task.detached(priority: .userInitiated) {
            try? MDVMermaidPipeline.prepare(source: source, theme: diagramTheme)
        }.value
        if let result { layouts.setObject(result, forKey: key.cacheID) }
        return result
    }

    /// The diagram drawn `width` points wide at the key's backing scale.
    func raster(_ prepared: MDVMermaidPrepared, key: MDVMermaidRenderKey, width: CGFloat) async -> NSImage? {
        let id = "\(key.cacheID)|w=\(width)" as NSString
        if let cached = rasters.object(forKey: id) { return cached }
        let scale = key.scale
        let image = await Task.detached(priority: .userInitiated) {
            SendableMermaidImage(image: MDVMermaidPipeline.rasterize(prepared, width: width, scale: scale))
        }.value.image
        if let image { rasters.setObject(image, forKey: id, cost: max(image.bitmapCost, 1)) }
        return image
    }

    /// Natural-size image at 2× — for PNG export.
    func image(source: String, theme: MDVTheme, style: MermaidRenderStyle, key: MDVMermaidRenderKey) async -> NSImage? {
        guard let prepared = await prepared(source: source, theme: theme, style: style, key: key) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            SendableMermaidImage(image: MDVMermaidPipeline.rasterize(prepared, width: ceil(prepared.size.width), scale: 2))
        }.value.image
    }
}

// Parse → normalize → layout → render, instead of the library's one-shot
// `MermaidRenderer.renderImage`, so we can repair the parsed model before it
// reaches the ELK layout engine. ELK enforces its invariants with `assert`,
// which is uncatchable and takes the whole app down.
enum MDVMermaidPipeline {
    /// Parse, repair, typeset math labels, and run ELK. The expensive half;
    /// `rasterize` does the rest and can be repeated at any width.
    static func prepare(source: String, theme: DiagramTheme) throws -> MDVMermaidPrepared {
        var graph = try MermaidParser.parse(sanitize(source))
        var mathNodes: [String: NSImage] = [:]
        switch graph.typedPayload {
        case .flowchart(var model), .stateDiagram(var model):
            normalizeSubgraphOwnership(model)
            mathNodes = substituteMath(in: &model, theme: theme)
            graph.payload = model
        default:
            break
        }
        let positioned = try GraphLayout().layout(graph)
        return MDVMermaidPrepared(positioned: positioned, theme: theme, math: mathNodes)
    }

    /// Draws the laid-out diagram `width` points wide (aspect preserved) into
    /// a bitmap at `scale` px/pt, upright. Text is drawn by CoreText at the
    /// final size instead of being drawn once and resampled, which is what
    /// keeps labels as sharp as the document text around them.
    static func rasterize(_ prepared: MDVMermaidPrepared, width: CGFloat, scale: CGFloat) -> NSImage? {
        let natural = prepared.size
        let fit = max(width, 1) / natural.width
        let size = CGSize(width: max(1, floor(natural.width * fit)), height: max(1, ceil(natural.height * fit)))
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)

        // The library draws y-down. Flip once here instead of flipping the
        // finished bitmap.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: fit, y: -fit)
        DiagramRenderer(theme: prepared.theme).render(
            prepared.positioned,
            in: ctx,
            bounds: CGRect(origin: .zero, size: natural)
        )
        ctx.restoreGState()

        // Typeset math over its nodes (y-up, in display points).
        if !prepared.math.isEmpty, let nodes = prepared.positioned.flowchartNodes {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for node in nodes {
                guard let image = prepared.math[node.id] else { continue }
                let w = image.size.width * fit, h = image.size.height * fit
                let x = (node.x + (node.width - image.size.width) / 2) * fit
                let yTop = (node.y + (node.height - image.size.height) / 2) * fit
                image.draw(in: CGRect(x: x, y: size.height - yTop - h, width: w, height: h))
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    // MARK: LaTeX in labels

    /// Mermaid.js renders `$$…$$` inside node/edge labels with KaTeX;
    /// BeautifulMermaid draws the dollars verbatim. A node whose label is
    /// nothing but one math span gets typeset properly: the label is swapped
    /// for a blank placeholder the layout measures to the same size, and the
    /// math image is drawn over the node afterwards (`composite`). Math mixed
    /// with text, and math in edge labels, falls back to the Unicode
    /// approximation the TOC uses (`x²`, `≤`, `a/b`).
    private static let mathLabelFontSize: CGFloat = 14

    private static func substituteMath(in model: inout ParsedGraphModel, theme: DiagramTheme) -> [String: NSImage] {
        var images: [String: NSImage] = [:]
        for idx in model.nodesInOrder.indices {
            let label = model.nodesInOrder[idx].node.label
            guard label.contains("$$") else { continue }
            if let latex = wholeMathSpan(label), let image = typeset(latex, color: theme.foreground) {
                images[model.nodesInOrder[idx].id] = image
                model.nodesInOrder[idx].node.label = placeholder(for: image.size)
            } else {
                model.nodesInOrder[idx].node.label = MathMarkdown.plainText(label)
            }
        }
        for idx in model.edges.indices {
            if let label = model.edges[idx].label, label.contains("$$") {
                model.edges[idx].label = MathMarkdown.plainText(label)
            }
        }
        return images
    }

    /// The LaTeX if `label` is exactly one `$$…$$` span (whitespace and
    /// line breaks around it allowed), else nil.
    private static func wholeMathSpan(_ label: String) -> String? {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("$$"), t.hasSuffix("$$"), t.count > 4 else { return nil }
        let inner = t.dropFirst(2).dropLast(2)
        guard !inner.contains("$$") else { return nil }
        let latex = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return latex.isEmpty ? nil : latex
    }

    private static func typeset(_ latex: String, color: NSColor) -> NSImage? {
        MathSymbols.registerOnce()
        var math = MathImage(
            latex: MathSymbols.preprocess(latex),
            fontSize: mathLabelFontSize,
            textColor: color,
            labelMode: .display,
            textAlignment: .center
        )
        let (error, image, _) = math.asImage()
        return error == nil ? image : nil
    }

    /// Blank text the library measures to at least `size`: spaces for width,
    /// extra lines for height. Node padding is added by the layout as usual.
    private static func placeholder(for size: CGSize) -> String {
        let fontSize = original_src_styles.FONT_SIZES.nodeLabel
        let weight = original_src_styles.FONT_WEIGHTS.nodeLabel
        var line = " "
        while original_src_text_metrics.measureMultilineText(line, fontSize: fontSize, fontWeight: weight).width < size.width,
              line.count < 400 {
            line.append(" ")
        }
        var text = line
        while original_src_text_metrics.measureMultilineText(text, fontSize: fontSize, fontWeight: weight).height < size.height,
              text.count < 4000 {
            text += "\n" + line
        }
        return text
    }

    /// Two things Mermaid.js accepts that BeautifulMermaid's parser doesn't:
    ///
    /// - A YAML front-matter block (`---\nconfig: …\n---`) before the
    ///   diagram type. It only carries config we can't honour anyway
    ///   (`wrappingWidth`, themes), so drop it rather than fail with
    ///   `invalidHeader("---")`.
    /// - Inline HTML formatting in labels (`<b>`, `<i>`, `<code>`, …).
    ///   The parser passes those through as literal text. Strip the tags
    ///   and keep the content; `<br/>` is understood and left alone.
    static func sanitize(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        // Front matter: leading `---` line … next `---` line.
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].trimmingCharacters(in: .whitespaces) == "---",
           let close = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(first...close)
        }
        var joined = lines.joined(separator: "\n")
        // xychart: `line "interest" [...]` / `bar "x" [...]` — the parser
        // only knows the unnamed form.
        if joined.contains("xychart") {
            joined = joined.replacingOccurrences(
                of: #"(?m)^(\s*)(line|bar)\s+"[^"]*"\s*\["#,
                with: "$1$2 [",
                options: .regularExpression
            )
        }
        guard joined.contains("<") else { return joined }
        return joined.replacingOccurrences(
            of: #"</?(?:b|i|u|s|strong|em|small|sup|sub|span|code|tt|font|mark)(?:\s[^<>]*)?>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    // The parser lets a node be claimed by several subgraphs (e.g. `A --> B`
    // inside `subgraph X` and `B` declared in `subgraph Y`). The layout builder
    // then emits B as a child of both compound nodes, and ELK asserts on the
    // edge-container mismatch. Mermaid.js gives the node to the subgraph that
    // mentioned it last; do the same so each node has exactly one owner.
    private static func normalizeSubgraphOwnership(_ model: ParsedGraphModel) {
        var owner: [String: ObjectIdentifier] = [:]
        func claim(_ subgraph: original_src_types.MermaidSubgraph) {
            for id in subgraph.nodeIds { owner[id] = ObjectIdentifier(subgraph) }
            subgraph.children.forEach(claim)
        }
        func prune(_ subgraph: original_src_types.MermaidSubgraph) {
            let me = ObjectIdentifier(subgraph)
            subgraph.nodeIds.removeAll { owner[$0] != me }
            subgraph.children.forEach(prune)
        }
        model.subgraphs.forEach(claim)
        model.subgraphs.forEach(prune)
    }
}

private struct SendableMermaidImage: @unchecked Sendable {
    let image: NSImage?
}

enum MDVMermaidImage {
    static func exportPNG(source: String, theme: MDVTheme, style: MermaidRenderStyle) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "mermaid-diagram.png"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let key = MDVMermaidRenderKey(source: source, theme: theme, style: style)
        Task {
            guard let image = await MDVMermaidImageCache.shared.image(source: source, theme: theme, style: style, key: key),
                  let pngData = image.pngData else {
                NSSound.beep()
                return
            }

            do {
                try pngData.write(to: url, options: .atomic)
            } catch {
                NSSound.beep()
            }
        }
    }
}

private struct MermaidFallbackView: View {
    let source: String
    let theme: MDVTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mermaid diagram could not be rendered")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text(source)
                .font(.system(size: max(theme.baseFontSize * 0.82, 11), design: .monospaced))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    var bitmapCost: Int {
        var rect = CGRect(origin: .zero, size: size)
        guard let cgImage = cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return max(Int(size.width * size.height * 4), 1)
        }
        return max(cgImage.bytesPerRow * cgImage.height, 1)
    }
}

private extension MDVTheme {
    var mermaidDiagramTheme: DiagramTheme {
        let backgroundColor = nsColor(for: resolvedCodePalette.background ?? secondaryBackground, fallbackRGBA: isDark ? 0x252D40FF : 0xF6F8FAFF)
        let foregroundColor = nsColor(for: text, fallbackRGBA: isDark ? 0xC9D1D9FF : 0x24292FFF)
        let accentColor = nsColor(for: accent, fallbackRGBA: isDark ? 0x58A6FFFF : 0x0969DAFF)
        let lineColor = backgroundColor.mixed(with: foregroundColor, amount: isDark ? 0.70 : 0.62)
        let nodeSurfaceColor = backgroundColor.mixed(with: foregroundColor, amount: isDark ? 0.16 : 0.06)
        let nodeBorderColor = backgroundColor.mixed(with: foregroundColor, amount: isDark ? 0.58 : 0.42)

        return DiagramTheme(
            background: backgroundColor,
            foreground: foregroundColor,
            line: lineColor,
            accent: accentColor,
            muted: backgroundColor.mixed(with: foregroundColor, amount: isDark ? 0.62 : 0.54),
            surface: nodeSurfaceColor,
            border: nodeBorderColor,
            font: .systemFont(ofSize: max(baseFontSize * 0.86, 12)),
            lineWidth: 2.1,
            cornerRadius: 8
        )
    }

    func nsColor(for color: Color, fallbackRGBA: UInt32) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB)
            ?? NSColor(Color(rgba: fallbackRGBA)).usingColorSpace(.sRGB)
            ?? .black
    }
}
