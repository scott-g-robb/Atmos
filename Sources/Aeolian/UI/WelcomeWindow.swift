import AppKit
import QuartzCore

struct SetupPermission {
  enum Kind: CaseIterable { case location, screen, login, automaticUpdates }
  let kind: Kind
  let title: String
  let detail: String
  let symbol: String
  let action: String
  let granted: Bool
}

/// A versioned, optional introduction. System permission dialogs always remain
/// in macOS's control; the guide completes only when the actual status menu opens.
final class WelcomeController: NSObject {
  private let introAudio = WelcomeAudio()
  var appIcon: NSImage?
  var permissions: () -> [SetupPermission] = { [] }
  var requestPermission: (SetupPermission.Kind) -> Void = { _ in }
  var menuAnchor: () -> CGRect? = { nil }
  var finished: (SetupProgress.Completion) -> Void = { _ in }
  var prepareWeather: () -> Void = {}
  private(set) var progress = SetupProgress()
  private var window: SetupWindow?
  private var guide: NSWindow?
  private var permissionTimer: Timer?
  private var anchorTimer: Timer?
  private var observer: NSObjectProtocol?
  private var permissionStates: [Bool] = []
  private var awaitingPermission: SetupPermission.Kind?
  private var transitioning = false
  private var completed = false
  private var calm: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  deinit {
    permissionTimer?.invalidate(); anchorTimer?.invalidate()
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func show() {
    let size = CGSize(width: 520, height: 530)
    let window = SetupWindow(contentRect: CGRect(origin: .zero, size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.identifier = AeolianPanelPresentation.identifier
    window.appearance = Preferences.interfaceAppearance.native
    window.level = Self.frontLevel
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.onCancel = { [weak self] in self?.skip() }
    window.contentView = makePage()
    window.center()
    self.window = window
    NSApp.activate(ignoringOtherApps: true)
    let introStart = introAudio.play()
    if let page = window.contentView as? SetupPageView { page.prepareEntrance(calm: calm, startTime: introStart) }
    window.makeKeyAndOrderFront(nil)
    observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
      object: nil, queue: .main) { [weak self] _ in
        guard let self, progress.page == .permissions else { return }
        refreshPermissions()
        window.level = Self.frontLevel
        window.orderFrontRegardless()
      }
  }

  /// Called only for the root status menu, not when a settings submenu opens.
  func menuOpened() {
    guard progress.page == .menuBar else { return }
    progress.openedMenu()
    anchorTimer?.invalidate(); anchorTimer = nil
    let guide = self.guide
    self.guide = nil
    finish()
    animate(duration: 0.22, changes: { guide?.animator().alphaValue = 0 }) {
      guide?.orderOut(nil)
    }
  }

  private static let frontLevel = AeolianPanelPresentation.level

  @objc private func next() {
    guard !transitioning else { return }
    (window?.contentView as? SetupPageView)?.finishEntrance()
    progress.next()
    if progress.page == .customisation { prepareWeather() }
    if progress.page == .menuBar { revealMenuBar() }
    else { changePage(forward: true) }
  }
  @objc private func back() {
    guard !transitioning else { return }
    progress.back(); changePage(forward: false)
  }
  @objc private func skip() {
    guard !transitioning else { return }
    (window?.contentView as? SetupPageView)?.finishEntrance()
    transitioning = true
    progress.skip()
    animate(duration: 0.22, changes: { self.window?.animator().alphaValue = 0 }) { [weak self] in self?.finish() }
  }

  private func makePage() -> SetupPageView {
    let view = SetupPageView(frame: CGRect(x: 0, y: 0, width: 520, height: progress.page == .welcome ? 530 : 630),
      page: progress.page, permissions: permissions(), icon: appIcon)
    view.next.target = self; view.next.action = #selector(next)
    view.previous.target = self
    view.previous.action = progress.page == .welcome ? #selector(skip) : #selector(back)
    for (kind, button) in view.permissionButtons {
      button.target = self; button.action = #selector(request(_:))
      button.tag = SetupPermission.Kind.allCases.firstIndex(of: kind)!
    }
    permissionStates = permissions().map(\.granted)
    return view
  }

  private func changePage(forward: Bool) {
    guard let window, let old = window.contentView else { return }
    window.level = Self.frontLevel
    transitioning = true
    permissionTimer?.invalidate(); permissionTimer = nil
    let page = makePage()
    let newFrame = CGRect(x: window.frame.midX-page.frame.width/2, y: window.frame.midY-page.frame.height/2,
      width: page.frame.width, height: page.frame.height)
    let container = NSView(frame: old.bounds)
    container.autoresizingMask = [.width, .height]
    let surface = AeolianPanelSurface(frame: container.bounds, welcome: false)
    surface.autoresizingMask = [.width, .height]
    container.addSubview(surface)
    window.contentView = container
    old.frame = container.bounds
    old.autoresizingMask = [.width, .height]
    page.frame = container.bounds
    page.autoresizingMask = [.width, .height]
    page.alphaValue = 0
    container.addSubview(old); container.addSubview(page)
    old.layoutSubtreeIfNeeded(); page.layoutSubtreeIfNeeded()
    animate(duration: 0.25, changes: {
      window.animator().setFrame(newFrame, display: true)
      old.animator().alphaValue = 0
      page.animator().alphaValue = 1
    }) { [weak self] in
      guard let self else { return }
      page.removeFromSuperview(); page.frame = CGRect(origin: .zero, size: newFrame.size)
      window.contentView = page
      page.layoutSubtreeIfNeeded()
      transitioning = false
      if progress.page == .permissions {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
      }
    }
  }

  @objc private func request(_ button: NSButton) {
    guard let kind = SetupPermission.Kind.allCases[safe: button.tag] else { return }
    awaitingPermission = kind
    // Let the system's authorization prompt or System Settings come forward.
    window?.level = .normal
    requestPermission(kind)
    refreshPermissions()
  }

  private func refreshPermissions() {
    guard progress.page == .permissions, let view = window?.contentView as? SetupPageView else { return }
    let current = permissions()
    let states = current.map(\.granted)
    view.update(current)
    if states != permissionStates, let awaitingPermission,
      current.contains(where: { $0.kind == awaitingPermission && $0.granted }) {
      self.awaitingPermission = nil
      window?.level = Self.frontLevel
      NSApp.activate(ignoringOtherApps: true)
      window?.makeKeyAndOrderFront(nil)
    }
    permissionStates = states
  }

  private func revealMenuBar() {
    guard let window else { return }
    transitioning = true
    permissionTimer?.invalidate(); permissionTimer = nil
    let frame = window.frame
    let top = window.screen?.frame.maxY ?? NSScreen.main?.frame.maxY ?? frame.maxY
    animate(duration: 0.35, changes: {
      window.animator().alphaValue = 0
      if !self.calm { window.animator().setFrameOrigin(CGPoint(x: frame.minX, y: top + 16)) }
    }) { [weak self] in
      guard let self else { return }
      window.orderOut(nil); self.window = nil; transitioning = false
      showGuide()
    }
  }

  private func showGuide() {
    guard progress.page == .menuBar else { return }
    let guide = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 210, height: 105),
      styleMask: .borderless, backing: .buffered, defer: false)
    guide.isOpaque = false; guide.backgroundColor = .clear
    guide.hasShadow = false; guide.ignoresMouseEvents = true
    guide.identifier = AeolianPanelPresentation.identifier
    guide.level = Self.frontLevel
    guide.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    guide.isReleasedWhenClosed = false
    guide.contentView = MenuBarGuideView(frame: CGRect(x: 0, y: 0, width: 210, height: 105))
    self.guide = guide
    placeGuide()
    guide.alphaValue = 0; guide.orderFrontRegardless()
    animate(duration: 0.3) { guide.animator().alphaValue = 1 }
    if !calm, let layer = guide.contentView?.layer {
      let float = CABasicAnimation(keyPath: "transform.translation.y")
      float.fromValue = -2; float.toValue = 2; float.duration = 1.3
      float.autoreverses = true; float.repeatCount = .infinity
      float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer.add(float, forKey: "gentleGuide")
    }
    let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.placeGuide() }
    timer.tolerance = 0.04
    RunLoop.main.add(timer, forMode: .common)
    anchorTimer = timer
  }

  private func placeGuide() {
    guard let guide, let anchor = menuAnchor() else { guide?.orderOut(nil); return }
    let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }
    let bounds = screen?.frame ?? anchor.insetBy(dx: -200, dy: -200)
    let x = min(bounds.maxX - 214, max(bounds.minX + 4, anchor.midX - 105))
    let y = min(anchor.minY - 109, bounds.maxY - 135)
    let origin = CGPoint(x: x, y: y)
    if guide.frame.origin != origin { guide.setFrameOrigin(origin) }
    (guide.contentView as? MenuBarGuideView)?.arrowX = anchor.midX - x
    if !guide.isVisible { guide.orderFrontRegardless() }
  }

  private func finish() {
    guard !completed else { return }
    completed = true
    introAudio.stop()
    permissionTimer?.invalidate(); anchorTimer?.invalidate()
    permissionTimer = nil; anchorTimer = nil
    window?.orderOut(nil); window = nil
    guide?.orderOut(nil); guide = nil
    if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
    if let completion = progress.completion { finished(completion) }
  }

  private func animate(duration: Double, changes: @escaping () -> Void, completion: @escaping () -> Void = {}) {
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = calm ? min(0.15, duration) : duration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      changes()
    }, completionHandler: completion)
  }
}

