/// Capture is driven by actual visible consumers, including outgoing wet/foggy scenes.
struct DesktopCaptureDemand {
  let live: Bool
  let snapshots: Bool
  let bloom: Bool
  init(water: Bool, fog: Bool, reflectionsEnabled: Bool, liveReflections: Bool, bloomEnabled: Bool) {
    bloom = fog && bloomEnabled
    snapshots = water && reflectionsEnabled && !liveReflections
    live = bloom || (water && reflectionsEnabled && liveReflections)
  }
}
