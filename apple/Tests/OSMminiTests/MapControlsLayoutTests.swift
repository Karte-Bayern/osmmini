import Foundation
import Testing

@testable import OSMmini

@Test func mapControlsSwitchOrientationBeforeTheRailWouldCoverTheBottomEdge() {
  let configurations: [(CGFloat, CGFloat)] = [(36, 171), (44, 203)]
  for (buttonSize, requiredHeight) in configurations {
    let fitting = OfflineMapControlsLayout(
      mapSize: CGSize(width: 390, height: requiredHeight), buttonSize: buttonSize,
      hasLocation: true, hasRoute: true)
    let shallow = OfflineMapControlsLayout(
      mapSize: CGSize(width: 390, height: requiredHeight - 1), buttonSize: buttonSize,
      hasLocation: true, hasRoute: true)
    #expect(fitting.isVertical)
    #expect(fitting.frame.maxY == requiredHeight - 12)
    #expect(!shallow.isVertical)
    #expect(shallow.frame.height == buttonSize)
    #expect(shallow.frame.maxX == 378)
    #expect(shallow.frame.minX >= 12)
  }
}

@Test func mapControlObstaclesFollowOnlyTheVisibleRail() {
  let size = CGSize(width: 1000, height: 600)
  let configurations: [(Bool, Bool, CGFloat)] = [
    (false, false, 73), (true, false, 110), (false, true, 110), (true, true, 147),
  ]
  for (hasLocation, hasRoute, expectedHeight) in configurations {
    let layout = OfflineMapControlsLayout(
      mapSize: size, buttonSize: 36, hasLocation: hasLocation, hasRoute: hasRoute)
    #expect(layout.frame == CGRect(x: 952, y: 12, width: 36, height: expectedHeight))
    #expect(!layout.frame.contains(CGPoint(x: 950, y: 100)))
    #expect(!layout.frame.contains(CGPoint(x: 970, y: expectedHeight + 13)))
  }
  let touchLayout = OfflineMapControlsLayout(
    mapSize: size, buttonSize: 44, hasLocation: true, hasRoute: true)
  #expect(touchLayout.frame == CGRect(x: 944, y: 12, width: 44, height: 179))
}