private final class SetupWindow: NSWindow {
  var onCancel: () -> Void = {}
  override var canBecomeKey: Bool { true }
  override func cancelOperation(_ sender: Any?) { onCancel() }
  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown { level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1) }
    super.sendEvent(event)
  }
}

/// Native controls, generous spacing and a single rounded material surface.
final class SetupPageView: NSView {
  let next: NSButton = AeolianPrimaryButton()
  let previous: NSButton
  private(set) var permissionButtons: [(SetupPermission.Kind, NSButton)] = []
  private var permissionRows: [SetupPermission.Kind: SetupPermissionRow] = [:]

  init(frame: CGRect, page: SetupProgress.Page, permissions: [SetupPermission], icon: NSImage? = nil) {
    previous = NSButton(title: page == .welcome ? "Skip setup" : "Back", target: nil, action: nil)
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 28
    layer?.masksToBounds = true
    let surface = AeolianPanelSurface(frame: bounds, welcome: page == .welcome)
    surface.autoresizingMask = [.width, .height]
    addSubview(surface)

    let content = NSStackView()
    content.orientation = .vertical; content.alignment = .centerX
    content.spacing = 14
    content.translatesAutoresizingMaskIntoConstraints = false
    if page == .welcome {
      // Test runners and SwiftPM are not application bundles: never borrow their
      // generic folder/executable icon as Atmos's identity.
      let artwork = icon ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) } ?? Bundle.main.image(forResource: "AppIcon")
        ?? NSImage(systemSymbolName: "cloud.sun.fill", accessibilityDescription: "Aeolian")!
      let icon = AeolianArtworkView(image: artwork)
      icon.setAccessibilityLabel("Aeolian app icon")
      icon.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 116),icon.heightAnchor.constraint(equalToConstant: 116)])
      content.addArrangedSubview(icon)
      let thanks = label("Thank you for downloading", size: 12, color: .secondaryLabelColor)
      thanks.attributedStringValue = NSAttributedString(string: thanks.stringValue, attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
        .kern: 0.4, .paragraphStyle: Self.centered])
      let title = label("Aeolian", size: 46, weight: .medium)
      let tagline = label("A little atmosphere on your desktop.", size: 15, color: .secondaryLabelColor)
      content.addArrangedSubview(thanks); content.addArrangedSubview(title); content.addArrangedSubview(tagline)
      content.setCustomSpacing(25, after: icon)
      content.setCustomSpacing(6, after: thanks)
      content.setCustomSpacing(9, after: title)
    } else if page == .customisation {
      content.addArrangedSubview(label("Make it yours.", size: 27, weight: .medium))
      content.addArrangedSubview(label("A few personal touches.\nChange these anytime in Settings.", size: 13, color: .secondaryLabelColor))
      let choices=QuickCustomisationView(frame:.zero)
      choices.translatesAutoresizingMaskIntoConstraints=false
      content.addArrangedSubview(choices)
      choices.widthAnchor.constraint(equalToConstant:440).isActive=true
      content.setCustomSpacing(24,after:content.arrangedSubviews[1])
    } else {
      content.addArrangedSubview(label("Make yourself at home.", size: 27, weight: .medium))
      content.addArrangedSubview(label("A few permissions for the full Aeolian experience.\nYou can change these later in Settings.", size: 13, color: .secondaryLabelColor))
      let rows = NSStackView(); rows.orientation = .vertical; rows.spacing = 10; rows.alignment = .leading
      rows.translatesAutoresizingMaskIntoConstraints = false
      for permission in permissions {
        let row = SetupPermissionRow(permission)
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        permissionRows[permission.kind] = row
        permissionButtons.append((permission.kind, row.button))
      }
      content.addArrangedSubview(rows)
      rows.widthAnchor.constraint(equalToConstant: 440).isActive = true
      content.setCustomSpacing(24, after: content.arrangedSubviews[1])
    }
    addSubview(content)
    NSLayoutConstraint.activate([
      content.centerXAnchor.constraint(equalTo: centerXAnchor),
      content.centerYAnchor.constraint(equalTo: centerYAnchor, constant: page == .welcome ? -22 : -12),
      content.widthAnchor.constraint(equalTo: widthAnchor, constant: -80),
    ])
    next.keyEquivalent = "\r"
    next.translatesAutoresizingMaskIntoConstraints = false
    previous.isBordered = false; previous.contentTintColor = .secondaryLabelColor
    previous.translatesAutoresizingMaskIntoConstraints = false
    addSubview(previous); addSubview(next)
    let steps = SetupStepsView(frame: .zero)
    steps.step = page == .welcome ? 0 : page == .permissions ? 1 : 2
    steps.translatesAutoresizingMaskIntoConstraints = false
    addSubview(steps)
    NSLayoutConstraint.activate([
      previous.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
      previous.centerYAnchor.constraint(equalTo: next.centerYAnchor),
      next.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -34),
      next.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
      next.widthAnchor.constraint(equalToConstant: 96), next.heightAnchor.constraint(equalToConstant: 36),
      steps.centerXAnchor.constraint(equalTo: centerXAnchor), steps.centerYAnchor.constraint(equalTo: next.centerYAnchor),
      steps.widthAnchor.constraint(equalToConstant: 42), steps.heightAnchor.constraint(equalToConstant: 8),
    ])
    setAccessibilityLabel(page == .welcome ? "Welcome to Aeolian" : page == .permissions ? "Aeolian permissions" : "Aeolian customisation")
  }
  required init?(coder: NSCoder) { nil }
  private static var centered: NSParagraphStyle {
    let style = NSMutableParagraphStyle(); style.alignment = .center; return style
  }
  override var mouseDownCanMoveWindow: Bool { true }
  func update(_ permissions: [SetupPermission]) {
    for permission in permissions { permissionRows[permission.kind]?.update(permission) }
  }
  func prepareEntrance(calm: Bool, startTime: CFTimeInterval = CACurrentMediaTime()) {
    guard let layer else { return }
    if calm {
      let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.35
      fade.beginTime = layer.convertTime(startTime, from: nil); fade.fillMode = .backwards
      layer.add(fade, forKey: "accessibleEntrance"); return
    }
    layoutSubtreeIfNeeded()
    func artwork(in view: NSView) -> NSView? {
      for child in view.subviews { if child is AeolianArtworkView { return child }; if let found = artwork(in: child) { return found } }
      return nil
    }
    let seed = artwork(in: self).map { convert($0.bounds, from: $0).insetBy(dx: -12, dy: -12) }
      ?? CGRect(x: bounds.midX-70, y: bounds.midY-70, width: 140, height: 140)
    let mask = CAShapeLayer(); mask.frame = bounds
    let final = CGPath(roundedRect: bounds, cornerWidth: 28, cornerHeight: 28, transform: nil)
    mask.path = final; mask.fillColor = NSColor.white.cgColor; layer.mask = mask
    let unfold = CABasicAnimation(keyPath: "path")
    unfold.fromValue = CGPath(roundedRect: seed, cornerWidth: 32, cornerHeight: 32, transform: nil)
    // The supplied 6.32-second clip swells to its crest around 2.5 seconds.
    // Let the surface form with that swell, then settle into its quiet tail.
    unfold.toValue = final; unfold.duration = 2.6
    unfold.beginTime = mask.convertTime(startTime+0.15, from: nil); unfold.fillMode = .backwards
    unfold.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.25, 1)
    let settle = AeolianPanelPresentation.settle(layer: layer, scales: [0.985, 1], keyTimes: [0, 1], duration: 3.4)
    settle.beginTime = layer.convertTime(startTime, from: nil); settle.fillMode = .backwards
    let arrival = CABasicAnimation(keyPath: "opacity")
    arrival.fromValue = 0; arrival.toValue = 1; arrival.duration = 0.9
    arrival.beginTime = layer.convertTime(startTime, from: nil); arrival.fillMode = .backwards
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak layer] in layer?.mask = nil }
    mask.add(unfold, forKey: "formingAtmosphere"); layer.add(settle, forKey: "settlingAtmosphere")
    layer.add(arrival, forKey: "arrivingAtmosphere")
    CATransaction.commit()
    // Text resolves through the musical rise; both controls arrive together.
    var index = 0
    func reveal(_ view: NSView) {
      if view is NSTextField || view === next || view === previous {
        view.wantsLayer = true
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = -4; move.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        let group = CAAnimationGroup(); group.animations = [move, fade]
        let control = view === next || view === previous
        let offset = control ? 2.5 : 0.95 + Double(min(index, 2))*0.4
        group.beginTime = view.layer?.convertTime(startTime+offset, from: nil) ?? startTime+offset
        group.duration = control ? 0.85 : 1.05
        group.fillMode = .backwards; group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer?.add(group, forKey: "settlingContent"); index += 1
      } else { for child in view.subviews { reveal(child) } }
    }
    for child in subviews where !(child is AeolianPanelSurface) { reveal(child) }
  }
  func finishEntrance() {
    layer?.mask = nil
    for key in ["settlingAtmosphere", "arrivingAtmosphere", "accessibleEntrance"] { layer?.removeAnimation(forKey: key) }
    func finish(_ view: NSView) {
      view.layer?.removeAnimation(forKey: "settlingContent")
      view.subviews.forEach(finish)
    }
    subviews.forEach(finish)
  }
  private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
    color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color; label.alignment = .center
    label.preferredMaxLayoutWidth = 440
    label.translatesAutoresizingMaskIntoConstraints = false
    label.widthAnchor.constraint(equalToConstant: 440).isActive = true
    return label
  }
}

