import AppKit
import MarkdownUI
import SwiftUI

/// Prints the rendered markdown document (⌘P → NSPrintOperation, whose
/// dialog's PDF dropdown doubles as Save-as-PDF).
///
/// Strategy: re-render every block through the same MarkdownUI pipeline the
/// screen uses, but via SwiftUI's `ImageRenderer` into one small vector PDF
/// per block. A plain flipped NSView composites those PDF pages in
/// `draw(_:)` and NSPrintOperation paginates it; `adjustPageHeightNew`
/// pushes a block that would straddle a page break onto the next page, so
/// breaks land in the gutters between blocks instead of through a line of
/// text.
///
/// Why ImageRenderer and not NSHostingView: hosting views composite through
/// the CoreAnimation render server, and their content never reaches
/// AppKit's print drawing context from an offscreen window — they print
/// blank. ImageRenderer renders without any window, and its CGContext path
/// keeps text as vector glyphs in the final PDF.
///
/// Mermaid diagrams render asynchronously on screen (`.task` →
/// MDVMermaidImageCache); ImageRenderer never runs async work, so blocks
/// are pre-rendered to NSImages before the view tree is built: native
/// types through the same raster cache, the gantt/pie/&-co that go
/// through the bundled mermaid.js via an offscreen WebView. A fence whose
/// render fails either way is re-tagged `mermaid` → `text` so it prints
/// as a plain code block rather than as an empty box. Metadata headers
/// (frontmatter) print as the same properties table the screen shows.
///
/// LaTeX is async for the same reason — MarkdownUI typesets `$…$` as an
/// inline image resolved in a `.task` — so the pre-pass typesets every
/// formula up front and hands the view tree the finished images through
/// `markdownResolvedInlineImages(_:)` (the one patch mdv carries on its
/// vendored MarkdownUI — see Vendor/MarkdownUI/README.md). Printed pages are
/// therefore vector text with formulas embedded at `printMathDensity`.
@MainActor
enum PrintController {
    /// How much smaller print type is than screen type, so that the printed
    /// page reads like the window does.
    ///
    /// What has to match is the *measure* — characters per line — not the
    /// point size: the screen sets `baseFontSize` (16pt) against the theme's
    /// `articleMaxWidth` column (860pt, ≈95–100 characters), while paper
    /// gives a 504pt column at Letter with the margins below. Set at the
    /// screen's 16pt the printed line holds only ~80 characters, so the page
    /// looks bigger and breaks paragraphs differently than the app does;
    /// scaling by the ratio of the two column widths (≈0.59 → 9.4pt) puts
    /// ~97 characters on both.
    ///
    /// Body, headings and code follow the result (em-relative sizes, and the
    /// code-block scale); the theme's absolute point margins deliberately
    /// don't, so block rhythm stays put while the type gets denser.
    private static func printTypeScale(contentWidth: CGFloat, theme: MDVTheme) -> CGFloat {
        guard let screenColumn = theme.articleMaxWidth, screenColumn > 0 else { return 1 }
        return min(1, contentWidth / screenColumn)
    }

    /// Pixels per point to bake the formulas that print as *images*.
    ///
    /// A standalone `$$…$$` block is drawn as vector glyphs (see
    /// `standaloneFormula`) and needs none of this. Inline `$…$` cannot be:
    /// MarkdownUI draws inline images with `Text(Image)`, and SwiftUI
    /// rasterizes any `NSImage` handed to it at 1 px/pt — measured, both for
    /// a drawing-handler image and for one backed by a PDF — so the only
    /// lever for an inline formula is how many pixels the bitmap it embeds
    /// carries. 12 → 864 ppi, which is above the 600 dpi most printers
    /// actually resolve, so the printer downsamples rather than stretches.
    /// Measured at 600 dpi output: 6 → 432 ppi gives p98 edge contrast 248,
    /// 12 gives 270, 24 adds nothing (270) for 55% more bytes.
    /// 6 costs 982 KB for test-docs/math.md, 12 costs 1.27 MB.
    private static let printMathDensity: CGFloat = 12

    /// TEMP SELF-TEST (delete): run the full print pipeline — pre-pass,
    /// container, AppKit pagination — and write the result to a PDF file
    /// instead of presenting a panel.
    static func selfTestPDF(_ request: Request, to url: URL) async {
        let printInfo = makePrintInfo()
        let prepass = await preRender(request: request, printInfo: printInfo)
        let container = buildContainer(request: request, prepass: prepass, printInfo: printInfo)
        let data = NSMutableData()
        let op = NSPrintOperation.pdfOperation(
            with: container, inside: container.bounds, to: data, printInfo: printInfo
        )
        op.run()
        try? data.write(to: url)
    }

