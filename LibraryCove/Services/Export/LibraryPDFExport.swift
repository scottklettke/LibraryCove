import Foundation
import SwiftData
import UIKit

/// One book flattened into plain values for PDF rendering.
///
/// `Book` is a SwiftData `@Model`, so the render pass must never touch it —
/// the snapshot is taken on the main actor (where the model container lives)
/// and rendering runs elsewhere on these value types only. Cover bytes are
/// resolved up front exactly like `LibraryDataService.export` does; images are
/// decoded per card and released so a large library never holds every
/// `UIImage` at once.
struct BookCatalogEntry: Identifiable {
    var id: String
    var title: String
    var authors: [String]
    var isbn: String?
    var publicationYear: Int?
    var tags: [String]
    var shelves: [String]
    var statusDisplay: String
    var publisher: String?
    var pageCount: Int?
    var bookDescription: String?
    var language: String?
    var physicalLocation: String?
    var rating: Int?
    var loanedTo: String?
    var ownerName: String?
    var acquiredDate: Date?
    var coverData: Data?
}

/// What the user wants included in the exported PDF catalog.
struct PDFExportOptions: Equatable {
    enum Layout: String, CaseIterable, Identifiable {
        case cards
        case list
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .cards: return "Catalog cards"
            case .list: return "Simple list"
            }
        }
    }

    enum CoverSize: String, CaseIterable, Identifiable {
        case small
        case medium
        case large
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
    }

    var layout: Layout = .cards
    /// Catalog-card layout only; the list layout uses fixed small rows.
    var coverSize: CoverSize = .medium
    var includeStats: Bool = true
    var includeISBN: Bool = true
    var includeDescription: Bool = true
    var includeLocation: Bool = true
    var includeRating: Bool = true
    var includeShelves: Bool = true
    var includeTags: Bool = true
    /// Shorthand: both tag toggles off hides the labels line entirely.
    var includeLabels: Bool { includeShelves || includeTags }

    /// Reproduces the original catalog design exactly.
    static let `default` = PDFExportOptions()
}