class AeolianPanelSurface: NSView {
  let welcome: Bool
  let divider: Bool
  init(frame: CGRect, welcome: Bool, divider: Bool = true) {
    self.welcome = welcome; self.divider = divider; super.init(frame: frame)
  }
  required init?(coder: NSCoder) { nil }
  var surfacePath: NSBezierPath {
    NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 28, yRadius: 28)
  }
  override func draw(_ dirtyRect: NSRect) {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let shape = surfacePath
    let upper = dark ? NSColor(srgbRed: 0.13, green: 0.15, blue: 0.18, alpha: 1)
      : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1)
    let lower = dark ? NSColor(srgbRed: 0.085, green: 0.10, blue: 0.125, alpha: 1)
      : NSColor(srgbRed: 0.95, green: 0.965, blue: 0.985, alpha: 1)
    NSGradient(starting: lower, ending: upper)?.draw(in: shape, angle: 90)
    NSGraphicsContext.saveGraphicsState(); shape.addClip()
    let strength: CGFloat = welcome ? 1 : 0.4
    let blue = AeolianAppearance.accent.withAlphaComponent((dark ? 0.16 : 0.13) * strength)
    NSGradient(starting: blue, ending: blue.withAlphaComponent(0))?
      .draw(in: bounds, relativeCenterPosition: CGPoint(x: -0.72, y: 0.72))
    let sun = NSColor(srgbRed: 1, green: 0.76, blue: 0.43, alpha: (dark ? 0.10 : 0.13) * strength)
    NSGradient(starting: sun, ending: sun.withAlphaComponent(0))?
      .draw(in: bounds, relativeCenterPosition: CGPoint(x: 0.8, y: 0.85))
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(dark ? 0.09 : 0.8).setStroke()
    shape.lineWidth = 1; shape.stroke()
    if divider {
      let line = NSBezierPath();line.move(to: CGPoint(x: 34, y: 86));line.line(to: CGPoint(x: bounds.width-34, y: 86))
      NSColor.labelColor.withAlphaComponent(dark ? 0.07 : 0.055).setStroke();line.lineWidth = 0.5;line.stroke()
    }
  }
}

