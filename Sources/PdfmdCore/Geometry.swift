/// Normalized page geometry and predicates.
///
/// Everything downstream of extraction uses `NormalizedRect`: each axis spans
/// 0...1 with the origin at the top-left of the page. PDFKit reports geometry
/// bottom-left in points and Vision reports bottom-left normalized quads; both
/// are converted at the extraction boundary (see `VisionExtractor` and
/// `PDFSource`) so the two conventions never leak into ordering, dedup, or
/// rendering.
public struct NormalizedRect: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let fullPage = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func intersection(_ other: NormalizedRect) -> NormalizedRect {
        let x0 = max(minX, other.minX)
        let y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX)
        let y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else {
            return NormalizedRect(x: 0, y: 0, width: 0, height: 0)
        }
        return NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Intersection area as a fraction of the smaller rect. Vision surfaces
    /// the same text through paragraph containers and table/list structure,
    /// so dedup is driven by overlap rather than string equality (which OCR
    /// noise would defeat).
    public func intersectionFractionOfSmaller(_ other: NormalizedRect) -> Double {
        let smaller = min(area, other.area)
        guard smaller > 0 else { return 0 }
        return intersection(other).area / smaller
    }

    /// True when `threshold` (default 0.6) of this rect lies inside `other`.
    public func isSubstantiallyContained(in other: NormalizedRect, threshold: Double = 0.6) -> Bool {
        guard area > 0, other.area > 0 else { return false }
        return intersection(other).area / area >= threshold
    }

    /// Shared horizontal band: vertical centers within `fraction` of the
    /// shorter block height. The primitive behind band-wise left-to-right
    /// ordering (see `ReadingOrder`).
    public func sharesHorizontalBand(with other: NormalizedRect, fraction: Double = 0.5) -> Bool {
        let h = min(height, other.height)
        guard h > 0 else { return false }
        return abs(midY - other.midY) <= h * fraction
    }
}
