import Foundation

enum LocationPresentation {
  static func name(district: String?, city: String?, region: String?, country: String?) -> String? {
    var parts: [String] = []
    // With a neighbourhood and city, a wider administrative region adds little useful precision.
    let candidates = district == nil ? [city, region, country] : [district, city, country]
    for candidate in candidates {
      guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
        !candidate.isEmpty,
        !parts.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame })
      else { continue }
      parts.append(candidate)
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }
}
