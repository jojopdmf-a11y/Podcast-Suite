import CoreGraphics
import Testing
@testable import PodLoungeCore

@Test func homeGridFitsFourEqualCells() {
    #expect(WorkspaceID.allCases == [.stripper, .fixer, .trimmer, .limiter])

    // Home area when the window content is about 1024×576 and the depot
    // uses its default width. The heading band sits above the four cards.
    let withDepot = CGSize(width: 1024 - 332, height: 576 - 80)
    let layout = LoungeHomeLayout.fitting(withDepot)
    #expect(layout.needsScroll == false)
    #expect(layout.cells.count == 4)
    expectEqualCells(layout, inside: withDepot)

    let strip = layout.cells[0]
    let decks = layout.cells[1]
    let cut = layout.cells[2]
    let roof = layout.cells[3]
    #expect(strip.x < decks.x)
    #expect(strip.y == decks.y)
    #expect(cut.x == strip.x)
    #expect(roof.x == decks.x)
    #expect(cut.y == roof.y)
    #expect(cut.y > strip.y)

    let withoutDepot = LoungeHomeLayout.fitting(CGSize(width: 1024, height: 576 - 80))
    #expect(withoutDepot.needsScroll == false)
    expectEqualCells(withoutDepot, inside: CGSize(width: 1024, height: 576 - 80))
    #expect(withoutDepot.cells[0].width > layout.cells[0].width)

    let tiny = LoungeHomeLayout.fitting(CGSize(width: 200, height: 160))
    #expect(tiny.needsScroll)
    #expect(tiny.cells.count == 4)
    #expect(tiny.cells.allSatisfy {
        $0.width >= LoungeHomeLayout.minimumCellWidth - 0.01
            && $0.height >= LoungeHomeLayout.minimumCellHeight - 0.01
    })
}

private func expectEqualCells(_ layout: LoungeHomeLayout, inside size: CGSize) {
    let width = layout.cells[0].width
    let height = layout.cells[0].height
    #expect(width > 0)
    #expect(height > 0)
    for cell in layout.cells {
        #expect(abs(cell.width - width) < 0.01)
        #expect(abs(cell.height - height) < 0.01)
        #expect(cell.x >= 0)
        #expect(cell.y >= 0)
        #expect(cell.x + cell.width <= size.width + 0.01)
        #expect(cell.y + cell.height <= size.height + 0.01)
    }
}
