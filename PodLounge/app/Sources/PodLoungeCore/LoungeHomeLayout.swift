import CoreGraphics
import Foundation

/// Four equal home-card cells. Order is TheStrip, TheDecks, TheCut, TheRoof.
///
/// The cells fill `size` under a short heading band. When a cell would be
/// smaller than the floor, `needsScroll` is true and the cells keep that floor
/// so a short window can scroll instead of crushing the title and the link.
public struct LoungeHomeLayout: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public var x: CGFloat
        public var y: CGFloat
        public var width: CGFloat
        public var height: CGFloat

        public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public static let contentPadding: CGFloat = 12
    public static let headingBand: CGFloat = 52
    public static let gridSpacing: CGFloat = 10
    public static let minimumCellWidth: CGFloat = 140
    public static let minimumCellHeight: CGFloat = 112

    public var cells: [Cell]
    public var needsScroll: Bool

    public var contentWidth: CGFloat {
        let edge = cells.map { $0.x + $0.width }.max() ?? 0
        return edge + Self.contentPadding
    }

    public var contentHeight: CGFloat {
        let edge = cells.map { $0.y + $0.height }.max() ?? 0
        return edge + Self.contentPadding
    }

    public init(cells: [Cell], needsScroll: Bool) {
        self.cells = cells
        self.needsScroll = needsScroll
    }

    /// Top-left, top-right, bottom-left, bottom-right.
    public static func fitting(_ size: CGSize) -> LoungeHomeLayout {
        let pad = contentPadding
        let gap = gridSpacing
        let innerWidth = max(0, size.width - pad * 2)
        let innerHeight = max(0, size.height - pad * 2 - headingBand)
        var cellWidth = max(0, (innerWidth - gap) / 2)
        var cellHeight = max(0, (innerHeight - gap) / 2)
        let needsScroll = cellWidth + 0.5 < minimumCellWidth || cellHeight + 0.5 < minimumCellHeight
        if needsScroll {
            cellWidth = max(cellWidth, minimumCellWidth)
            cellHeight = max(cellHeight, minimumCellHeight)
        }
        let originX = pad
        let originY = pad + headingBand
        let cells = [
            Cell(x: originX, y: originY, width: cellWidth, height: cellHeight),
            Cell(x: originX + cellWidth + gap, y: originY, width: cellWidth, height: cellHeight),
            Cell(x: originX, y: originY + cellHeight + gap, width: cellWidth, height: cellHeight),
            Cell(x: originX + cellWidth + gap, y: originY + cellHeight + gap, width: cellWidth, height: cellHeight),
        ]
        return LoungeHomeLayout(cells: cells, needsScroll: needsScroll)
    }
}