    struct Request {
        let blocks: [String]
        let jobTitle: String
        let theme: MDVTheme
        let baseURL: URL?
        /// Effective flag — caller has already ANDed the user preference
        /// with the *print* theme's `smartTypographyAllowed`.
        let smartTypography: Bool
        /// Sheet parent. nil → app-modal dialog.
        let window: NSWindow?
        /// Block 0 as a properties table: `nil` means the document has no
        /// metadata header (print it as ordinary markdown), an empty array
        /// means the header exists but is hidden on screen (print nothing
        /// for that block), non-empty prints the table.
        let frontmatter: [FrontmatterRow]?
    }

    static func printDocument(_ request: Request) {
        // A print sheet is already up — don't stack a second modal session.
        guard activeSession == nil else {
            NSSound.beep()
            return
        }
        let printInfo = makePrintInfo()
        Task { @MainActor in
            let prepass = await preRender(request: request, printInfo: printInfo)
            // Leave the task context before building views or presenting the
            // panel: the macOS 26 print panel is SwiftUI-backed and its view
            // updates interrogate the current Swift-concurrency executor;
            // presented from inside this short-lived Task it crashes
            // (EXC_BAD_ACCESS in swift_task_isCurrentExecutor / DesignLibrary)
            // once the task is gone. A plain main-queue callout has no task
            // context to go stale. Reproduced 5/5 without this hop, 0/N with.
            DispatchQueue.main.async {
                let container = buildContainer(request: request, prepass: prepass, printInfo: printInfo)
                runOperation(container: container, printInfo: printInfo, request: request)
            }
        }
    }

    // MARK: - Print info

