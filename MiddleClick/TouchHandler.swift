import MoreTouchCore
import MultitouchSupport

@MainActor class TouchHandler {
  static let shared = TouchHandler()
  private static let config = Config.shared
  private init() {
    Self.config.$tapToClick.onSet {
      self.tapToClick = $0
    }
    Self.config.$minimumFingers.onSet {
      Self.fingersQua = $0
    }
  }

  /// stored locally, since accessing the cache is more CPU-expensive than a local variable
  private var tapToClick = config.tapToClick

  private static var fingersQua = config.minimumFingers
  private static let allowMoreFingers = config.allowMoreFingers
  private static let maxDistanceDelta = config.maxDistanceDelta
  private static let maxTimeDelta = config.maxTimeDelta
  // Fingertips are ~7–9mm; palm contacts are ~20–25mm. 15 splits them cleanly.
  // nonisolated so it is safe to read from the multitouch background thread.
  nonisolated(unsafe) private static let palmMajorAxisThreshold: Float = 15.0

  private var maybeMiddleClick = false
  private var touchStartTime: Date?
  private static var lastEmulatedMiddleClickTime: Date?
  private var middleClickPos1: SIMD2<Float> = .zero
  private var middleClickPos2: SIMD2<Float> = .zero

  private let touchCallback: MTFrameCallbackFunction = {
    _, data, nFingers, _, _ in
    guard !AppUtils.isIgnoredAppBundle() else { return }

    let state = GlobalState.shared

    // Count only active fingertip contacts, excluding palms (large majorAxis)
    // and lifting contacts (majorAxis == 0.0).
    let effectiveFingers = TouchHandler.countNonPalmTouches(data: data, nFingers: nFingers)

    // Only clear threeDown when all real fingers lift (effectiveFingers == 0).
    // Keeping it set while fingers are partially lifting prevents spurious
    // 2-finger right-clicks from slipping through the mouse event tap.
    if effectiveFingers == 0 {
      state.threeDown = false
    } else if allowMoreFingers ? effectiveFingers >= fingersQua : effectiveFingers == fingersQua {
      state.threeDown = true
    }

    let handler = TouchHandler.shared

    guard handler.tapToClick else { return }

    guard effectiveFingers != 0 else {
      handler.handleTouchEnd()
      return
    }

    guard !(effectiveFingers < fingersQua) else {
      // Real finger count dropped below threshold while palm remains on pad.
      // Trigger touch end so the middle click fires without waiting for the
      // palm to lift (which may never happen during normal use).
      if handler.touchStartTime != nil { handler.handleTouchEnd() }
      return
    }

    if !allowMoreFingers && effectiveFingers > fingersQua {
      handler.resetMiddleClick()
    }

    let isCurrentFingersQuaAllowed = allowMoreFingers ? effectiveFingers >= fingersQua : effectiveFingers == fingersQua
    guard isCurrentFingersQuaAllowed else { return }

    // Start the timer only once qualifying fingers are present, so a resting
    // palm that arrives before the tap doesn't consume the timeout budget.
    // Skip processTouches on the first frame: a borderline palm contact may
    // still be below the threshold and would corrupt the position baseline.
    let isTouchStart = handler.touchStartTime == nil
    if isTouchStart {
      handler.touchStartTime = Date()
      handler.maybeMiddleClick = true
      handler.middleClickPos1 = .zero
      return
    }

    if handler.maybeMiddleClick, let touchStartTime = handler.touchStartTime {
      let elapsedTime = -touchStartTime.timeIntervalSinceNow
      if elapsedTime > maxTimeDelta {
        handler.maybeMiddleClick = false
      }
    }

    // Don't update positions once any contact starts lifting (majorAxis == 0.0).
    // A lifting contact can be substituted by a different finger in processTouches,
    // corrupting pos2 and producing a spurious large delta.
    guard !TouchHandler.hasLiftingContact(data: data, nFingers: nFingers) else { return }

    handler.processTouches(data: data, nFingers: nFingers)

    return
  }