private final class SetupStepsView: NSView {
  var step = 0
  override func draw(_ dirtyRect: NSRect) {
    for i in 0..<3 {
      (i == step ? AeolianAppearance.accent : NSColor.labelColor.withAlphaComponent(0.14)).setFill()
      NSBezierPath(ovalIn: CGRect(x: CGFloat(i)*16+2, y: 1, width: 5, height: 5)).fill()
    }
  }
}

final class AeolianArtworkView: NSView {
  let image: NSImage
  init(image: NSImage) { self.image = image; super.init(frame: .zero); setAccessibilityRole(.image) }
  required init?(coder: NSCoder) { nil }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: bounds, xRadius: bounds.width*0.225, yRadius: bounds.height*0.225).addClip()
    image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
  }
}

final class AeolianPrimaryButton: NSButton {
  private var caption: NSTextField?
  override var title: String { didSet { caption?.stringValue = title; setAccessibilityLabel(title) } }
  init(title: String = "Next") {
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    setAccessibilityLabel(title)
    let caption = NSTextField(labelWithString: title)
    self.caption = caption
    caption.font = .systemFont(ofSize: 13, weight: .medium)
    caption.textColor = .white
    caption.alignment = .center
    caption.translatesAutoresizingMaskIntoConstraints = false
    caption.setAccessibilityElement(false)
    addSubview(caption)
    NSLayoutConstraint.activate([
      caption.centerXAnchor.constraint(equalTo: centerXAnchor),
      caption.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(convert(point, from: superview)) ? self : nil
  }
  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
    let ink=AeolianAppearance.onAccent
    if caption?.textColor != ink {caption?.textColor=ink}
    let accent = AeolianAppearance.accent
    (isHighlighted ? accent.blended(withFraction: 0.14, of: .black) ?? accent : accent).setFill()
    shape.fill()
    if window?.firstResponder === self {
      NSColor.keyboardFocusIndicatorColor.setStroke(); shape.lineWidth = 2; shape.stroke()
    }
  }
}

private final class SetupPermissionRow: NSView {
  let button: NSButton = SetupPermissionButton(title: "Allow", target: nil, action: nil)
  init(_ permission: SetupPermission) {
    super.init(frame: .zero)
    let icon = NSImageView(image: NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil) ?? NSImage())
    icon.contentTintColor = .secondaryLabelColor
    let title = NSTextField(labelWithString: permission.title)
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    let detail = NSTextField(wrappingLabelWithString: permission.detail)
    detail.font = .systemFont(ofSize: 11.5); detail.textColor = .secondaryLabelColor
    detail.preferredMaxLayoutWidth = 262
    let text = NSStackView(views: [title, detail])
    text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
    button.bezelStyle = .rounded; button.controlSize = .regular
    for view in [icon, text, button] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 26),
      text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 13),
      text.centerYAnchor.constraint(equalTo: centerYAnchor),
      text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
      text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
      button.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 10),
      button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      button.widthAnchor.constraint(equalToConstant: 88),button.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    update(permission)
  }
  required init?(coder: NSCoder) { nil }
  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
    NSColor.labelColor.withAlphaComponent(0.018).setFill();shape.fill()
    NSColor.labelColor.withAlphaComponent(0.065).setStroke();shape.lineWidth = 0.5;shape.stroke()
  }
  func update(_ permission: SetupPermission) {
    button.title = permission.granted ? "Allowed" : permission.action
    button.isEnabled = !permission.granted
    button.image = permission.granted ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) : nil
    button.imagePosition = .imageLeading
    button.setAccessibilityLabel("\(permission.title): \(button.title)")
  }
}