    private static func makePrintInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        // AppKit's standard header (job title + date) and footer (page
        // numbers), fed by PrintContainerView.printJobTitle.
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = NSNumber(value: true)
        return info
    }

    // MARK: - Pre-pass

    private struct PrePass {
        var images: [Int: NSImage] = [:]
        var failed: Set<Int> = []
        /// Typeset LaTeX, per block and keyed by image source. Handed to the
        /// view tree through `\.resolvedInlineImages` — see `blockRoot`.
        var math: [Int: [String: Image]] = [:]
        /// Blocks that are nothing but a `$$…$$` formula, drawn as vector
        /// glyphs (see `standaloneFormula`).
        var formulaPages: [Int: BlockPage] = [:]
    }

    /// Everything the print view tree needs for one block's markdown.
    private struct BlockSource {
        let markdown: String
        /// The math spans the block contains, in document order.
        let specs: [MathSpec]
        /// The block contained at least one `$…$` / `$$…$$` span, i.e. its
        /// laid-out content depends on async image resolution.
        var hasMath: Bool { !specs.isEmpty }
    }

    /// A block that is nothing but one `$$…$$` formula, if that is what it is.
    ///
    /// Those are printed by drawing SwiftMath's own image into the block's
    /// PDF page — the glyphs stay vector, so a standalone formula is as sharp
    /// as the prose around it at any zoom and on any printer. Going through
    /// MarkdownUI instead embeds a bitmap of it, which a viewer resampling
    /// the page (Preview at fit-to-window, say) renders soft, and which is
    /// what a reader notices most, because a display formula is large.
    private static func standaloneFormula(_ source: BlockSource) -> MathSpec? {
        guard source.specs.count == 1, let spec = source.specs.first, spec.display else { return nil }
        // The whole block, nothing but the image reference the rewrite emitted.
        return source.markdown.trimmingCharacters(in: .whitespacesAndNewlines) == "!\([])(\(spec.url))" ? spec : nil
    }

    /// Draws one formula into a page-sized PDF, centred like `MathDisplayView`
    /// centres it (`maxWidth: .infinity, alignment: .center`, 4pt of vertical
    /// padding, scaled down to the column if it is wider than one).
    private static func formulaPage(
        for spec: MathSpec,
        rendered: MathRendered,
        width: CGFloat
    ) -> BlockPage? {
        // A formula SwiftMath could not parse keeps the MarkdownUI path,
        // which prints the error and the source the way `MathDisplayView`
        // does — not just the source, which is all this page would show.
        guard rendered.error == nil else { return nil }
        let image = rendered.vectorImage
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return nil }
        let scale = min(1, width / natural.width)
        let drawn = CGSize(width: natural.width * scale, height: natural.height * scale)
        // 4pt padding, which is what `MathDisplayView` puts around a display
        // formula, scaled like every other margin here, and nothing else:
        // MarkdownUI's measured height for such a block stopped at the image,
        // so adding the paragraph's bottom margin would space printed formulas
        // differently from the blocks around them.
        let padding: CGFloat = 4 * printTypeScale(contentWidth: width, theme: .highContrast)
        let size = CGSize(width: width, height: drawn.height + padding * 2)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        // Not flipped: the page is y-up, and the block view puts the formula
        // at the top of the page with 4pt of padding above it.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(
            x: (width - drawn.width) / 2,
            y: size.height - padding - drawn.height,
            width: drawn.width,
            height: drawn.height
        ))
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        return BlockPage(document: document, page: page, size: size)
    }

    /// Mirrors the screen pipeline's order (`ContentView.blockView`): math
    /// spans become image references first, smartening runs after so it
    /// never rewrites LaTeX.
    private static func blockSource(
        _ block: String,
        mermaidFailed: Bool,
        smartTypography: Bool,
        theme: MDVTheme,
        typeScale: CGFloat
    ) -> BlockSource {
        let source = mermaidFailed ? retagMermaidFence(block) : block
        let rewritten = MathMarkdown.rewritten(
            source,
            fontSize: theme.baseFontSize * typeScale,
            headingSizeEms: theme.headingSizeEms,
            color: NSColor(theme.text),
            rasterScale: printMathDensity
        )
        return BlockSource(
            markdown: smartTypography ? smartenMarkdown(rewritten.markdown) : rewritten.markdown,
            specs: rewritten.specs
        )
    }

    private static func preRender(request: Request, printInfo: NSPrintInfo) async -> PrePass {
        // Same style preference MermaidCodeBlockChrome persists via
        // @AppStorage("mdv.mermaid.style") — only the native path honours it.
        let style = UserDefaults.standard.string(forKey: "mdv.mermaid.style")
            .flatMap(MermaidRenderStyle.init(rawValue:)) ?? .document
        let contentWidth = printInfo.paperSize.width
            - printInfo.leftMargin - printInfo.rightMargin
        // The block view pads the diagram 18pt per side; render the web page
        // at the width the image actually displays at.
        let diagramWidth = max(contentWidth - 36, 1)
        var result = PrePass()

        for (idx, block) in request.blocks.enumerated() {
            if let source = mermaidSource(fromFencedBlock: block) {
                if isBeautifulMermaidSupported(source) {
                    let key = MDVMermaidRenderKey(source: source, theme: request.theme, style: style)
                    if let image = await MDVMermaidImageCache.shared.image(
                        source: source, theme: request.theme, style: style, key: key
                    ) {
                        result.images[idx] = image
                    } else {
                        result.failed.insert(idx)
                    }
                } else if let image = await MermaidWebRenderer.image(
                    source: source, theme: request.theme, width: diagramWidth
                ) {
                    // Gantt, pie, & co.: the bundled mermaid.js path, rasterized
                    // offscreen so it prints like a native diagram rather than
                    // as its source.
                    result.images[idx] = image
                } else {
                    result.failed.insert(idx)
                }
                continue
            }

            // Block 0 with a metadata header prints as the properties table,
            // which has no markdown body to typeset.
            if idx == 0, request.frontmatter != nil { continue }

            let source = blockSource(
                block,
                mermaidFailed: result.failed.contains(idx),
                smartTypography: request.smartTypography,
                theme: request.theme,
                typeScale: printTypeScale(contentWidth: contentWidth, theme: request.theme)
            )
            guard source.hasMath else { continue }
            if let spec = standaloneFormula(source) {
                let rendered = await MathImageCache.shared.rendered(for: spec)
                if let page = formulaPage(for: spec, rendered: rendered, width: contentWidth) {
                    result.formulaPages[idx] = page
                    continue
                }
            }
            // Typeset the block's formulas now and pass them to the view tree.
            // That tree is drawn by `ImageRenderer`, which runs no async work,
            // so MarkdownUI would otherwise skip every inline image it hasn't
            // loaded — i.e. print the paragraph with its formulas missing.
            var images: [String: Image] = [:]
            for spec in source.specs {
                let rendered = await MathImageCache.shared.rendered(for: spec)
                images[spec.url] = Image(nsImage: rendered.image)
            }
            result.math[idx] = images
        }
        return result
    }

    /// If `block` is a single fenced code block whose info string names
    /// mermaid, returns the fence body; otherwise nil. The document's block
    /// splitter is fence-aware, so a mermaid fence is exactly one block.
    /// Language detection mirrors `CodeBlockChrome.displayLanguage` (first
    /// token of the info string).
    private static func mermaidSource(fromFencedBlock block: String) -> String? {
        var lines = block.components(separatedBy: "\n")
        guard let first = lines.first else { return nil }
        let trimmed = first.drop(while: { $0 == " " })
        let marker: String
        if trimmed.hasPrefix("```") { marker = "```" }
        else if trimmed.hasPrefix("~~~") { marker = "~~~" }
        else { return nil }
        let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        let language = info.split(separator: " ").first.map { $0.lowercased() } ?? ""
        guard language == "mermaid" else { return nil }
        lines.removeFirst()
        // Tolerate an unterminated fence at EOF.
        if let last = lines.last, last.drop(while: { $0 == " " }).hasPrefix(marker) {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// Failed mermaid render → print the source as a plain code block.
    /// Re-tagging the fence keeps it out of MermaidCodeBlockChrome (whose
    /// diagram view renders via `.task` and would print as an empty box).
    private static func retagMermaidFence(_ block: String) -> String {
        var lines = block.components(separatedBy: "\n")
        guard let first = lines.first,
              let range = first.range(of: "mermaid", options: .caseInsensitive) else { return block }
        lines[0] = first.replacingCharacters(in: range, with: "text")
        return lines.joined(separator: "\n")
    }

    // MARK: - Container construction

    /// The print view for one markdown block, shared by the pre-pass's math
    /// rasterizer and `buildContainer` so both render byte-identical trees.
    /// Pinning the width inside the root view makes the renderer (and the
    /// hosting view) report the ideal height at that width.
    private static func blockRoot(
        markdown: String,
        mermaidImage: NSImage?,
        theme: MDVTheme,
        baseURL: URL?,
        width: CGFloat,
        resolvedInlineImages: [String: Image] = [:]
    ) -> AnyView {
        // Margins scale with the type so the printed page keeps the screen's
        // proportions: the theme's margins are absolute points, so at 0.59×
        // type they would otherwise print ~1.7× looser than the window shows.
        let typeScale = printTypeScale(contentWidth: width, theme: theme)
        return AnyView(
            PrintBlockView(
                markdown: markdown,
                mermaidImage: mermaidImage,
                theme: theme,
                scale: typeScale,
                marginScale: typeScale,
                baseURL: baseURL
            )
            .frame(width: width, alignment: .topLeading)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
            // Formulas the view tree can't resolve itself (no async work under
            // `ImageRenderer`) — without these an inline `$…$` draws as nothing.
            .markdownResolvedInlineImages(resolvedInlineImages)
        )
    }

    private static func buildContainer(
        request: Request,
        prepass: PrePass,
        printInfo: NSPrintInfo
    ) -> PrintContainerView {
        let contentWidth = printInfo.paperSize.width
            - printInfo.leftMargin - printInfo.rightMargin
        let container = PrintContainerView(frame: .zero)
        container.pageBackground = NSColor(request.theme.background)
        container.jobTitle = request.jobTitle

        // Screen rhythm: LazyVStack spacing 8 + each block's 2pt vertical
        // hover padding × 2 — scaled with the type so the printed gutters keep
        // the screen's proportions.
        let spacing: CGFloat = 12 * printTypeScale(contentWidth: contentWidth, theme: request.theme)
        var y: CGFloat = 0
        func append(_ page: BlockPage) {
            let frame = NSRect(x: 0, y: y, width: contentWidth, height: ceil(page.size.height))
            container.blockRenders.append(
                PrintContainerView.BlockRender(
                    frame: frame, document: page.document, page: page.page
                )
            )
            y += frame.height + spacing
        }

        let typeScale = printTypeScale(contentWidth: contentWidth, theme: request.theme)
        for (idx, block) in request.blocks.enumerated() {
            if idx == 0, let frontmatter = request.frontmatter {
                // Block 0 is the metadata header: a properties table on
                // screen, or nothing at all when the user has hidden it —
                // mirror both instead of printing the raw fence as prose.
                guard !frontmatter.isEmpty else { continue }
                let root = AnyView(
                    FrontmatterTableView(
                        rows: frontmatter,
                        theme: request.theme,
                        fontScale: typeScale,
                        paddingScale: typeScale
                    )
                        .frame(width: contentWidth, alignment: .topLeading)
                        .environment(\.colorScheme, request.theme.isDark ? .dark : .light)
                )
                if let render = renderBlockPDF(root: root, width: contentWidth) {
                    append(BlockPage(document: render.document, page: render.page, size: render.size))
                }
                continue
            }

            if let page = prepass.formulaPages[idx] {
                append(page)
                continue
            }

            let source = blockSource(
                block,
                mermaidFailed: prepass.failed.contains(idx),
                smartTypography: request.smartTypography,
                theme: request.theme,
                typeScale: printTypeScale(contentWidth: contentWidth, theme: request.theme)
            )
            let root = blockRoot(
                markdown: source.markdown,
                mermaidImage: prepass.images[idx],
                theme: request.theme,
                baseURL: request.baseURL,
                width: contentWidth,
                resolvedInlineImages: prepass.math[idx] ?? [:]
            )
            guard let render = renderBlockPDF(root: root, width: contentWidth) else {
                continue
            }
            append(BlockPage(document: render.document, page: render.page, size: render.size))
        }
        container.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(y - spacing, 1))
        return container
    }

    /// Renders one block view into a single-page vector PDF at the given
    /// width, returning the PDF document, its first page, and the laid-out
    /// size. Text stays vector all the way into the print/Save-as-PDF
    /// output.
    ///
    /// The `document` is returned alongside the `page` and MUST be retained
    /// for as long as the page is used: a `CGPDFPage` does not retain its
    /// parent document, so dropping the document frees the page's backing
    /// bytes and any later `drawPDFPage` is a use-after-free.
    private static func renderBlockPDF(
        root: AnyView, width: CGFloat
    ) -> (document: CGPDFDocument, page: CGPDFPage, size: CGSize)? {
        let renderer = ImageRenderer(content: root)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)

        var laidOutSize = CGSize.zero
        let data = NSMutableData()
        renderer.render { size, renderInContext in
            laidOutSize = size
            guard size.width > 0, size.height > 0,
                  let consumer = CGDataConsumer(data: data as CFMutableData) else { return }
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            ctx.beginPDFPage(nil)
            renderInContext(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        guard laidOutSize.width > 0, laidOutSize.height > 0,
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        return (document, page, laidOutSize)
    }

    // MARK: - Run

    /// Keeps the container alive until the sheet-based print operation's
    /// did-run callback — `runModal(for:...)` returns immediately, so
    /// without this the view could be released mid-print.
    @MainActor
    private final class PrintSession: NSObject {
        let container: PrintContainerView
        var operation: NSPrintOperation?

        init(container: PrintContainerView) {
            self.container = container
        }

        // NSPrintOperation invokes the did-run selector on the main thread.
        @objc func printOperationDidRun(
            _ printOperation: NSPrintOperation,
            success: Bool,
            contextInfo: UnsafeMutableRawPointer?
        ) {
            PrintController.activeSession = nil
        }
    }

    private static var activeSession: PrintSession?

    private static func runOperation(
        container: PrintContainerView,
        printInfo: NSPrintInfo,
        request: Request
    ) {
        let op = NSPrintOperation(view: container, printInfo: printInfo)
        op.jobTitle = request.jobTitle
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling])

        if let parent = request.window {
            let session = PrintSession(container: container)
            session.operation = op
            activeSession = session
            op.runModal(
                for: parent,
                delegate: session,
                didRun: #selector(PrintSession.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        } else {
            op.run()
        }
    }
}