  nonisolated private static func hasLiftingContact(data: UnsafePointer<MTTouch>?, nFingers: Int32) -> Bool {
    guard nFingers > 0, let data = data else { return false }
    for i in 0..<Int(nFingers) where data[i].majorAxis == 0.0 { return true }
    return false
  }

  nonisolated private static func countNonPalmTouches(data: UnsafePointer<MTTouch>?, nFingers: Int32) -> Int32 {
    guard nFingers > 0, let data = data else { return 0 }
    var count: Int32 = 0
    for i in 0..<Int(nFingers) {
      let maj = data[i].majorAxis
      if maj > 0 && maj < palmMajorAxisThreshold { count += 1 }
    }
    return count
  }

  private func processTouches(data: UnsafePointer<MTTouch>?, nFingers: Int32) {
    guard let data = data else { return }

    if maybeMiddleClick {
      middleClickPos1 = .zero
    } else {
      middleClickPos2 = .zero
    }

    var kept = 0
    for i in 0..<Int(nFingers) {
      guard kept < Self.fingersQua else { break }
      let maj = data[i].majorAxis
      guard maj > 0 && maj < Self.palmMajorAxisThreshold else { continue }
      let pos = SIMD2(data[i].normalizedVector.position)
      if maybeMiddleClick {
        middleClickPos1 += pos
      } else {
        middleClickPos2 += pos
      }
      kept += 1
    }

    if maybeMiddleClick {
      middleClickPos2 = middleClickPos1
      maybeMiddleClick = false
    }
  }

  private func resetMiddleClick() {
    maybeMiddleClick = false
    middleClickPos1 = .zero
  }

  private func handleTouchEnd() {
    guard let startTime = touchStartTime else { return }

    let elapsedTime = -startTime.timeIntervalSinceNow
    touchStartTime = nil

    guard middleClickPos1.isNonZero && elapsedTime <= Self.maxTimeDelta else { return }

    let delta = middleClickPos1.delta(to: middleClickPos2)
    if delta < Self.maxDistanceDelta && !shouldPreventEmulation() {
      Self.emulateMiddleClick()
    }
  }

  private static func emulateMiddleClick() {
    if let lastTime = lastEmulatedMiddleClickTime,
       -lastTime.timeIntervalSinceNow < maxTimeDelta * 0.3 {
      return
    }
    lastEmulatedMiddleClickTime = .init()
    GlobalState.shared.lastEmulatedClickTime = .init()

    // get the current pointer location
    let location = CGEvent(source: nil)?.location ?? .zero
    let buttonType: CGMouseButton = .center

    postMouseEvent(type: .otherMouseDown, button: buttonType, location: location)
    postMouseEvent(type: .otherMouseUp, button: buttonType, location: location)
  }

  private func shouldPreventEmulation() -> Bool {
    guard let naturalLastTime = GlobalState.shared.naturalMiddleClickLastTime else { return false }

    let elapsedTimeSinceNatural = -naturalLastTime.timeIntervalSinceNow
    return elapsedTimeSinceNatural <= Self.maxTimeDelta * 0.75 // fine-tuned multiplier
  }

  private static func postMouseEvent(
    type: CGEventType, button: CGMouseButton, location: CGPoint
  ) {
    CGEvent(
      mouseEventSource: nil, mouseType: type, mouseCursorPosition: location,
      mouseButton: button
    )?.post(tap: .cghidEventTap)
  }

  private var currentDeviceList: [MTDevice] = []
  func registerTouchCallback() {
    currentDeviceList = MTDevice.createList()
    currentDeviceList.forEach { $0.registerAndStart(touchCallback) }
  }
  func unregisterTouchCallback() {
    currentDeviceList.forEach { $0.unregisterAndStop(touchCallback) }
    currentDeviceList.removeAll()
  }
}

extension SIMD2 where Scalar == Float {
  init(_ point: MTPoint) { self.init(point.x, point.y) }
}
extension SIMD2 where Scalar: FloatingPoint {
  func delta(to other: SIMD2) -> Scalar {
    return abs(x - other.x) + abs(y - other.y)
  }

  var isNonZero: Bool { x != 0 || y != 0 }
}
