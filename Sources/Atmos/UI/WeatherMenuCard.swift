import AppKit

/// A compact native menu summary with semantic colours, real type hierarchy and VoiceOver text.
final class WeatherMenuCard: NSView {
  private let location = NSTextField(labelWithString: "Local Weather")
  private let temperature = NSTextField(labelWithString: "—")
  private let condition = NSTextField(
    labelWithString: "Choose Live Weather to follow your location")
  private let icon = NSImageView()
  private let metrics = NSTextField(wrappingLabelWithString: "")
  private let layers = NSTextField(wrappingLabelWithString: "")
  private let updated = NSTextField(labelWithString: "")
  private let alerts = NSStackView()

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 306, height: 216))
    location.font = .systemFont(ofSize: 13, weight: .semibold)
    temperature.font = .systemFont(ofSize: 36, weight: .light)
    temperature.setContentHuggingPriority(.required, for: .horizontal)
    condition.font = .systemFont(ofSize: 13)
    condition.maximumNumberOfLines = 2
    condition.lineBreakMode = .byWordWrapping
    metrics.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    layers.font = .systemFont(ofSize: 12, weight: .medium)
    updated.font = .systemFont(ofSize: 11)
    updated.textColor = .secondaryLabelColor
    for label in [location, temperature, condition, metrics, layers] {
      label.textColor = .labelColor
    }
    let headline = NSStackView(views: [temperature, icon])
    headline.orientation = .horizontal
    headline.alignment = .centerY
    headline.spacing = 14
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.contentTintColor = .controlAccentColor
    icon.widthAnchor.constraint(equalToConstant: 42).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 42).isActive = true
    alerts.orientation = .vertical
    alerts.alignment = .leading
    alerts.spacing = 5
    alerts.isHidden = true
    let stack = NSStackView(views: [location, alerts, headline, condition, metrics, layers, updated])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
      condition.widthAnchor.constraint(equalTo: stack.widthAnchor),
      metrics.widthAnchor.constraint(equalTo: stack.widthAnchor),
      layers.widthAnchor.constraint(equalTo: stack.widthAnchor),
      alerts.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
  }
  required init?(coder: NSCoder) { nil }

  func update(weather: LiveWeather) {
    update(
      reading: weather.current, place: weather.locationName, detail: weather.locationDetail,
      status: weather.status, live: weather.enabled)
  }

  func update(
    reading: WeatherSnapshot?, place: String, detail: String, status: String, live: Bool = false
  ) {
    location.stringValue = place
    location.toolTip = detail
    for view in alerts.arrangedSubviews { alerts.removeArrangedSubview(view); view.removeFromSuperview() }
    let now = Date()
    if let reading {
      for alert in reading.visibleAlerts(at: now) {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.maximumNumberOfLines = 0
        // Keep the agency's complete wording, with an embedded details link.
        let text = NSMutableAttributedString(string: alert.summary + "\n" + alert.source,
          attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor, .link: alert.detailsURL])
        field.attributedStringValue = text
        field.toolTip = alert.detailsURL.absoluteString
        alerts.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: alerts.widthAnchor).isActive = true
        if now < alert.starts {
          let start = DateFormatter.localizedString(from: alert.starts, dateStyle: .short, timeStyle: .short)
          let timing = NSTextField(wrappingLabelWithString: "Starts \(start)")
          timing.font = .systemFont(ofSize: 11); timing.textColor = .secondaryLabelColor
          alerts.addArrangedSubview(timing)
        } else if !alert.isActive(at: now) {
          let timing = NSTextField(labelWithString: "Event ended · Warning still reported")
          timing.font = .systemFont(ofSize: 11); timing.textColor = .secondaryLabelColor
          alerts.addArrangedSubview(timing)
        }
      }
      if !reading.alertsAvailable {
        let label = NSTextField(wrappingLabelWithString: "Weather warnings unavailable")
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        alerts.addArrangedSubview(label)
      }
    }
    alerts.isHidden = alerts.arrangedSubviews.isEmpty
    if let reading {
      temperature.stringValue = "\(Int(reading.temperature.rounded()))°"
      condition.stringValue =
        reading.condition.prefix(1).uppercased() + reading.condition.dropFirst()
      icon.image = NSImage(
        systemSymbolName: reading.effect.symbol, accessibilityDescription: reading.condition)
      let direction = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][
        Int((reading.windDirection / 45).rounded()) % 8]
      let feels =
        reading.apparentTemperature.map { "Feels like \(Int($0.rounded()))°" }
        ?? "\(reading.isDay == 1 ? "Daytime" : "Nighttime")"
      metrics.stringValue =
        "\(feels)     Wind \(Int(reading.windSpeed.rounded())) km/h \(direction)\nCloud \(Int((reading.cloudCover ?? 0).rounded()))%     Rain \(String(format: "%.1f", reading.precipitationRate)) mm/h"
        + (reading.humidity.map { "     Humidity \(Int($0.rounded()))%" } ?? "")
      layers.stringValue = WeatherScene(weather: reading).summary
      let time = DateFormatter.localizedString(
        from: Date(timeIntervalSince1970: reading.time), dateStyle: .none, timeStyle: .short)
      updated.stringValue = "Observed \(time) · \(reading.isDay == 1 ? "Day" : "Night")"
    } else {
      temperature.stringValue = "—"
      condition.stringValue = status
      icon.image = NSImage(systemSymbolName: "location", accessibilityDescription: nil)
      metrics.stringValue =
        status.hasPrefix("Apple Weather")
        ? "Choose Automatic or Open-Meteo to keep following the weather."
        : "Effects follow your location while Live Weather is on."
      layers.stringValue =
        live
        ? "Waiting for local weather · No temporary scene"
        : "Manual scene · \(Preferences.manualScene.summary)"
      updated.stringValue = "Updates automatically"
    }
    layoutSubtreeIfNeeded()
    setFrameSize(NSSize(width: 306, height: max(190, subviews[0].fittingSize.height + 24)))
  }
}
