import Foundation
import Testing

@testable import OSMmini

@Test func nativeScrollNormalizationRetainsFineTrackpadMotionAndWheelDirection() {
  #expect(abs(OfflineMapInputDelta.scroll(1, precise: true) - 1 / 240) < 0.000_001)
  #expect(abs(OfflineMapInputDelta.scroll(1, precise: false) - 0.2) < 0.000_001)
  for precise in [false, true] {
    #expect(OfflineMapInputDelta.scroll(0, precise: precise) == 0)
    let forward = OfflineMapInputDelta.scroll(0.25, precise: precise)
    let reverse = OfflineMapInputDelta.scroll(-0.25, precise: precise)
    #expect(forward > 0 && forward < 0.5)
    #expect(forward == -reverse)
    #expect(OfflineMapInputDelta.scroll(100_000, precise: precise) == 0.5)
    #expect(OfflineMapInputDelta.scroll(-100_000, precise: precise) == -0.5)
    #expect(OfflineMapInputDelta.scroll(.nan, precise: precise) == 0)
    #expect(OfflineMapInputDelta.scroll(.infinity, precise: precise) == 0)
    #expect(OfflineMapInputDelta.scroll(-.infinity, precise: precise) == 0)
  }
}

@Test func nativeMagnificationUsesMultiplicativeScaleWithoutDroppingSmallChanges() {
  let forward = OfflineMapInputDelta.magnification(0.1)
  let reverse = OfflineMapInputDelta.magnification(1 / 1.1 - 1)
  #expect(abs(forward - log2(1.1)) < 0.000_001)
  #expect(abs(forward + reverse) < 0.000_001)
  #expect(OfflineMapInputDelta.magnification(0.000_01) > 0)
  #expect(OfflineMapInputDelta.magnification(-0.000_01) < 0)
  #expect(OfflineMapInputDelta.magnification(1_000) == 0.5)
  #expect(OfflineMapInputDelta.magnification(-0.999) == -0.5)
  for invalid in [Double.nan, .infinity, -.infinity, -1, -2] {
    #expect(OfflineMapInputDelta.magnification(invalid) == 0)
  }
}
