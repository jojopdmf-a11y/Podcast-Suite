import Testing
@testable import LilLevelerKit

@Test func spareWidthGoesToTheMeterColumn() {
    let split = LevelerPaneMath.columns(
        available: 916,
        preset: 196,
        output: 292,
        showsPreset: true,
        presetMin: LevelerPaneMetrics.presetMin,
        presetMax: LevelerPaneMetrics.presetMax,
        outputMin: LevelerPaneMetrics.outputMin,
        outputMax: LevelerPaneMetrics.outputMax,
        centerMin: LevelerPaneMetrics.centerMin,
        divider: LevelerPaneMetrics.divider
    )
    #expect(split.preset == 196)
    #expect(split.output == 292)
    #expect(split.center == 408)
    #expect(split.center >= LevelerPaneMetrics.centerMin)
}

@Test func presetDragStopsAtTheCenterFloor() {
    let split = LevelerPaneMath.columns(
        available: 916,
        preset: 500,
        output: 292,
        showsPreset: true,
        presetMin: 184,
        presetMax: 320,
        outputMin: 276,
        outputMax: 420,
        centerMin: 400,
        divider: 10,
        lock: .output
    )
    #expect(split.output == 292)
    #expect(split.center == 400)
    #expect(split.preset == 204)
}

@Test func outputDragDoesNotShrinkPresets() {
    let split = LevelerPaneMath.columns(
        available: 1200,
        preset: 220,
        output: 800,
        showsPreset: true,
        presetMin: 184,
        presetMax: 320,
        outputMin: 276,
        outputMax: 420,
        centerMin: 400,
        divider: 10,
        lock: .preset
    )
    #expect(split.preset == 220)
    #expect(split.output == 420)
    #expect(split.center == 540)
}

@Test func tightWindowKeepsTheTextFloors() {
    let split = LevelerPaneMath.columns(
        available: LevelerPaneMetrics.columnsMinimum,
        preset: 80,
        output: 80,
        showsPreset: true,
        presetMin: LevelerPaneMetrics.presetMin,
        presetMax: LevelerPaneMetrics.presetMax,
        outputMin: LevelerPaneMetrics.outputMin,
        outputMax: LevelerPaneMetrics.outputMax,
        centerMin: LevelerPaneMetrics.centerMin,
        divider: LevelerPaneMetrics.divider
    )
    #expect(split.preset == LevelerPaneMetrics.presetMin)
    #expect(split.output == LevelerPaneMetrics.outputMin)
    #expect(split.center == LevelerPaneMetrics.centerMin)
}

@Test func spareHeightStaysOnTheMeters() {
    let split = LevelerPaneMath.band(available: 500, storedBottom: 180, topMin: 168, bottomMin: 180)
    #expect(split.bottom == 180)
    #expect(split.top == 320)
}

@Test func loudnessDragCannotEraseTheMeters() {
    let split = LevelerPaneMath.band(available: 400, storedBottom: 900, topMin: 168, bottomMin: 180)
    #expect(split.top == 168)
    #expect(split.bottom == 232)
}

@Test func depotCannotPushTheLimiterBelowItsFloor() {
    let maxDepot = LevelerPaneMath.depotMaximum(
        container: 1280,
        reserved: LevelerPaneMetrics.limiterWorkspaceMinimum,
        minimum: 260,
        cap: 560
    )
    #expect(maxDepot < 560)
    #expect(1280 - maxDepot >= LevelerPaneMetrics.limiterWorkspaceMinimum)

    let wide = LevelerPaneMath.depotMaximum(
        container: 2000,
        reserved: LevelerPaneMetrics.limiterWorkspaceMinimum,
        minimum: 260,
        cap: 560
    )
    #expect(wide == 560)
}