/// High-quality PDF catalog of a set of books ("what you see" in the library:
/// the filtered/sorted view normally, or just the selection while selecting).
///
/// Layout is a designed print document: a cover page, an optional stats page,
/// then unsplittable book units flowing across US Letter pages — either
/// catalog cards (cover thumbnail at left, full metadata and description at
/// right) or compact list rows — with numbered entry footers and ISBNs.
/// Rendered with `UIGraphicsPDFRenderer` (vector text, no new dependencies).
@MainActor
enum LibraryPDFExport {
    /// Resolves each book into a `BookCatalogEntry`, downloading remote covers
    /// once per distinct URL (same precedence as the zip export). Injectable
    /// `fetchRemoteCover` for tests.
    static func makeEntries(
        from books: [Book],
        ownerNames: [String: String] = [:],
        fetchRemoteCover: @escaping (URL) async -> Data? = LibraryDataService.fetchRemoteCover
    ) async -> [BookCatalogEntry] {
        let remoteCovers = Set(books.compactMap(\.coverImageURL)
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") })
        var fetchedRemotes: [String: Data] = [:]
        if !remoteCovers.isEmpty {
            await withTaskGroup(of: (String, Data?).self) { group in
                for urlString in remoteCovers {
                    group.addTask {
                        guard let url = URL(string: urlString) else { return (urlString, nil) }
                        return (urlString, await fetchRemoteCover(url))
                    }
                }
                for await (urlString, data) in group where data != nil {
                    fetchedRemotes[urlString] = data
                }
            }
        }

        return books.map { book in
            var coverData: Data?
            if let cover = book.coverImageURL {
                if cover.hasPrefix("http://") || cover.hasPrefix("https://") {
                    coverData = fetchedRemotes[cover]
                } else {
                    coverData = CoverImageStore.localData(forCover: cover)
                }
            }
            return BookCatalogEntry(
                id: book.id,
                title: book.title,
                authors: book.authors,
                isbn: book.isbn,
                publicationYear: book.publicationYear,
                tags: book.tags,
                shelves: book.shelves,
                statusDisplay: book.statusEnum.displayName,
                publisher: book.publisher,
                pageCount: book.pageCount,
                bookDescription: book.bookDescription,
                language: book.language,
                physicalLocation: book.physicalLocation,
                rating: book.rating,
                loanedTo: book.loanedTo,
                ownerName: book.ownerID.flatMap { ownerNames[$0] },
                acquiredDate: book.acquiredDate,
                coverData: coverData
            )
        }
    }

    /// Resolved geometry for one render pass: thumbnail size and text column
    /// derive from the chosen options, so measurement and drawing can never
    /// disagree.
    private struct PDFCardLayout {
        let coverWidth: CGFloat
        let coverHeight: CGFloat
        let textLeft: CGFloat
        let textWidth: CGFloat
        let blockGap: CGFloat

        init(options: PDFExportOptions) {
            switch options.coverSize {
            case .small:
                coverWidth = 64
                coverHeight = 96
            case .medium:
                coverWidth = 92
                coverHeight = 138
            case .large:
                coverWidth = 122
                coverHeight = 183
            }
            textLeft = margin + coverWidth + 16
            textWidth = pageWidth - margin - textLeft
            blockGap = 26
        }
    }

    /// Renders the catalog PDF. Depends only on the snapshot values, static
    /// fonts/colors, the options, and the passed-in brand image, so it is
    /// safe to call from any actor. Returns `nil` only when there is nothing
    /// to draw.
    nonisolated static func render(
        _ entries: [BookCatalogEntry],
        title: String,
        options: PDFExportOptions = .default,
        generatedAt: Date = Date(),
        brandImage: UIImage? = nil,
        filtersNote: String? = nil
    ) -> Data? {
        guard !entries.isEmpty else { return nil }
        // Catalog order: alphabetical by author, then by title within the
        // same author, with entry id as a final tiebreak so equal
        // author+title pairs always render in the same order. Locale-aware
        // and case/diacritic-insensitive so "de Souza" sorts near "De Souza"
        // and accents don't break grouping.
        let sorted = entries.sorted { a, b in
            let aAuthors = a.authors.isEmpty ? ["Unknown"] : a.authors
            let bAuthors = b.authors.isEmpty ? ["Unknown"] : b.authors
            let result = aAuthors.joined(separator: ", ").compare(
                bAuthors.joined(separator: ", "),
                options: [.caseInsensitive, .diacriticInsensitive, .forcedOrdering],
                locale: Locale.current
            )
            if result != .orderedSame { return result == .orderedAscending }
            let titleResult = a.title.compare(
                b.title,
                options: [.caseInsensitive, .diacriticInsensitive, .forcedOrdering],
                locale: Locale.current
            )
            if titleResult != .orderedSame { return titleResult == .orderedAscending }
            return a.id < b.id
        }
        let layout = PDFCardLayout(options: options)
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        )
        return renderer.pdfData { context in
            drawCoverPage(
                context: context,
                entries: sorted,
                title: title,
                generatedAt: generatedAt,
                brandImage: brandImage,
                filtersNote: filtersNote
            )
            let drewStats = options.includeStats
                ? drawStatsPage(context: context, entries: sorted)
                : false

            // Book pages start on a fresh page (stats is optional), numbered
            // continuously from the cover page.
            context.beginPage()
            var pageNumber = drewStats ? 3 : 2
            var cursor = contentTop
            for (index, entry) in sorted.enumerated() {

                let height = blockHeight(for: entry, layout: layout, options: options)
                if cursor + height > contentBottom {
                    context.beginPage()
                    pageNumber += 1
                    cursor = contentTop
                }
                drawRunningHeader(context: context, title: title, generatedAt: generatedAt, page: pageNumber)
                drawBookUnit(
                    entry,
                    number: index + 1,
                    top: cursor,
                    layout: layout,
                    options: options
                )
                cursor += height + layout.blockGap
            }
        }
    }

    // MARK: - Geometry & typography

    /// US Letter in points (72 dpi).
    static let pageWidth: CGFloat = 612
    static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 54
    private static var contentWidth: CGFloat { pageWidth - margin * 2 }
    private static var contentTop: CGFloat { 66 }
    private static var contentBottom: CGFloat { pageHeight - 62 }
    private static let cardBottomPad: CGFloat = 9
    private static let listRowPad: CGFloat = 6
    private static let footerRuleHeight: CGFloat = 12

