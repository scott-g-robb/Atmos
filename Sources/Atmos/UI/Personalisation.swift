import AppKit
import SwiftUI

enum InterfaceAppearance: String, CaseIterable {
  case system, light, dark
  var title: String { self == .system ? "Match System" : rawValue.capitalized }
  var native: NSAppearance? { self == .system ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
  var scheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
}
enum InterfaceAccent: String, CaseIterable {
  case blue, teal, green, orange, pink, purple
  var title: String { rawValue.capitalized }
  var color: NSColor {
    switch self {
    case .blue: return .systemBlue
    case .teal: return .systemTeal
    case .green: return .systemGreen
    case .orange: return .systemOrange
    case .pink: return .systemPink
    case .purple: return .systemPurple
    }
  }
}
extension Preferences {
  static var interfaceAppearance: InterfaceAppearance {
    get {UserDefaults.standard.string(forKey:"interfaceAppearance").flatMap(InterfaceAppearance.init(rawValue:)) ?? .system}
    set {UserDefaults.standard.set(newValue.rawValue,forKey:"interfaceAppearance")}
  }
  static var interfaceAccent: InterfaceAccent {
    get {UserDefaults.standard.string(forKey:"interfaceAccent").flatMap(InterfaceAccent.init(rawValue:)) ?? .blue}
    set {UserDefaults.standard.set(newValue.rawValue,forKey:"interfaceAccent")}
  }
}
extension Notification.Name { static let atmosPersonalisationChanged = Notification.Name("Atmos.personalisationChanged") }

final class AtmosAppearance: ObservableObject {
  static let shared = AtmosAppearance()
  @Published private(set) var revision = 0
  static var accent: NSColor {Preferences.interfaceAccent.color}
  static var onAccent: NSColor {
    guard let c=accent.usingColorSpace(.sRGB) else {return .white}
    func linear(_ v:CGFloat)->CGFloat {v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4)}
    let luminance=linear(c.redComponent)*0.2126+linear(c.greenComponent)*0.7152+linear(c.blueComponent)*0.0722
    return luminance>0.32 ? .black:.white
  }
  func apply() {
    revision += 1
    for window in NSApp?.windows ?? [] where window.identifier == AtmosPanelPresentation.identifier {
      window.appearance = Preferences.interfaceAppearance.native
      func redraw(_ view: NSView) {view.needsDisplay=true;view.subviews.forEach(redraw)}
      if let view=window.contentView {redraw(view)}
    }
    NotificationCenter.default.post(name:.atmosPersonalisationChanged,object:nil)
  }
}

