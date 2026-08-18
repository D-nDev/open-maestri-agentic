import CoreGraphics

/// Conversion between CGRect and Maestri [[x,y],[w,h]] formats
extension CGRect {
    /// Convert from Maestri JSON format [[x, y], [width, height]]
    init?(frameArray: [[Double]]) {
        guard frameArray.count == 2,
              frameArray[0].count == 2,
              frameArray[1].count == 2 else {
            return nil
        }
        self.init(
            x: frameArray[0][0],
            y: frameArray[0][1],
            width: frameArray[1][0],
            height: frameArray[1][1]
        )
    }

    /// Convert to Maestri JSON format [[x, y], [width, height]]
    var frameArray: [[Double]] {
        [[origin.x, origin.y], [size.width, size.height]]
    }
}