    private static let titleFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
    private static let authorFont = UIFont.systemFont(ofSize: 10.5, weight: .medium)
    private static let bodyFont = UIFont.systemFont(ofSize: 9.5)
    private static let smallFont = UIFont.systemFont(ofSize: 8)
    private static let metaColor = UIColor(white: 0.45, alpha: 1)
    private static let textColor = UIColor(white: 0.15, alpha: 1)
    /// App accent (Assets: AccentColor, light value).
    private static let accent = UIColor(red: 0, green: 0.478, blue: 1.0, alpha: 1)

    private static let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: titleFont,
        .foregroundColor: textColor,
    ]
    private static let authorAttrs: [NSAttributedString.Key: Any] = [
        .font: authorFont,
        .foregroundColor: accent,
    ]
    private static let smallAttrs: [NSAttributedString.Key: Any] = [
        .font: smallFont,
        .foregroundColor: metaColor,
    ]
    private static let bodyAttrs: [NSAttributedString.Key: Any] = [
        .font: bodyFont,
        .foregroundColor: UIColor(white: 0.2, alpha: 1),
    ]

    // MARK: - Cover page

    private static func drawCoverPage(
        context: UIGraphicsPDFRendererContext,
        entries: [BookCatalogEntry],
        title: String,
        generatedAt: Date,
        brandImage: UIImage?,
        filtersNote: String?
    ) {
        context.beginPage()
        let bandHeight: CGFloat = 250

        UIColor(white: 0.97, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)).fill()

        accent.setFill()
        UIBezierPath(rect: CGRect(x: 0, y: 0, width: pageWidth, height: bandHeight)).fill()

        "Library Catalog".draw(
            at: CGPoint(x: margin, y: 30),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor(white: 1, alpha: 0.85),
            ]
        )

        let chip = CGRect(x: margin, y: 66, width: 52, height: 52)
        UIColor(white: 1, alpha: 0.18).setFill()
        UIBezierPath(roundedRect: chip, cornerRadius: 12).fill()
        if let brandImage {
            drawAspectFill(brandImage, in: chip.insetBy(dx: 6, dy: 6), cornerRadius: 9)
        } else {
            UIImage(systemName: "books.vertical.fill")?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: chip.insetBy(dx: 13, dy: 13))
        }

        "LIBRARYCOVE".draw(
            at: CGPoint(x: margin, y: 142),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .heavy),
                .foregroundColor: UIColor(white: 1, alpha: 0.8),
                .kern: 3.0,
            ]
        )
        drawWrapped(
            title.isEmpty ? "Library Catalog" : title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 33, weight: .bold),
                .foregroundColor: UIColor.white,
            ],
            in: CGRect(x: margin, y: 164, width: contentWidth, height: 74)
        )

        let count = entries.count
        let authorCount = Set(entries.flatMap(\.authors)).filter { $0 != "Unknown" }.count
        var summaryParts = ["\(count) book\(count == 1 ? "" : "s")"]
        if authorCount > 1 { summaryParts.append("\(authorCount) authors") }
        summaryParts.append(
            DateFormatter.localizedString(from: generatedAt, dateStyle: .long, timeStyle: .none)
        )
        summaryParts.joined(separator: "   ·   ").draw(
            at: CGPoint(x: margin, y: bandHeight + 38),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor(white: 0.35, alpha: 1),
            ]
        )

        // Active filters the export was scoped to, if any. One wrapped line
        // between the summary and the cover strip; "Filtered by" prefixes it
        // so the provenance is obvious in print.
        if let filtersNote, !filtersNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let note = "Filtered by " + filtersNote
            let noteAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10.5),
                .foregroundColor: accent,
            ]
            let noteHeight = (note as NSString).boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: noteAttrs,
                context: nil
            ).size.height
            drawWrapped(
                note,
                attributes: noteAttrs,
                in: CGRect(x: margin, y: bandHeight + 58, width: contentWidth, height: ceil(noteHeight))
            )
        }

        // A strip of cover thumbnails closes the page.
        var thumbX = margin
        for data in entries.compactMap(\.coverData).prefix(8) {
            guard let image = UIImage(data: data) else { continue }
            drawAspectFill(image, in: CGRect(x: thumbX, y: bandHeight + 74, width: 62, height: 92), cornerRadius: 6)
            thumbX += 70
            if thumbX + 62 > pageWidth - margin { break }
        }

        "Generated by LibraryCove".draw(
            at: CGPoint(x: margin, y: pageHeight - margin),
            withAttributes: [
                .font: smallFont,
                .foregroundColor: UIColor(white: 0.55, alpha: 1),
            ]
        )
    }

    // MARK: - Stats page

    @discardableResult
    private static func drawStatsPage(
        context: UIGraphicsPDFRendererContext,
        entries: [BookCatalogEntry]
    ) -> Bool {
        var byStatus: [String: Int] = [:]
        for entry in entries { byStatus[entry.statusDisplay, default: 0] += 1 }
        guard !byStatus.isEmpty else { return false }

        context.beginPage()
        drawRunningHeader(context: context, title: "Library Catalog", generatedAt: Date(), page: 2)

        "At a glance".draw(
            at: CGPoint(x: margin, y: contentTop + 12),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                .foregroundColor: UIColor(white: 0.1, alpha: 1),
            ]
        )
        let ordered = ["Reading", "To read", "Completed"].filter { byStatus[$0] != nil }
        let rest = byStatus.keys.filter { !ordered.contains($0) }.sorted()
        var y = contentTop + 56
        let labelWidth: CGFloat = 110
        let maxBar = contentWidth - labelWidth - 44
        for key in ordered + rest {
            let value = byStatus[key] ?? 0
            let ratio = CGFloat(value) / CGFloat(max(entries.count, 1))
            UIColor(white: 0.92, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: margin + labelWidth, y: y + 3, width: maxBar, height: 10)).fill()
            accent.setFill()
            UIBezierPath(rect: CGRect(x: margin + labelWidth, y: y + 3, width: max(2, ratio * maxBar), height: 10)).fill()
            "\(key) — \(value)".draw(
                at: CGPoint(x: margin, y: y),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 10.5),
                    .foregroundColor: UIColor(white: 0.25, alpha: 1),
                ]
            )
            y += 24
        }
        return true
    }

    // MARK: - Running furniture

    private static func drawRunningHeader(
        context: UIGraphicsPDFRendererContext,
        title: String,
        generatedAt: Date,
        page: Int
    ) {
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: UIColor(white: 0.55, alpha: 1),
        ]
        (title.isEmpty ? "Library Catalog" : title).draw(at: CGPoint(x: margin, y: 28), withAttributes: headerAttrs)
        let stamp = DateFormatter.localizedString(from: generatedAt, dateStyle: .short, timeStyle: .none)
        stamp.draw(
            at: CGPoint(x: pageWidth - margin - stamp.size(withAttributes: headerAttrs).width, y: 28),
            withAttributes: headerAttrs
        )
        UIColor(white: 0.88, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(x: margin, y: 46, width: contentWidth, height: 0.5)).fill()

        let pageText = "Page \(page)"
        let pageAttrs: [NSAttributedString.Key: Any] = [
            .font: smallFont,
            .foregroundColor: UIColor(white: 0.55, alpha: 1),
        ]
        pageText.draw(
            at: CGPoint(x: pageWidth - margin - pageText.size(withAttributes: pageAttrs).width, y: pageHeight - 40),
            withAttributes: pageAttrs
        )
    }

    // MARK: - Book units

    private struct Segment {
        let text: String
        let attrs: [NSAttributedString.Key: Any]
        let maxLines: Int
        let spacingBefore: CGFloat
    }

    /// The text column of a catalog card, as ordered measured segments. Both
    /// `blockHeight(for:layout:options:)` and `drawBookCard` iterate this same
    /// list, so the pre-measured block height can never drift from what is
    /// drawn. Respects the include toggles.
    private static func segments(
        for entry: BookCatalogEntry,
        options: PDFExportOptions
    ) -> [Segment] {
        var result: [Segment] = []
        func add(_ text: String, _ attrs: [NSAttributedString.Key: Any], maxLines: Int, spacing: CGFloat = 0) {
            result.append(Segment(text: text, attrs: attrs, maxLines: maxLines, spacingBefore: spacing))
        }

        add(entry.title.isEmpty ? "Untitled" : entry.title, titleAttrs, maxLines: 3)
        add(authorsText(entry), authorAttrs, maxLines: 2, spacing: 4)
        if !metaText(entry).isEmpty {
            add(metaText(entry), smallAttrs, maxLines: 1, spacing: 3)
        }
        add(factsText(entry, options: options), smallAttrs, maxLines: 2, spacing: 3)
        if options.includeLabels, let labels = labelsText(entry, options: options) {
            add(labels, smallAttrs, maxLines: 2, spacing: 3)
        }
        if options.includeDescription, let blurb = trimmedDescription(entry) {
            add(blurb, bodyAttrs, maxLines: 6, spacing: 5)
        }
        return result
    }

    /// Compact segments for the list layout: title, authors, and one meta
    /// line (year · publisher · pages · status, plus location/rating when
    /// their toggles are on — same gating as the catalog cards).
    private static func listSegments(
        for entry: BookCatalogEntry,
        options: PDFExportOptions
    ) -> [Segment] {
        var result: [Segment] = []
        result.append(Segment(
            text: entry.title.isEmpty ? "Untitled" : entry.title,
            attrs: titleAttrs, maxLines: 1, spacingBefore: 0
        ))
        result.append(Segment(
            text: authorsText(entry),
            attrs: authorAttrs, maxLines: 1, spacingBefore: 2
        ))
        var meta: [String] = []
        if !metaText(entry).isEmpty { meta.append(metaText(entry)) }
        meta.append(entry.statusDisplay)
        if options.includeLocation,
           let location = entry.physicalLocation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !location.isEmpty {
            meta.append(location)
        }
        if options.includeRating, let rating = entry.rating, (1...5).contains(rating) {
            meta.append(String(repeating: "★", count: rating))
        }
        if options.includeLabels, let labels = labelsText(entry, options: options) {
            meta.append(labels)
        }
        result.append(Segment(
            text: meta.joined(separator: "   ·   "),
            attrs: smallAttrs, maxLines: 1, spacingBefore: 2
        ))
        if options.includeDescription, let blurb = trimmedDescription(entry) {
            result.append(Segment(
                text: blurb,
                attrs: bodyAttrs, maxLines: 2, spacingBefore: 3
            ))
        }
        return result
    }

    /// Total height of one unsplittable book unit: the measured text plus the
    /// unit's bottom pad and footer rule. Cards are floored at the cover
    /// thumbnail height so the cover always fits; list rows measure across
    /// the full content width.
    private static func blockHeight(
        for entry: BookCatalogEntry,
        layout: PDFCardLayout,
        options: PDFExportOptions
    ) -> CGFloat {
        switch options.layout {
        case .cards:
            var textHeight: CGFloat = 0
            for segment in segments(for: entry, options: options) {
                textHeight += segment.spacingBefore + measuredHeight(segment, width: layout.textWidth)
            }
            let cardHeight = textHeight + cardBottomPad + footerRuleHeight
            return max(cardHeight, layout.coverHeight + cardBottomPad)
        case .list:
            var height: CGFloat = 0
            for segment in listSegments(for: entry, options: options) {
                height += segment.spacingBefore + measuredHeight(segment, width: contentWidth)
            }
            return height + listRowPad + footerRuleHeight
        }
    }

    private static func drawBookUnit(
        _ entry: BookCatalogEntry,
        number: Int,
        top: CGFloat,
        layout: PDFCardLayout,
        options: PDFExportOptions
    ) {
        let height = blockHeight(for: entry, layout: layout, options: options)

        if options.layout == .cards {
            drawCoverThumbnail(entry.coverData, layout: layout, top: top)
            var y = top
            for segment in segments(for: entry, options: options) {
                y += segment.spacingBefore
                let segHeight = measuredHeight(segment, width: layout.textWidth)
                drawWrapped(
                    segment.text,
                    attributes: segment.attrs,
                    in: CGRect(x: layout.textLeft, y: y, width: layout.textWidth, height: segHeight)
                )
                y += segHeight
            }
        } else {
            var y = top
            for segment in listSegments(for: entry, options: options) {
                y += segment.spacingBefore
                let segHeight = measuredHeight(segment, width: contentWidth)
                drawWrapped(
                    segment.text,
                    attributes: segment.attrs,
                    in: CGRect(x: margin, y: y, width: contentWidth, height: segHeight)
                )
                y += segHeight
            }
        }

        // Footer: numbered entry + hairline rule + ISBN at right, which
        // together make each unit read as a numbered catalog entry.
        let dividerY = top + height - footerRuleHeight
        UIColor(white: 0.9, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(x: margin, y: dividerY, width: contentWidth, height: 0.5)).fill()
        let footAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7.5, weight: .semibold),
            .foregroundColor: UIColor(white: 0.6, alpha: 1),
        ]
        String(format: "%03d", number).draw(at: CGPoint(x: margin, y: dividerY + 4), withAttributes: footAttrs)
        if options.includeISBN,
           let isbn = entry.isbn?.trimmingCharacters(in: .whitespacesAndNewlines), !isbn.isEmpty {
            let text = "ISBN \(isbn)"
            let width = text.size(withAttributes: footAttrs).width
            text.draw(at: CGPoint(x: pageWidth - margin - width, y: dividerY + 4), withAttributes: footAttrs)
        }
    }

    /// Aspect-fill cover thumbnail with a hairline border, or a grey
    /// placeholder when the entry has no usable cover bytes.
    private static func drawCoverThumbnail(
        _ coverData: Data?,
        layout: PDFCardLayout,
        top: CGFloat
    ) {
        let thumbFrame = CGRect(x: margin, y: top, width: layout.coverWidth, height: layout.coverHeight)
        if let data = coverData, let image = UIImage(data: data) {
            drawAspectFill(image, in: thumbFrame, cornerRadius: 5)
        } else {
            let placeholder = UIBezierPath(roundedRect: thumbFrame, cornerRadius: 5)
            UIColor(white: 0.94, alpha: 1).setFill()
            placeholder.fill()
            UIImage(systemName: "book.closed")?
                .withTintColor(UIColor(white: 0.7, alpha: 1), renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: thumbFrame.midX - 13, y: thumbFrame.midY - 13, width: 26, height: 26))
        }
        let border = UIBezierPath(roundedRect: thumbFrame, cornerRadius: 5)
        border.lineWidth = 0.5
        UIColor(white: 0.85, alpha: 1).setStroke()
        border.stroke()
    }

    // MARK: - Segment texts

    private static func authorsText(_ entry: BookCatalogEntry) -> String {
        entry.authors.isEmpty ? "Unknown" : entry.authors.joined(separator: ", ")
    }

    private static func metaText(_ entry: BookCatalogEntry) -> String {
        [
            entry.publicationYear.map(String.init),
            entry.publisher?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? entry.publisher : nil,
            entry.pageCount.map { "\($0) pp" },
            entry.language.map { "Lang: \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: "   ·   ")
    }
    private static func factsText(_ entry: BookCatalogEntry, options: PDFExportOptions) -> String {
        var facts = [entry.statusDisplay]
        if options.includeLocation,
           let location = entry.physicalLocation?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            facts.append(location)
        }
        if let owner = entry.ownerName, !owner.isEmpty { facts.append("Owner: \(owner)") }
        if options.includeRating, let rating = entry.rating, (1...5).contains(rating) {
            facts.append(String(repeating: "★", count: rating))
        }
        return facts.joined(separator: "   ·   ")
    }

    private static func labelsText(_ entry: BookCatalogEntry, options: PDFExportOptions) -> String? {
        var labels: [String] = []
        if options.includeShelves {
            labels += entry.shelves.map { "shelf: \($0)" }
        }
        if options.includeTags {
            labels += entry.tags
        }
        let cleaned = labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: " · ")
    }

    private static func trimmedDescription(_ entry: BookCatalogEntry) -> String? {
        guard let blurb = entry.bookDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !blurb.isEmpty else { return nil }
        return blurb
    }

    // MARK: - Text measurement & drawing

    /// Bounded line-wrapped height for a segment: the natural wrapped height
    /// capped at `maxLines` lines. Drawing clips to the same rect, so the cap
    /// keeps every block unsplittable and bounded.
    private static func measuredHeight(_ segment: Segment, width: CGFloat) -> CGFloat {
        let font = segment.attrs[.font] as? UIFont ?? UIFont.systemFont(ofSize: 10)
        let maxHeight = CGFloat(segment.maxLines) * font.lineHeight
        let size = (segment.text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: segment.attrs,
            context: nil
        ).size
        return min(ceil(size.height), maxHeight)
    }

    private static func drawWrapped(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        in rect: CGRect
    ) {
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
    }

    private static func drawAspectFill(_ image: UIImage, in frame: CGRect, cornerRadius: CGFloat) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        UIBezierPath(roundedRect: frame, cornerRadius: cornerRadius).addClip()
        let imageSize = image.size
        if imageSize.width > 0, imageSize.height > 0 {
            let scale = max(frame.width / imageSize.width, frame.height / imageSize.height)
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let drawOrigin = CGPoint(
                x: frame.midX - drawSize.width / 2,
                y: frame.midY - drawSize.height / 2
            )
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
        ctx.restoreGState()
    }
}
