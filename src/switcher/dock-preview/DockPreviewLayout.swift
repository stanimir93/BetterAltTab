import Cocoa

enum DockEdge: Equatable {
    case bottom
    case left
    case right
}

/// Geometry of the Dock hover panel, in Cocoa coordinates (origin bottom-left of the primary screen).
enum DockPreviewLayout {
    static let thumbnailHeight: CGFloat = 130
    static let minAspect: CGFloat = 0.6
    static let maxAspect: CGFloat = 2.2
    static let padding: CGFloat = 8
    static let spacing: CGFloat = 6
    static let tileInset: CGFloat = 6
    static let titleHeight: CGFloat = 22
    static let gapToIcon: CGFloat = 8
    static let screenMargin: CGFloat = 8

    /// The Dock hugs the screen edge its icon is closest to. Reading it from the icon's frame needs no
    /// `com.apple.dock orientation` read, and stays right for a Dock on a secondary screen.
    static func edge(_ icon: CGRect, _ screen: CGRect) -> DockEdge {
        let distances: [(DockEdge, CGFloat)] = [
            (.bottom, icon.minY - screen.minY),
            (.left, icon.minX - screen.minX),
            (.right, screen.maxX - icon.maxX),
        ]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// One thumbnail size per window, from each window's width/height ratio. Ratios are clamped so a very
    /// wide or very tall window still gets a usable tile. When the row (or column, for a side Dock) would be
    /// longer than `maxLength`, every tile shrinks by the same factor.
    static func thumbnailSizes(_ aspects: [CGFloat], maxLength: CGFloat, vertical: Bool) -> [CGSize] {
        let sizes = aspects.map { CGSize(width: (thumbnailHeight * clampedAspect($0)).rounded(), height: thumbnailHeight) }
        let length = panelLength(sizes, vertical: vertical)
        guard length > maxLength, length > 0 else { return sizes }
        let fixed = padding * 2 + spacing * CGFloat(max(0, sizes.count - 1)) + CGFloat(sizes.count) * tileInset * 2
            + (vertical ? CGFloat(sizes.count) * titleHeight : 0)
        let scale = max(0.2, (maxLength - fixed) / (length - fixed))
        return sizes.map { CGSize(width: ($0.width * scale).rounded(), height: ($0.height * scale).rounded()) }
    }

    static func tileSize(_ thumbnail: CGSize) -> CGSize {
        CGSize(width: thumbnail.width + tileInset * 2, height: thumbnail.height + titleHeight + tileInset * 2)
    }

    static func panelSize(_ thumbnails: [CGSize], vertical: Bool) -> CGSize {
        let tiles = thumbnails.map { tileSize($0) }
        let gaps = spacing * CGFloat(max(0, tiles.count - 1))
        if vertical {
            return CGSize(width: (tiles.map { $0.width }.max() ?? 0) + padding * 2,
                          height: tiles.reduce(0) { $0 + $1.height } + gaps + padding * 2)
        }
        return CGSize(width: tiles.reduce(0) { $0 + $1.width } + gaps + padding * 2,
                      height: (tiles.map { $0.height }.max() ?? 0) + padding * 2)
    }

    /// Centered on the icon, on the side of it facing away from the screen edge, and kept inside
    /// `visibleFrame` along the Dock.
    static func origin(_ panel: CGSize, icon: CGRect, edge: DockEdge, visibleFrame: CGRect) -> CGPoint {
        switch edge {
            case .bottom:
                return CGPoint(x: clamp(icon.midX - panel.width / 2, visibleFrame.minX, visibleFrame.maxX - panel.width),
                               y: icon.maxY + gapToIcon)
            case .left:
                return CGPoint(x: icon.maxX + gapToIcon,
                               y: clamp(icon.midY - panel.height / 2, visibleFrame.minY, visibleFrame.maxY - panel.height))
            case .right:
                return CGPoint(x: icon.minX - gapToIcon - panel.width,
                               y: clamp(icon.midY - panel.height / 2, visibleFrame.minY, visibleFrame.maxY - panel.height))
        }
    }

    /// The icon's frame stretched across the gap to the panel, so the pointer travelling from one to the
    /// other never crosses a spot that hides the panel.
    static func bridge(icon: CGRect, panel: CGRect, edge: DockEdge) -> CGRect {
        switch edge {
            case .bottom: return CGRect(x: icon.minX, y: icon.minY, width: icon.width, height: max(icon.height, panel.minY - icon.minY))
            case .left: return CGRect(x: icon.minX, y: icon.minY, width: max(icon.width, panel.minX - icon.minX), height: icon.height)
            case .right: return CGRect(x: panel.maxX, y: icon.minY, width: max(icon.width, icon.maxX - panel.maxX), height: icon.height)
        }
    }

    /// Aspect-fits `content` into `slot`, centered.
    static func fit(_ content: CGSize, in slot: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return slot }
        let scale = min(slot.width / content.width, slot.height / content.height)
        let size = CGSize(width: (content.width * scale).rounded(), height: (content.height * scale).rounded())
        return CGRect(x: (slot.midX - size.width / 2).rounded(), y: (slot.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    private static func panelLength(_ thumbnails: [CGSize], vertical: Bool) -> CGFloat {
        let size = panelSize(thumbnails, vertical: vertical)
        return vertical ? size.height : size.width
    }

    private static func clampedAspect(_ aspect: CGFloat) -> CGFloat {
        guard aspect.isFinite, aspect > 0 else { return 16 / 10 }
        return min(maxAspect, max(minAspect, aspect))
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(value, max(low, high)))
    }
}
