import SwiftUI
import UIKit

/// Sheet for cropping a just-captured cover photo to the book cover.
///
/// Shows the photo with a draggable, resizable crop rectangle. Drag inside the
/// rectangle to move it; drag a corner to resize. The crop is stored in
/// normalized image coordinates (0...1) so mapping to pixels is resolution-
/// independent. Tapping Crop hands back a UIImage of the selected region,
/// drawn upright regardless of the camera's EXIF orientation.
struct PhotoCropView: View {
    let sourceImage: UIImage
    let onConfirm: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Normalized crop rect in image space (0...1).
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Smallest crop side as a fraction of the image side. 0.2 of a portrait
    /// photo is roughly the area a book cover occupies in a typical shot.
    private static let minSide: CGFloat = 0.2

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let frame = fittedFrame(in: geo.size)
                let rect = displayRect(frame)
                ZStack(alignment: .topLeading) {
                    Color.black
                        .ignoresSafeArea()

                    Image(uiImage: sourceImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)

                    // Dim everything outside the crop rect.
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: geo.size))
                        p.addRect(rect)
                    }
                    .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    // Border + rule-of-thirds grid.
                    Path { p in
                        p.addRect(rect)
                        for i in 1...2 {
                            let dx = rect.width / 3 * CGFloat(i)
                            let dy = rect.height / 3 * CGFloat(i)
                            p.move(to: CGPoint(x: rect.minX + dx, y: rect.minY))
                            p.addLine(to: CGPoint(x: rect.minX + dx, y: rect.maxY))
                            p.move(to: CGPoint(x: rect.minX, y: rect.minY + dy))
                            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + dy))
                        }
                    }
                    .stroke(Color.white, lineWidth: 1)

                    // Body of the crop rect: drag to move.
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .gesture(moveGesture(frame: frame))

                    // Corner handles.
                    let cornerSize: CGFloat = 24
                    cornerHandle(corner: 0, point: .init(x: rect.minX, y: rect.minY), frame: frame, size: cornerSize)
                    cornerHandle(corner: 1, point: .init(x: rect.maxX, y: rect.minY), frame: frame, size: cornerSize)
                    cornerHandle(corner: 2, point: .init(x: rect.minX, y: rect.maxY), frame: frame, size: cornerSize)
                    cornerHandle(corner: 3, point: .init(x: rect.maxX, y: rect.maxY), frame: frame, size: cornerSize)
                }
            }
            .background(Color.black)
            .overlay(alignment: .bottom) {
                Text("Position the box over the cover, then tap Crop")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 10)
            }
            .navigationTitle("Crop cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crop") { onConfirm(croppedImage()) }
                }
            }
        }
    }

    // MARK: - Geometry

    /// Fitted frame of the whole image inside the container.
    private func fittedFrame(in container: CGSize) -> CGRect {
        let imageSize = sourceImage.size
        let scale = min(container.width / imageSize.width,
                        container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }

    /// Normalized crop mapped to on-screen points inside the fitted frame.
    private func displayRect(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + crop.minX * frame.width,
               y: frame.minY + crop.minY * frame.height,
               width: crop.width * frame.width,
               height: crop.height * frame.height)
    }

    // MARK: - Gestures

    private func moveGesture(frame: CGRect) -> some Gesture {
        let start = crop
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.translation.width / frame.width
                let dy = value.translation.height / frame.height
                crop = clampedMove(start, dx: dx, dy: dy)
            }
    }

    private func cornerHandle(corner: UInt8, point: CGPoint,
                              frame: CGRect, size: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: size, height: size)
            .position(x: point.x, y: point.y)
            .gesture(resizeGesture(corner: corner, frame: frame))
    }

    private func resizeGesture(corner: UInt8, frame: CGRect) -> some Gesture {
        let start = crop
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.translation.width / frame.width
                let dy = value.translation.height / frame.height
                crop = resizedRect(from: start, corner: corner, dx: dx, dy: dy)
            }
    }

    // MARK: - Crop math

    private func clampedMove(_ start: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        let width = min(start.width, 1), height = min(start.height, 1)
        let x = min(max(start.minX + dx, 0), max(0, 1 - width))
        let y = min(max(start.minY + dy, 0), max(0, 1 - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Moves one corner while its diagonal opposite stays fixed, then clamps so
    /// the rect stays inside the image and never thinner than `minSide`.
    private func resizedRect(from start: CGRect, corner: UInt8, dx: CGFloat, dy: CGFloat) -> CGRect {
        switch corner {
        case 0: // top-left, opposite = bottom-right
            let x = min(max(start.minX + dx, 0), start.maxX - Self.minSide)
            let y = min(max(start.minY + dy, 0), start.maxY - Self.minSide)
            return CGRect(x: x, y: y,
                          width: start.maxX - x, height: start.maxY - y)
        case 1: // top-right, opposite = bottom-left
            let x = max(min(start.maxX + dx, 1), start.minX + Self.minSide)
            let y = min(max(start.minY + dy, 0), start.maxY - Self.minSide)
            return CGRect(x: start.minX, y: y,
                          width: x - start.minX, height: start.maxY - y)
        case 2: // bottom-left, opposite = top-right
            let x = min(max(start.minX + dx, 0), start.maxX - Self.minSide)
            let y = max(min(start.maxY + dy, 1), start.minY + Self.minSide)
            return CGRect(x: x, y: start.minY,
                          width: start.maxX - x, height: y - start.minY)
        default: // bottom-right, opposite = top-left
            let x = max(min(start.maxX + dx, 1), start.minX + Self.minSide)
            let y = max(min(start.maxY + dy, 1), start.minY + Self.minSide)
            return CGRect(x: start.minX, y: start.minY,
                          width: x - start.minX, height: y - start.minY)
        }
    }

    /// Renders the selected region as an upright UIImage.
    private func croppedImage() -> UIImage {
        let imageSize = sourceImage.size
        let pixelRect = CGRect(x: crop.minX * imageSize.width,
                               y: crop.minY * imageSize.height,
                               width: crop.width * imageSize.width,
                               height: crop.height * imageSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: pixelRect.size, format: format)
        return renderer.image { _ in
            // `draw(at:)` respects EXIF orientation, so the region lands upright.
            sourceImage.draw(at: CGPoint(x: -pixelRect.minX, y: -pixelRect.minY))
        }
    }
}
