import Foundation

/// Shared by the control rail and label collision detection, including the
/// horizontal arrangement used when the map is too shallow for a column.
struct OfflineMapControlsLayout {
  static let inset: CGFloat = 12
  static let separator: CGFloat = 1

  let buttonSize: CGFloat
  let isVertical: Bool
  let frame: CGRect

  init(mapSize: CGSize, buttonSize: CGFloat, hasLocation: Bool, hasRoute: Bool) {
    self.buttonSize = buttonSize
    let count = 2 + (hasLocation ? 1 : 0) + (hasRoute ? 1 : 0)
    let length = CGFloat(count) * buttonSize + CGFloat(count - 1) * Self.separator
    isVertical = mapSize.height >= length + 2 * Self.inset
    let size = isVertical
      ? CGSize(width: buttonSize, height: length)
      : CGSize(width: length, height: buttonSize)
    frame = CGRect(
      x: max(0, mapSize.width - Self.inset - size.width), y: Self.inset,
      width: size.width, height: size.height)
  }
}
