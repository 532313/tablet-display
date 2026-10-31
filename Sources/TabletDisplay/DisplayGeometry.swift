import Foundation

/// Pixel and logical dimensions of the virtual display. Keeping both is
/// important for HiDPI: a 2560x1600 panel can expose 1280x800 points, and an
/// orientation switch must preserve that 2x relationship.
struct DisplayGeometry: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let logicalWidth: Int
    let logicalHeight: Int

    init(pixelWidth: Int, pixelHeight: Int, logicalWidth: Int, logicalHeight: Int) {
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
        self.logicalWidth = max(1, logicalWidth)
        self.logicalHeight = max(1, logicalHeight)
    }

    init(pixelWidth: Int, pixelHeight: Int, useHiDPI: Bool) {
        let logicalWidth = useHiDPI ? max(1, pixelWidth / 2) : pixelWidth
        let logicalHeight = useHiDPI ? max(1, pixelHeight / 2) : pixelHeight
        self.init(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                  logicalWidth: logicalWidth, logicalHeight: logicalHeight)
    }

    var isHiDPI: Bool {
        logicalWidth * 2 == pixelWidth && logicalHeight * 2 == pixelHeight
    }

    /// Swap the display dimensions while preserving the pixel-to-point ratio.
    func oriented(portrait: Bool) -> DisplayGeometry {
        let pixelW = portrait ? min(pixelWidth, pixelHeight) : max(pixelWidth, pixelHeight)
        let pixelH = portrait ? max(pixelWidth, pixelHeight) : min(pixelWidth, pixelHeight)
        let logicalW = portrait ? min(logicalWidth, logicalHeight) : max(logicalWidth, logicalHeight)
        let logicalH = portrait ? max(logicalWidth, logicalHeight) : min(logicalWidth, logicalHeight)
        return DisplayGeometry(pixelWidth: pixelW, pixelHeight: pixelH,
                               logicalWidth: logicalW, logicalHeight: logicalH)
    }

    var isPortrait: Bool { pixelHeight > pixelWidth }
}
