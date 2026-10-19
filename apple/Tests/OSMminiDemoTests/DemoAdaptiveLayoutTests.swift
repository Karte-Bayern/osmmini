import Foundation
import Testing

@testable import OSMminiDemoCLI

struct DemoAdaptiveLayoutTests {
  @Test func narrowPhoneAndResizedTabletKeepControlsBelowTheMap() {
    let sizes = [
      CGSize(width: 375, height: 600),
      CGSize(width: 466, height: 678),
      CGSize(width: 600, height: 700),
    ]
    for size in sizes {
      for accessibility in [false, true] {
        let metrics = DemoMapLayoutMetrics(
          size: size, accessibility: accessibility, expanded: true)
        #expect(metrics.sideWidth == nil)
        #expect(metrics.maximumBottomHeight > 0)
        #expect(metrics.maximumBottomHeight < size.height)
      }
    }
  }

  @Test func wideDetailUsesReadableSidePanelAndLeavesMapSpace() throws {
    let size = CGSize(width: 1000, height: 700)
    for accessibility in [false, true] {
      let metrics = DemoMapLayoutMetrics(
        size: size, accessibility: accessibility, expanded: true)
      let sideWidth = try #require(metrics.sideWidth)
      #expect((320...380).contains(sideWidth))
      #expect(size.width - sideWidth >= 400)
    }
  }

  @Test func shallowWindowKeepsControlsBelowTheMap() {
    for accessibility in [false, true] {
      let metrics = DemoMapLayoutMetrics(
        size: CGSize(width: 1000, height: 300), accessibility: accessibility, expanded: true)
      #expect(metrics.sideWidth == nil)
      #expect(metrics.maximumBottomHeight > 0)
      #expect(metrics.maximumBottomHeight < 300)
    }
  }

  @Test func accessibilityPanelRequires380PointsPlus400PointsForTheMap() throws {
    let narrow = DemoMapLayoutMetrics(
      size: CGSize(width: 779, height: 700), accessibility: true, expanded: true)
    #expect(narrow.sideWidth == nil)

    let fitting = DemoMapLayoutMetrics(
      size: CGSize(width: 780, height: 700), accessibility: true, expanded: true)
    let sideWidth = try #require(fitting.sideWidth)
    #expect(sideWidth == 380)
    #expect(780 - sideWidth >= 400)
  }

  @Test func idleControlsNeverReserveASidePanel() {
    for size in [CGSize(width: 1000, height: 700), CGSize(width: 1600, height: 1000)] {
      for accessibility in [false, true] {
        let metrics = DemoMapLayoutMetrics(
          size: size, accessibility: accessibility, expanded: false)
        #expect(metrics.sideWidth == nil)
        #expect(metrics.maximumBottomHeight.isFinite)
        #expect(metrics.maximumBottomHeight >= 0)
      }
    }
  }

  @Test func invalidGeometryProducesFiniteNonnegativeBottomHeight() {
    let sizes = [
      CGSize.zero,
      CGSize(width: 0, height: 700),
      CGSize(width: 1000, height: 0),
      CGSize(width: -1000, height: 700),
      CGSize(width: 1000, height: -700),
      CGSize(width: CGFloat.nan, height: 700),
      CGSize(width: 1000, height: CGFloat.nan),
      CGSize(width: CGFloat.infinity, height: 700),
      CGSize(width: 1000, height: CGFloat.infinity),
      CGSize(width: -CGFloat.infinity, height: -CGFloat.infinity),
    ]
    for size in sizes {
      for accessibility in [false, true] {
        for expanded in [false, true] {
          let metrics = DemoMapLayoutMetrics(
            size: size, accessibility: accessibility, expanded: expanded)
          #expect(metrics.sideWidth == nil)
          #expect(metrics.maximumBottomHeight.isFinite)
          #expect(metrics.maximumBottomHeight >= 0)
        }
      }
    }
  }

  @Test func resizingChoosesBottomThenSideThenBottomDeterministically() {
    let sizes = [
      CGSize(width: 466, height: 678),
      CGSize(width: 1000, height: 700),
      CGSize(width: 600, height: 700),
    ]
    for accessibility in [false, true] {
      let firstPass = sizes.map {
        DemoMapLayoutMetrics(size: $0, accessibility: accessibility, expanded: true)
      }
      #expect(firstPass.map { $0.sideWidth != nil } == [false, true, false])
      for (size, previous) in zip(sizes, firstPass) {
        let repeated = DemoMapLayoutMetrics(
          size: size, accessibility: accessibility, expanded: true)
        #expect(repeated.sideWidth == previous.sideWidth)
        #expect(repeated.maximumBottomHeight == previous.maximumBottomHeight)
      }
    }
  }
}