private final class SetupPermissionButton: NSButton {
  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 12, yRadius: 12)
    if isEnabled {
      AeolianAppearance.accent.withAlphaComponent(isHighlighted ? 0.16 : 0.07).setFill();shape.fill()
      AeolianAppearance.accent.withAlphaComponent(0.16).setStroke();shape.lineWidth = 0.5;shape.stroke()
    }
    let text = NSAttributedString(string: isEnabled ? title : "✓ Allowed", attributes: [
      .font: NSFont.systemFont(ofSize: 12, weight: .medium),
      .foregroundColor: isEnabled ? AeolianAppearance.accent : NSColor.secondaryLabelColor])
    let size = text.size();text.draw(at: CGPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2))
  }
}

final class MenuBarGuideView: NSView {
  var arrowX: CGFloat = 105 { didSet { needsDisplay = true } }
  override init(frame: CGRect) { super.init(frame: frame); wantsLayer = true }
  required init?(coder: NSCoder) { nil }
  override func draw(_ dirtyRect: NSRect) {
    let x = min(bounds.width - 14, max(14, arrowX))
    let path = NSBezierPath()
    path.move(to: CGPoint(x: x, y: 46)); path.line(to: CGPoint(x: x, y: 91))
    path.move(to: CGPoint(x: x - 7, y: 83));path.line(to: CGPoint(x: x, y: 91));path.line(to: CGPoint(x: x + 7, y: 83))
    path.lineWidth = 3; path.lineCapStyle = .round;path.lineJoinStyle = .round
    AeolianAppearance.accent.setStroke(); path.stroke()
    let pill = NSBezierPath(roundedRect: CGRect(x: 18, y: 6, width: 174, height: 32), xRadius: 16, yRadius: 16)
    NSColor.windowBackgroundColor.setFill();pill.fill()
    let text = NSAttributedString(string: "Your atmosphere is here", attributes: [
      .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
    let size = text.size();text.draw(at: CGPoint(x: (bounds.width-size.width)/2, y: 22-size.height/2))
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