/// Shared native controls for the optional setup page and later personalisation.
final class QuickCustomisationView: NSView {
  private let appearancePicker = NSPopUpButton()
  private let preset = NSPopUpButton()
  private let temperature = NSPopUpButton()
  private let wind = NSPopUpButton()
  private let rainfall = NSPopUpButton()
  private let visibility = NSPopUpButton()
  private let menuStyle = NSPopUpButton()
  private var swatches: [AccentSwatch] = []
  override init(frame:NSRect) {
    super.init(frame:frame)
    let stack=NSStackView();stack.orientation = .vertical;stack.spacing=16;stack.alignment = .leading
    stack.translatesAutoresizingMaskIntoConstraints=false;addSubview(stack)
    NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor),stack.trailingAnchor.constraint(equalTo:trailingAnchor),
      stack.topAnchor.constraint(equalTo:topAnchor),stack.bottomAnchor.constraint(equalTo:bottomAnchor)])
    func picker(_ popup:NSPopUpButton,_ titles:[String],_ tag:Int) {
      popup.addItems(withTitles:titles);popup.tag=tag;popup.target=self;popup.action=#selector(changed(_:))
      popup.controlSize = .regular;popup.translatesAutoresizingMaskIntoConstraints=false
      popup.widthAnchor.constraint(equalToConstant:210).isActive=true
    }
    func row(_ title:String,_ control:NSView) {
      let text=NSTextField(labelWithString:title);text.font = .systemFont(ofSize:12,weight:.medium)
      let spacer=NSView();spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
      let row=NSStackView(views:[text,spacer,control]);row.alignment = .centerY;row.spacing=12
      stack.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
      if let popup=control as? NSPopUpButton {popup.setAccessibilityLabel(title)}
    }
    picker(appearancePicker,InterfaceAppearance.allCases.map(\.title),0);row("Appearance",appearancePicker)
    let colors=NSStackView();colors.spacing=7
    for accent in InterfaceAccent.allCases {
      let button=AccentSwatch(accent:accent);button.target=self;button.action=#selector(accentChanged(_:))
      colors.addArrangedSubview(button);swatches.append(button)
    }
    row("Accent colour",colors)
    let divider=NSBox();divider.boxType = .separator;stack.addArrangedSubview(divider)
    divider.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
    picker(preset,["Metric","Imperial","Custom combination"],1);row("Measurements",preset)
    preset.menu?.autoenablesItems=false;preset.item(at:2)?.isEnabled=false
    picker(temperature,["Celsius · °C","Fahrenheit · °F"],2);row("Temperature",temperature)
    picker(wind,["Kilometres per hour · km/h","Miles per hour · mph"],3);row("Wind speed",wind)
    picker(rainfall,["Millimetres · mm","Inches · in"],4);row("Rainfall",rainfall)
    picker(visibility,["Kilometres · km","Miles · mi"],5);row("Visibility",visibility)
    let second=NSBox();second.boxType = .separator;stack.addArrangedSubview(second)
    second.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
    picker(menuStyle,MenuBarStyle.allCases.map(\.title),6);row("Menu bar",menuStyle)
    refresh()
  }
  required init?(coder:NSCoder){nil}
  private func refresh() {
    appearancePicker.selectItem(at:InterfaceAppearance.allCases.firstIndex(of:Preferences.interfaceAppearance) ?? 0)
    let u=Preferences.displayUnits,base=Preferences.weatherUnits
    preset.selectItem(at:u == WeatherDisplayUnits(preset:base) ? (base == .metric ? 0:1):2)
    for (popup,value) in [(temperature,u.temperatureUnits),(wind,u.windUnits),(rainfall,u.rainfallUnits),(visibility,u.visibilityUnits)] {
      popup.selectItem(at:value == .metric ? 0:1)
    }
    menuStyle.selectItem(at:MenuBarStyle.allCases.firstIndex(of:Preferences.menuBarStyle) ?? 0)
    swatches.forEach {$0.state = $0.accent == Preferences.interfaceAccent ? .on:.off;$0.needsDisplay=true}
  }
  @objc private func changed(_ sender:NSPopUpButton) {
    let index=sender.indexOfSelectedItem
    switch sender.tag {
    case 0: Preferences.interfaceAppearance=InterfaceAppearance.allCases[index]
    case 1: if index<2 {Preferences.weatherUnits=index == 0 ? .metric:.imperial}
    case 2...5:
      var units=Preferences.displayUnits
      let value:WeatherUnits=index == 0 ? .metric:.imperial
      switch sender.tag {
      case 2:units.temperatureUnits=value
      case 3:units.windUnits=value
      case 4:units.rainfallUnits=value
      default:units.visibilityUnits=value
      }
      Preferences.displayUnits=units
    case 6:Preferences.menuBarStyle=MenuBarStyle.allCases[index]
    default:break
    }
    refresh();AtmosAppearance.shared.apply()
  }
  @objc private func accentChanged(_ sender:AccentSwatch) {
    Preferences.interfaceAccent=sender.accent;refresh();AtmosAppearance.shared.apply()
  }
}
private final class AccentSwatch:NSButton {
  let accent:InterfaceAccent
  init(accent:InterfaceAccent) {
    self.accent=accent;super.init(frame:.zero)
    isBordered=false;toolTip=accent.title;setAccessibilityLabel(accent.title)
    translatesAutoresizingMaskIntoConstraints=false
    widthAnchor.constraint(equalToConstant:25).isActive=true;heightAnchor.constraint(equalToConstant:28).isActive=true
  }
  required init?(coder:NSCoder){nil}
  override func draw(_ dirtyRect:NSRect) {
    let circle=NSBezierPath(ovalIn:bounds.insetBy(dx:4,dy:5))
    accent.color.setFill();circle.fill()
    if Preferences.interfaceAccent == accent {
      NSColor.labelColor.withAlphaComponent(0.7).setStroke()
      let ring=NSBezierPath(ovalIn:bounds.insetBy(dx:1.5,dy:2.5));ring.lineWidth=1.5;ring.stroke()
    }
  }
}

final class PersonalisationController:NSObject {
  private var window:NSWindow?
  func show() {
    if let window {window.makeKeyAndOrderFront(nil);return}
    let window=PersonalisationWindow(contentRect:CGRect(x:0,y:0,width:520,height:640),styleMask:.borderless,backing:.buffered,defer:false)
    window.onCancel = { [weak self] in self?.close() }
    window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear;window.hasShadow=true
    window.level=AtmosPanelPresentation.level;window.identifier=AtmosPanelPresentation.identifier
    window.appearance=Preferences.interfaceAppearance.native;window.isMovableByWindowBackground=true
    let root=AtmosPanelSurface(frame:window.frame,welcome:true)
    let title=NSTextField(labelWithString:"Make it yours.");title.font = .systemFont(ofSize:27,weight:.medium)
    let choices=QuickCustomisationView(frame:.zero)
    let button=AtmosPrimaryButton(title:"Done");button.target=self;button.action=#selector(close);button.keyEquivalent="\r"
    for view in [title,choices,button] {view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view)}
    NSLayoutConstraint.activate([title.centerXAnchor.constraint(equalTo:root.centerXAnchor),title.topAnchor.constraint(equalTo:root.topAnchor,constant:35),
      choices.topAnchor.constraint(equalTo:title.bottomAnchor,constant:28),choices.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:40),
      choices.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-40),
      button.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-34),button.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-28),
      button.widthAnchor.constraint(equalToConstant:96),button.heightAnchor.constraint(equalToConstant:36)])
    window.contentView=root;window.center();self.window=window
    NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)
  }
  @objc private func close(){window?.close();window=nil}
}
private final class PersonalisationWindow:NSWindow {
  var onCancel:()->Void = {}
  override var canBecomeKey:Bool {true}
  override func cancelOperation(_ sender:Any?){onCancel()}
}
