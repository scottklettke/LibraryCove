import Testing
import SwiftData
import UIKit
@testable import BookNexus

@Suite struct BookModelTests {
    @Test func bookDefaults() throws {
        let book = Book(title: "Dune")
        #expect(book.title == "Dune")
        #expect(book.status == "to-read")
        #expect(book.syncState == "modified")
        #expect(book.authorsText == "Unknown")
    }

    @Test func statusParsing() throws {
        #expect(BookStatus(raw: "reading") == .reading)
        #expect(BookStatus(raw: "not-a-status") == nil)
    }
}

@Suite struct PersistenceTests {
    @MainActor @Test func inMemoryContainerInsertsBook() throws {
        let container = Persistence.inMemory
        let context = container.mainContext
        let book = Book(title: "Foundation")
        context.insert(book)
        try context.save()

        let fetch = FetchDescriptor<Book>()
        let books = try container.mainContext.fetch(fetch)
        #expect(books.count == 1)
        #expect(books.first?.title == "Foundation")
    }
}

@Suite struct CoverProcessorTests {

    /// A deterministic LCG so the generated "photo" is reproducible; the
    /// same seed always produces the same image (and thus the same byte sizes).
    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// Builds a photo-like cover image at iPhone-camera resolution: smooth
    /// colour gradients (what most of a book jacket is) plus fine textures
    /// and edge detail, so the JPEG has realistic content to encode.
    private func makePhotoLikeImage(width: CGFloat = 4032, height: CGFloat = 3024) -> UIImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // Diagonal colour wash (spine highlight → jacket shade).
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor(red: 0.16, green: 0.22, blue: 0.42, alpha: 1).cgColor,
                    UIColor(red: 0.62, green: 0.30, blue: 0.18, alpha: 1).cgColor,
                ] as CFArray,
                locations: [0, 1]
            )!
            ctx.cgContext.drawLinearGradient(gradient,
                                             start: .zero,
                                             end: CGPoint(x: width, y: height),
                                             options: [])
            // Fine grit so the JPEG carries real high-frequency detail.
            var rng = LCG(state: 0xC0FFEE)
            let cell: CGFloat = 64
            for y in stride(from: 0, through: height, by: cell) {
                for x in stride(from: 0, through: width, by: cell) {
                    let n = CGFloat(rng.next() % 100) / 100
                    UIColor(white: 0.5, alpha: 0.12 * n).setFill()
                    ctx.cgContext.fill(CGRect(x: x, y: y, width: cell, height: cell))
                }
            }
            // Vertical "page edges" for crisp structural detail.
            for x in stride(from: 0, through: width, by: 260) {
                ctx.cgContext.setAlpha(0.10)
                ctx.cgContext.move(to: CGPoint(x: x, y: 0))
                ctx.cgContext.addLine(to: CGPoint(x: x, y: height))
                ctx.cgContext.setStrokeColor(UIColor.white.cgColor)
                ctx.cgContext.strokePath()
            }
            ctx.cgContext.setAlpha(1)
        }
    }

    /// Downscaling must keep a meaningful quality ceiling while shrinking the
    /// stored payload substantially. Also logs the measured sizes so the
    /// space-savings estimate is grounded in the real encode pipeline.
    @MainActor @Test func resizeKeepsCoversCrispAndSmall() throws {
        let photo = makePhotoLikeImage()

        // True "before": the old BookFormView pipeline — UIGraphicsImageRenderer
        // default format, whose scale is the screen's (3x on iPhone), so a
        // `maxDimension: 900` point cap actually stored a 2700px JPEG.
        let oldSize = photo.size
        let oldScale = 900.0 / max(oldSize.width, oldSize.height)
        let oldNewSize = CGSize(width: oldSize.width * oldScale, height: oldSize.height * oldScale)
        let oldRenderer = UIGraphicsImageRenderer(size: oldNewSize)
        let oldResized = oldRenderer.image { _ in
            photo.draw(in: CGRect(origin: .zero, size: oldNewSize))
        }
        let oldURL = "data:image/jpeg;base64," + oldResized.jpegData(compressionQuality: 0.8)!.base64EncodedString()

        // "After": the shipped CoverImageData pipeline (current cap, scale-1).
        let newURL = try #require(CoverImageData.encode(photo))

        // Reference pixel caps for the estimate table (scale-1 renderers).
        func storedLength(pixels: CGFloat) -> Int {
            let r = CoverImageData.resize(photo, maxPixelDimension: pixels)
            return ("data:image/jpeg;base64," + r.jpegData(compressionQuality: 0.8)!.base64EncodedString()).utf8.count
        }

        let oldBytes = oldURL.utf8.count
        let newBytes = newURL.utf8.count
        let dim480 = storedLength(pixels: 480)
        let dim800 = storedLength(pixels: 800)

        print("COVER-SIZES old-900pt(2700px)-q0.8 stored=\(oldBytes)B "
              + "| new\(Int(CoverImageData.maxPixelDimension))px-q0.8 stored=\(newBytes)B "
              + "| 480px-q0.8 stored=\(dim480)B | 800px-q0.8 stored=\(dim800)B")

        // Contract: the stored URL is materially smaller than the old cap.
        #expect(newBytes < oldBytes / 2, "new cover should be <50% of the old stored size")

        // A canonical 3:2 cover photo would be upscaled from ~200→300px @3x for
        // the largest render; verify the stored 640px covers that corner case.
        let decoded = try #require(UIImage(data: Data(base64Encoded: String(newURL.drop(while: { $0 != "," }).dropFirst()))!))
        let longestEdge = max(decoded.size.width, decoded.size.height)
        #expect(longestEdge <= CoverImageData.maxPixelDimension + 1,
                "decoded cover should not exceed the pixel cap")
        let smallest = min(decoded.size.width, decoded.size.height)
        #expect(smallest >= CoverImageData.maxPixelDimension * 3 / 4,
                "aspect ratio must survive (portrait covers stay tall enough for a 100×140pt render)")
    }
}
