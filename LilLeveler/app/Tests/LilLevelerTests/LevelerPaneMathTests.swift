import CoreGraphics
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

@Test func standaloneWindowFitsAMacBookScreen() {
    #expect(LevelerWindowFit.minimumContentWidth <= 1300)
    #expect(LevelerWindowFit.minimumContentHeight <= 840)
    #expect(LevelerWindowFit.minimumContentHeight + LevelerWindowFit.assumedTitleBarHeight <= 870)

    // 1512×982 point MacBook, menu bar already removed (visible height 949).
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
    let fit = LevelerWindowFit.contentSize(
        minimumWidth: LevelerWindowFit.minimumContentWidth,
        minimumHeight: LevelerWindowFit.minimumContentHeight,
        idealWidth: LevelerWindowFit.idealContentWidth,
        idealHeight: LevelerWindowFit.idealContentHeight,
        visible: visible,
        titleBar: LevelerWindowFit.assumedTitleBarHeight
    )
    #expect(fit.minWidth == LevelerWindowFit.minimumContentWidth)
    #expect(fit.minHeight == LevelerWindowFit.minimumContentHeight)
    #expect(fit.idealWidth == LevelerWindowFit.idealContentWidth)
    #expect(fit.idealHeight == LevelerWindowFit.idealContentHeight)
    #expect(fit.idealHeight + LevelerWindowFit.assumedTitleBarHeight <= visible.height)
    #expect(fit.idealWidth <= visible.width)

    let split = LevelerPaneMath.columns(
        available: LevelerWindowFit.minimumContentWidth - LevelerLayout.windowPadding * 2,
        preset: LevelerLayout.appPresetDefault,
        output: LevelerLayout.appOutputDefault,
        showsPreset: true,
        presetMin: LevelerLayout.appPresetMin,
        presetMax: LevelerLayout.appPresetMax,
        outputMin: LevelerLayout.appOutputMin,
        outputMax: LevelerLayout.appOutputMax,
        centerMin: LevelerLayout.appCenterMin,
        divider: LevelerPaneMetrics.divider
    )
    #expect(split.preset == LevelerLayout.appPresetDefault)
    #expect(split.output == LevelerLayout.appOutputDefault)
    #expect(split.center > LevelerLayout.appCenterMin)
}

@Test func standaloneWindowClampsToAShortScreen() {
    let visible = CGRect(x: 0, y: 0, width: 1280, height: 700)
    let fit = LevelerWindowFit.contentSize(
        minimumWidth: LevelerWindowFit.minimumContentWidth,
        minimumHeight: LevelerWindowFit.minimumContentHeight,
        idealWidth: LevelerWindowFit.idealContentWidth,
        idealHeight: LevelerWindowFit.idealContentHeight,
        visible: visible,
        titleBar: 28
    )
    #expect(fit.minWidth == 1180)
    #expect(fit.idealWidth == 1280)
    #expect(fit.minHeight == 672)
    #expect(fit.idealHeight == 672)
}
