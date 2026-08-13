import SwiftUI
import UIKit

/// Sheet for cropping a just-captured or already-stored cover photo to the
/// book cover.
///
/// A single drag gesture handles the whole canvas and picks its behavior from
/// where the finger lands:
///  - on a corner handler -> resize that corner (opposite pinned),
///  - near an edge -> resize that edge,
///  - anywhere inside -> move the box.
///
/// Routing by hit point (instead of separate per-handle gestures) avoids
/// SwiftUI gesture-arbitration races between overlapping views, so the corner
/// always stays under the finger. The crop is stored in normalized image
/// coordinates (0...1), so mapping to pixels is resolution-independent.
struct PhotoCropView: View {
    let sourceImage: UIImage
    let onConfirm: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Normalized crop rect in image space (0...1).
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Gesture bookkeeping for the current drag.
    @State private var activeTarget: DragTarget?
    @State private var startRect = CGRect.zero

    /// Hit-test radii in display points.
    private static let cornerRadius: CGFloat = 28
    private static let edgeInset: CGFloat = 22
    private static let minSide: CGFloat = 0.2

    enum DragTarget: Equatable {
        case move, edgeTop, edgeRight, edgeBottom, edgeLeft
        case cornerTL, cornerTR, cornerBL, cornerBR
    }

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

                    dimOverlay(size: geo.size, rect: rect)
                    guideOverlay(rect)

                    // A single invisible capture surface: routing by hit point
                    // inside the gesture, so nothing else can steal the drag.
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: geo.size.width, height: geo.size.height)
                        .gesture(dragGesture(frame: frame))

                    // Drop the visual affordances on top (non-interactive).
                    handlesAndEdges(rect)
                }
            }
            .background(Color.black)
            .overlay(alignment: .bottom) {
                Text("Drag on a corner or edge to resize, inside to move")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 10)
            }
            // The sheet's drag-to-dismiss would compete with the crop drag.
            .interactiveDismissDisabled()
            .presentationDragIndicator(.hidden)
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

    // MARK: - Gesture

    private func dragGesture(frame: CGRect) -> some Gesture {
        let frameSize = CGSize(width: frame.width, height: frame.height)
        return DragGesture(minimumDistance: 1)
            .onChanged { value in
                if activeTarget == nil {
                    activeTarget = hitTest(value.startLocation, rect: displayRect(frame))
                    startRect = crop
                }
                guard let target = activeTarget else { return }
                let dx = value.translation.width / frameSize.width
                let dy = value.translation.height / frameSize.height
                crop = Self.adjusted(startRect, target: target, dx: dx, dy: dy)
            }
            .onEnded { _ in
                activeTarget = nil
            }
    }

    /// Decides move vs. edge vs. corner from the initial touch point.
    private func hitTest(_ point: CGPoint, rect: CGRect) -> DragTarget {
        let pts: [(DragTarget, CGPoint)] = [
            (.cornerTL, .init(x: rect.minX, y: rect.minY)),
            (.cornerTR, .init(x: rect.maxX, y: rect.minY)),
            (.cornerBL, .init(x: rect.minX, y: rect.maxY)),
            (.cornerBR, .init(x: rect.maxX, y: rect.maxY)),
        ]
        for (target, corner) in pts {
            if hypot(point.x - corner.x, point.y - corner.y) <= Self.cornerRadius {
                return target
            }
        }
        // Edges (checked before interior so edge-drags resize).
        if point.y >= rect.minY - Self.edgeInset && point.y <= rect.minY + Self.edgeInset
            && point.x > rect.minX && point.x < rect.maxX { return .edgeTop }
        if point.y >= rect.maxY - Self.edgeInset && point.y <= rect.maxY + Self.edgeInset
            && point.x > rect.minX && point.x < rect.maxX { return .edgeBottom }
        if point.x >= rect.minX - Self.edgeInset && point.x <= rect.minX + Self.edgeInset
            && point.y > rect.minY && point.y < rect.maxY { return .edgeLeft }
        if point.x >= rect.maxX - Self.edgeInset && point.x <= rect.maxX + Self.edgeInset
            && point.y > rect.minY && point.y < rect.maxY { return .edgeRight }
        return .move
    }

    /// Applies a drag to the stored start rect in normalized space.
    /// Static so the math can be unit-tested.
    static func adjusted(_ start: CGRect, target: DragTarget, dx: CGFloat, dy: CGFloat) -> CGRect {
        switch target {
        case .move:
            let dt = max(0, 1 - start.width), dh = max(0, 1 - start.height)
            return CGRect(x: min(max(start.minX + dx, 0), dt),
                          y: min(max(start.minY + dy, 0), dh),
                          width: min(start.width, 1),
                          height: min(start.height, 1))
        case .edgeTop:
            let y = min(max(start.minY + dy, 0), start.maxY - Self.minSide)
            return CGRect(x: start.minX, y: y, width: start.width, height: start.maxY - y)
        case .edgeRight:
            let x = max(min(start.maxX + dx, 1), start.minX + Self.minSide)
            return CGRect(x: start.minX, y: start.minY, width: x - start.minX, height: start.height)
        case .edgeBottom:
            let y = max(min(start.maxY + dy, 1), start.minY + Self.minSide)
            return CGRect(x: start.minX, y: start.minY, width: start.width, height: y - start.minY)
        case .edgeLeft:
            let x = min(max(start.minX + dx, 0), start.maxX - Self.minSide)
            return CGRect(x: x, y: start.minY, width: start.maxX - x, height: start.height)
        case .cornerTL:
            let x = min(max(start.minX + dx, 0), start.maxX - Self.minSide)
            let y = min(max(start.minY + dy, 0), start.maxY - Self.minSide)
            return CGRect(x: x, y: y, width: start.maxX - x, height: start.maxY - y)
        case .cornerTR:
            let x = max(min(start.maxX + dx, 1), start.minX + Self.minSide)
            let y = min(max(start.minY + dy, 0), start.maxY - Self.minSide)
            return CGRect(x: start.minX, y: y, width: x - start.minX, height: start.maxY - y)
        case .cornerBL:
            let x = min(max(start.minX + dx, 0), start.maxX - Self.minSide)
            let y = max(min(start.maxY + dy, 1), start.minY + Self.minSide)
            return CGRect(x: x, y: start.minY, width: start.maxX - x, height: y - start.minY)
        case .cornerBR:
            let x = max(min(start.maxX + dx, 1), start.minX + Self.minSide)
            let y = max(min(start.maxY + dy, 1), start.minY + Self.minSide)
            return CGRect(x: start.minX, y: start.minY, width: x - start.minX, height: y - start.minY)
        }
    }

    // MARK: - Visual affordances (non-interactive)

    private func dimOverlay(size: CGSize, rect: CGRect) -> some View {
        Path { p in
            p.addRect(CGRect(origin: .zero, size: size))
            p.addRect(rect)
        }
        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func guideOverlay(_ rect: CGRect) -> some View {
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
        .allowsHitTesting(false)
    }

    /// Drawn after the gesture surface purely as a visual guide.
    private func handlesAndEdges(_ rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            let size: CGFloat = 30
            ForEach([CGPoint(x: rect.minX, y: rect.minY),
                     CGPoint(x: rect.maxX, y: rect.minY),
                     CGPoint(x: rect.minX, y: rect.maxY),
                     CGPoint(x: rect.maxX, y: rect.maxY)], id: \.x) { p in
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
                    .frame(width: size, height: size)
                    .position(x: p.x, y: p.y)
            }
        }
        .allowsHitTesting(false)
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
