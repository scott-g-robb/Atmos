import CoreGraphics

/// Short-lived metadata only. Window positions never go through this cache.
struct WindowMetadataCache<Value> {
  private struct Entry { var time: Double; var value: Value? }
  private var entries: [CGWindowID: Entry] = [:]
  var lifetime: Double = 0.08
  mutating func value(for window: CGWindowID, now: Double, fetch: () -> Value?) -> Value? {
    if let entry = entries[window], now >= entry.time, now - entry.time < lifetime { return entry.value }
    let value = fetch()
    if entries.count >= 512 { entries = entries.filter { now - $0.value.time < lifetime } }
    if entries.count >= 512 { entries.removeAll(keepingCapacity: true) }
    entries[window] = Entry(time: now, value: value)
    return value
  }
  mutating func invalidate() { entries.removeAll(keepingCapacity: true) }
}