/// One page of a block's rendered output, retained as a unit: a `CGPDFPage`
/// does not retain its parent document, and dropping the document frees the
/// page's backing bytes.
private struct BlockPage {
    let document: CGPDFDocument
    let page: CGPDFPage
    let size: CGSize
}

// MARK: - Per-block print view

/// Print-side equivalent of ContentView.blockView: the plain Markdown path
/// only (no find highlights, hover stripes, or selection tints), type size
/// fixed at `printTypeScale(_:theme:)` regardless of screen zoom, remote
/// images forced
/// to the blocked placeholder so nothing in the tree depends on async work.
private struct PrintBlockView: View {
    let markdown: String
    let mermaidImage: NSImage?
    let theme: MDVTheme
    /// `PrintController.printTypeScale(_:theme:)` — body/heading/code type
    /// size for paper. Fixed (never derived from the screen's
    /// `themes.fontScale`) so printed output doesn't depend on the reader's
    /// on-screen zoom.
    let scale: CGFloat
    /// The same factor applied to the theme's absolute point margins, so the
    /// printed rhythm stays proportional to the type — i.e. it looks like the
    /// window does, rather than 1.7× looser than it.
    let marginScale: CGFloat
    let baseURL: URL?

    var body: some View {
        if let image = mermaidImage {
            // Mirrors MermaidCodeBlockChrome.diagramChrome / diagramBody
            // (unzoomed), minus the hover toolbar.
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(
                    image.size.height > 0 ? image.size.width / image.size.height : 1,
                    contentMode: .fit
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18 * marginScale)
                .padding(.vertical, 12 * marginScale)
                .background(theme.resolvedCodePalette.background ?? theme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Markdown(markdown)
                .markdownTheme(theme.markdownTheme(scale: scale, forPrint: true, marginScale: marginScale))
                .markdownCodeSyntaxHighlighter(.mdv(theme: theme, scale: scale))
                .markdownInlineImageProvider(MathInlineImageProvider())
                .markdownImageProvider(LocalImageProvider(
                    baseURL: baseURL,
                    loadRemoteImages: false
                ))
        }
    }
}

// MARK: - Container view

/// Flipped canvas that composites the per-block vector PDF pages in
/// `draw(_:)`. Pagination happens here: AppKit proposes a page bottom and
/// `adjustPageHeightNew` moves it up to the nearest block boundary when a
/// block would otherwise be sliced.
final class PrintContainerView: NSView {
    struct BlockRender {
        /// Container coordinates (flipped: y grows downward), sorted top-down.
        let frame: NSRect
        /// Retained so `page` stays valid — a CGPDFPage does not retain its
        /// parent document, and dropping the document frees the page's bytes.
        let document: CGPDFDocument
        let page: CGPDFPage
    }

