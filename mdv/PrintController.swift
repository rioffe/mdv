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

    /// Pixels per point for a printed *diagram*.
    ///
    /// Lower than the formula density on purpose: a diagram is a full-column
    /// picture, so its pixel count grows with the square — at the formula's 12
    /// a Gantt chart lands at 1731 ppi and 11.7 MB for one page. 4 is 288 ppi,
    /// the usual print standard, and puts the same chart at ~2 MB.
    private static let printDiagramDensity: CGFloat = 4

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
        /// Typeset LaTeX, per block: same-size marker rectangles for the view
        /// tree (`\.resolvedInlineImages`, so the layout reserves each
        /// formula's place) plus the vector images to draw into those places
        /// afterwards — see `vectorizeFormulas`.
        var math: [Int: MathOverlay] = [:]
        /// Blocks that are nothing but a `$$…$$` formula, drawn as vector
        /// glyphs (see `standaloneFormula`).
        var formulaPages: [Int: BlockPage] = [:]
        /// Mermaid blocks whose diagram came back as a PDF, so its labels print
        /// as vector rather than as a raster of them (see `diagramPage`).
        var diagramPages: [Int: BlockPage] = [:]
    }

    /// A block's inline formulas: the images the page lays out with, and the
    /// vector versions drawn over them afterwards.
    private struct MathOverlay {
        /// Bitmap images keyed by image source. The page is laid out with
        /// these — they are what the reader gets if the overlay cannot run.
        let images: [String: Image]
        /// Solid background-coloured images of exactly the same size, used to
        /// lay the *finished* page out: invisible, and a few bytes each where
        /// a formula bitmap is kilobytes.
        let placeholders: [String: Image]
        /// The formulas to draw into their places, in document order.
        let formulas: [MathRendered]
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

    /// The printed page for a diagram block: the chrome the screen draws around
    /// a diagram — the code-block background, the 18/12pt insets — with the
    /// diagram itself drawn from its own PDF page and scaled to the printed
    /// column, so its labels stay vector.
    private static func diagramPage(
        diagram: CGPDFPage,
        diagramSize: CGSize,
        width: CGFloat,
        drawnWidth: CGFloat,
        theme: MDVTheme,
        typeScale: CGFloat
    ) -> BlockPage? {
        let verticalInset = 12 * typeScale
        let scale = min(1, max(drawnWidth, 1) / max(diagramSize.width, 1))
        let drawn = CGSize(width: diagramSize.width * scale, height: diagramSize.height * scale)
        let size = CGSize(width: width, height: drawn.height + verticalInset * 2)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        let background = NSColor(theme.resolvedCodePalette.background ?? theme.secondaryBackground)
        background.setFill()
        NSBezierPath(roundedRect: mediaBox, xRadius: 6, yRadius: 6).fill()
        ctx.saveGState()
        // Both pages are y-up, so the diagram is placed and scaled, not flipped.
        ctx.translateBy(x: (width - drawn.width) / 2, y: size.height - verticalInset - drawn.height)
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(diagram)
        ctx.restoreGState()
        ctx.endPDFPage()
        ctx.closePDF()
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        return BlockPage(document: document, page: page, size: size)
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

    /// A solid image of `size`, used to reserve a formula's place on a page
    /// that will have the formula drawn into it afterwards. Painted the page's
    /// own background — the colour the print container fills with — so it is
    /// invisible whatever the theme paints.
    private static func blankImage(size: CGSize, background: NSColor) -> NSImage {
        NSImage(size: NSSize(width: max(size.width, 1), height: max(size.height, 1)), flipped: false) { rect in
            background.setFill()
            rect.fill()
            return true
        }
    }

    /// Draws each inline formula over the bitmap the page was laid out with.
    ///
    /// Why this dance: SwiftUI draws inline images as bitmaps. Any `NSImage`
    /// handed to `Text(Image)` is rasterized — measured, SwiftMath's
    /// drawing-handler image and one backed by a PDF page both land at 72 ppi,
    /// and only a pre-baked bitmap keeps its own density — and `Text` ignores
    /// `AttributedString` attachments outright, so an inline `$…$` cannot be
    /// vector by itself. So the page is laid out with the bitmap in place, the
    /// image placements are read back out of it, and SwiftMath's drawing-handler
    /// image is drawn over each one — where a PDF context keeps the glyphs.
    ///
    /// Returns nil — leaving the page exactly as rendered, bitmaps and all —
    /// when the placements do not account for every formula, or a placement
    /// does not match the formula it should hold.
    private static func formulaPlacements(
        in page: BlockPage,
        overlay: MathOverlay?
    ) -> [CGRect]? {
        guard let overlay, !overlay.formulas.isEmpty,
              let placements = imagePlacements(in: page.page) else { return nil }
        // The page draws images in document order, so walk both lists in that
        // order and pair them by size. A placement matching no formula is some
        // other image in the block and is left alone.
        var rects: [CGRect] = []
        var remaining = overlay.formulas
        for placement in placements {
            guard let match = remaining.firstIndex(where: { formula in
                let size = formula.vectorImage.size
                return abs(placement.rect.width - size.width) <= 2
                    && abs(placement.rect.height - size.height) <= 2
            }) else { continue }
            rects.append(placement.rect)
            remaining.remove(at: match)
        }
        guard remaining.isEmpty, rects.count == overlay.formulas.count else { return nil }
        return rects
    }

    /// Draws the formulas into the page that was laid out with placeholders
    /// standing in for them, where a PDF context keeps them vector.
    private static func drawFormulas(
        _ formulas: [MathRendered],
        at rects: [CGRect],
        on page: BlockPage
    ) -> BlockPage? {
        guard rects.count == formulas.count else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: page.size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.drawPDFPage(page.page)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (rect, formula) in zip(rects, formulas) {
            formula.vectorImage.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let composed = document.page(at: 1) else { return nil }
        return BlockPage(document: document, page: composed, size: page.size)
    }

    /// Every image the page draws, in draw order, as a rect in page
    /// coordinates plus the image's own pixel size.
    ///
    /// Read out of the content stream rather than found by searching: the
    /// stream already records the order the images were drawn in, which is the
    /// order they appear in the document, so a formula can be paired with its
    /// placement without inferring anything from where a rectangle happens to
    /// be.
    private static func imagePlacements(in page: CGPDFPage) -> [(rect: CGRect, pixels: CGSize)]? {
        final class State {
            var ctm = CGAffineTransform.identity
            var stack: [CGAffineTransform] = []
            var placements: [(rect: CGRect, pixels: CGSize)] = []
            var xobjects: CGPDFDictionaryRef?
        }
        guard let pageDictionary = page.dictionary else { return nil }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources),
              let resourcesDictionary = resources else { return nil }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resourcesDictionary, "XObject", &xobjects),
              let xobjectDictionary = xobjects else { return nil }
        let state = State()
        state.xobjects = xobjectDictionary

        guard let table = CGPDFOperatorTableCreate() else { return nil }
        defer { CGPDFOperatorTableRelease(table) }
        let info = Unmanaged.passUnretained(state).toOpaque()
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            state.stack.append(state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            state.ctm = state.stack.popLast() ?? .identity
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var a = CGPDFReal(), b = CGPDFReal(), c = CGPDFReal()
            var d = CGPDFReal(), e = CGPDFReal(), f = CGPDFReal()
            guard CGPDFScannerPopNumber(scanner, &f), CGPDFScannerPopNumber(scanner, &e),
                  CGPDFScannerPopNumber(scanner, &d), CGPDFScannerPopNumber(scanner, &c),
                  CGPDFScannerPopNumber(scanner, &b), CGPDFScannerPopNumber(scanner, &a) else { return }
            let transform = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f)
            state.ctm = state.ctm.concatenating(transform)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name, let xobjects = state.xobjects else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xobjects, name, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype),
                  let subtype, String(cString: subtype) == "Image" else { return }
            var width = CGPDFInteger(), height = CGPDFInteger()
            CGPDFDictionaryGetInteger(dictionary, "Width", &width)
            CGPDFDictionaryGetInteger(dictionary, "Height", &height)
            state.placements.append((
                rect: CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm),
                pixels: CGSize(width: width, height: height)
            ))
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        let scanner = CGPDFScannerCreate(stream, table, info)
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
        return state.placements
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
        let typeScale = printTypeScale(contentWidth: contentWidth, theme: request.theme)
        // The block view insets the diagram 18pt per side (scaled with the rest
        // of the print margins), so this is the width the image is drawn at —
        // render at exactly that, at `printMathDensity`, and it lands 1:1 with
        // the pixels a printer can resolve. Screen-sized rasters (2 px/pt) are
        // what made a printed Gantt chart and typeset node labels look soft.
        let diagramWidth = max(contentWidth - 2 * 18 * typeScale, 1)
        // Diagrams lay themselves out at the width the *screen's* column would
        // give them and are drawn at `diagramWidth` — the same proportion the
        // type and the formulas print at. A diagram's label sizes are absolute
        // pixels, so laying one out at the narrow printed column is what makes
        // its text tower over the prose beside it.
        let diagramLayoutWidth = max(diagramWidth / typeScale, 1)
        var result = PrePass()

        for (idx, block) in request.blocks.enumerated() {
            if let source = mermaidSource(fromFencedBlock: block) {
                if isBeautifulMermaidSupported(source) {
                    let key = MDVMermaidRenderKey(
                        source: source,
                        theme: request.theme,
                        style: style,
                        scale: printDiagramDensity * typeScale
                    )
                    // `raster` at the print scale, rather than `image` (which is
                    // pinned to 2× for PNG export) — the layout is cached, only
                    // the pixels are redrawn.
                    if let prepared = await MDVMermaidImageCache.shared.prepared(
                        source: source, theme: request.theme, style: style, key: key
                    ) {
                        if let rendered = MDVMermaidPipeline.pdf(prepared, width: diagramLayoutWidth),
                           let page = diagramPage(
                               diagram: rendered.page,
                               diagramSize: rendered.size,
                               width: contentWidth,
                               // A native diagram has a natural size of its own,
                               // so it prints scaled by the type factor —
                               // uniformly, which is what keeps its proportions.
                               drawnWidth: rendered.size.width * typeScale,
                               theme: request.theme,
                               typeScale: typeScale
                           ) {
                            result.diagramPages[idx] = page
                        } else if let image = await MDVMermaidImageCache.shared.raster(
                            prepared, key: key, width: diagramLayoutWidth
                        ) {
                            // Fallback: the bitmap, which still prints as a
                            // diagram, just without vector labels.
                            result.images[idx] = image
                        } else {
                            result.failed.insert(idx)
                        }
                    } else {
                        result.failed.insert(idx)
                    }
                } else if let rendered = await MermaidWebRenderer.pdf(
                    source: source,
                    theme: request.theme,
                    width: diagramLayoutWidth
                ), let page = diagramPage(
                    diagram: rendered.page,
                    diagramSize: rendered.size,
                    width: contentWidth,
                    // The web path is laid out at the screen's column width, so
                    // drawing it at the printed column scales it by the type
                    // factor without distorting anything.
                    drawnWidth: diagramWidth,
                    theme: request.theme,
                    typeScale: typeScale
                ) {
                    // Gantt, pie, & co.: the bundled mermaid.js path, drawn from
                    // a PDF of the page so its labels print as vector.
                    result.diagramPages[idx] = page
                } else if let image = await MermaidWebRenderer.image(
                    source: source,
                    theme: request.theme,
                    width: diagramLayoutWidth,
                    displayWidth: diagramWidth,
                    density: printDiagramDensity
                ) {
                    // Fallback: the raster, which still prints as a diagram.
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
            var placeholders: [String: Image] = [:]
            var formulas: [MathRendered] = []
            for spec in source.specs {
                let rendered = await MathImageCache.shared.rendered(for: spec)
                images[spec.url] = Image(nsImage: rendered.image)
                placeholders[spec.url] = Image(nsImage: blankImage(
                    size: rendered.image.size,
                    background: NSColor(request.theme.background)
                ))
                formulas.append(rendered)
            }
            result.math[idx] = MathOverlay(images: images, placeholders: placeholders, formulas: formulas)
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

            if let page = prepass.formulaPages[idx] ?? prepass.diagramPages[idx] {
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
                resolvedInlineImages: prepass.math[idx]?.images ?? [:]
            )
            guard let render = renderBlockPDF(root: root, width: contentWidth) else {
                continue
            }
            let page = BlockPage(document: render.document, page: render.page, size: render.size)
            // Inline formulas print as vector: lay the page out with the bitmap
            // formulas (which is also what a failure falls back to), read back
            // where they landed, then lay the same page out with invisible
            // placeholders and draw the formulas into those places.
            var printed = page
            if let overlay = prepass.math[idx],
               let rects = formulaPlacements(in: page, overlay: overlay) {
                let blank = blockRoot(
                    markdown: source.markdown,
                    mermaidImage: prepass.images[idx],
                    theme: request.theme,
                    baseURL: request.baseURL,
                    width: contentWidth,
                    resolvedInlineImages: overlay.placeholders
                )
                if let render = renderBlockPDF(root: blank, width: contentWidth),
                   abs(render.size.height - page.size.height) <= 1,
                   let composed = drawFormulas(
                       overlay.formulas,
                       at: rects,
                       on: BlockPage(document: render.document, page: render.page, size: render.size)
                   ) {
                    printed = composed
                }
            }
            append(printed)
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

