import AppKit

final class WindSlider: NSView {
  var changed: ((Double) -> Void)?
  var speed: Double = 0 { didSet { show() } }
  var automatic = false { didSet { show() } }
  var awaitingWeather = false { didSet { show() } }
  private let slider = NSSlider()
  private let caption = NSTextField(labelWithString: "")
  init() {
    super.init(frame:NSRect(x:0,y:0,width:200,height:50))
    autoresizingMask = .width
    slider.minValue=0;slider.maxValue=100;slider.isContinuous=true
    slider.target=self;slider.action = #selector(slide)
    slider.setAccessibilityLabel("Wind speed")
    caption.font = .systemFont(ofSize:NSFont.smallSystemFontSize)
    caption.textColor = .secondaryLabelColor;caption.alignment = .center
    for view in [slider,caption] {view.translatesAutoresizingMaskIntoConstraints=false;addSubview(view)}
    NSLayoutConstraint.activate([
      slider.leadingAnchor.constraint(equalTo:leadingAnchor,constant:29),
      slider.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-15),
      slider.topAnchor.constraint(equalTo:topAnchor,constant:4),
      caption.centerXAnchor.constraint(equalTo:slider.centerXAnchor),
      caption.topAnchor.constraint(equalTo:slider.bottomAnchor,constant:2),
      caption.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-2)])
    setFrameSize(NSSize(width:frame.width,height:fittingSize.height));show()
  }
  required init?(coder:NSCoder) {nil}
  @objc private func slide() {
    guard !automatic else {return}
    speed=slider.doubleValue.rounded();changed?(speed)
  }
  private func show() {
    slider.doubleValue=max(0,min(100,speed));slider.isEnabled = !automatic
    let reading="\(Int(speed.rounded())) km/h"
    caption.stringValue=automatic ? (awaitingWeather ? "Auto · Waiting for weather":"Auto · \(reading)"):reading
    slider.setAccessibilityValueDescription(caption.stringValue)
  }
}
