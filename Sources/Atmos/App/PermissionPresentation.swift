import CoreLocation

/// Permission and current use are separate: a grant alone never means capture is running.
struct PermissionPresentation {
  let status: String
  let detail: String
  let granted: Bool

  static func screen(granted: Bool, enabled: Bool, active: Bool, stopped: Bool) -> Self {
    guard granted else {
      return Self(
        status: "Not granted",
        detail:
          "Allow this copy of Atmos in System Settings, then Recheck Screenshot Access. If macOS asks to relaunch, choose Restart Atmos. Wallpaper Only works without access.",
        granted: false)
    }
    let detail =
      !enabled
      ? "Off in Atmos · No desktop capture."
      : stopped
        ? "Stopped in macOS · Select a reflection source to resume."
        : active
          ? "Taking a screenshot · Images stay on this Mac; no video or audio."
          : "Cached screenshots · New images only for visible water or fog bloom."
    return Self(status: active ? "Granted · In use" : "Granted", detail: detail, granted: true)
  }

  static func location(status: CLAuthorizationStatus, enabled: Bool, locating: Bool, paused: Bool)
    -> Self
  {
    switch status {
    case .authorized, .authorizedAlways:
      return Self(
        status: locating ? "Granted · In use" : "Granted",
        detail: !enabled
          ? "Not in use · Live Weather is off."
          : paused
            ? "Paused while Atmos is hidden or asleep."
            : locating
              ? "Finding your approximate location."
              : "Idle · Live Weather reuses its last location between updates.", granted: true)
    case .notDetermined:
      return Self(
        status: "Not requested", detail: "Enable Live Weather to request location access.",
        granted: false)
    case .denied:
      return Self(
        status: "Not granted", detail: "Allow Atmos in Location Services to use Live Weather.",
        granted: false)
    case .restricted:
      return Self(
        status: "Restricted",
        detail: "Location access is restricted by macOS or your administrator.", granted: false)
    @unknown default:
      return Self(
        status: "Unavailable", detail: "Review Location Services in System Settings.",
        granted: false)
    }
  }
}