    var blockRenders: [BlockRender] = []
    var pageBackground: NSColor = .white
    var jobTitle: String = "mdv"

    override var isFlipped: Bool { true }

    /// Feeds AppKit's standard print header.
    override var printJobTitle: String { jobTitle }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        pageBackground.setFill()
        dirtyRect.fill()
        for block in blockRenders where block.frame.intersects(dirtyRect) {
            ctx.saveGState()
            // Block PDFs are y-up; the container is flipped. Anchor at the
            // block's bottom edge and flip back to PDF coordinates.
            ctx.translateBy(x: block.frame.minX, y: block.frame.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.drawPDFPage(block.page)
            ctx.restoreGState()
        }
    }

    /// How far a page break may be pulled up, as a fraction of the page.
    /// AppKit's default is 0.2 — any block-boundary push larger than 20%
    /// of a page would be clamped and the block sliced anyway. 0.9 lets
    /// blocks up to ~90% of a page move wholesale to the next page.
    override var heightAdjustLimit: CGFloat { 0.9 }

    /// Flipped coordinates: y grows downward, `top < bottom`. `limit` is
    /// the highest allowed break (`top + (1 − heightAdjustLimit) × pageHeight`)
    /// — except on the document's final partial page, where AppKit still
    /// computes it from the full page height and it can land BEYOND
    /// `bottom`. The returned value must never exceed `bottom` ("*new not
    /// set or increased" assertion), so the bottom clamp is applied last.
    /// A block that straddles the proposed break and fits on a single page
    /// moves wholesale to the next page; blocks taller than a page (or
    /// starting exactly at the page top) slice at the default break.
    override func adjustPageHeightNew(
        _ newBottom: UnsafeMutablePointer<CGFloat>,
        top oldTop: CGFloat,
        bottom oldBottom: CGFloat,
        limit bottomLimit: CGFloat
    ) {
        var proposed = oldBottom
        let pageHeight = oldBottom - oldTop
        for block in blockRenders {
            let frame = block.frame
            if frame.minY >= oldBottom { break }       // below the break — done
            guard frame.maxY > oldBottom else { continue }  // fully above
            // This block straddles the proposed page break.
            if frame.height <= pageHeight && frame.minY > oldTop {
                proposed = frame.minY
            }
            break
        }
        newBottom.pointee = min(max(proposed, bottomLimit), oldBottom)
    }
}

