import AppKit
import SwiftUI

/// The menu's actions remain the same AppKit commands used by shortcuts and tests.
/// Only its presentation changes; there is no second set of weather preferences.
final class AtmosMenuNavigation: ObservableObject {
  @Published var page = ""
  @Published var category = 0
  @Published var expandedPreset: UUID?
}

final class AtmosMenuModel: ObservableObject {
  @Published private(set) var revision = 0
  let menu: NSMenu
  let navigation = AtmosMenuNavigation()
  var reading: WeatherSnapshot?
  var activeScene: WeatherScene?
  var activeLayers: [WeatherMenuLayer] {
    (activeScene ?? reading.map { WeatherScene(weather: $0) })?.menuLayers ?? []
  }
  var place = "Your atmosphere"
  var status = "A little atmosphere on your desktop."
  var provider = "Apple Weather"
  var providerURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!
  var attribution: NSImage?
  var lastUpdateCheck: Date?
  var updateStatus = "Not checked yet"
  var updateAvailable = false
  var invoke: (NSMenuItem) -> Void = { _ in }
  var intensityChanged: (Snowfall) -> Void = { _ in }
  var windChanged: (Double) -> Void = { _ in }
  var cloudCoverageChanged: (Double) -> Void = { _ in }
  var beginNewPreset: () -> Void = {}
  let library: AtmosphereLibrary
  var selectPreset: (AtmospherePreset) -> Void = { _ in }
  var close: () -> Void = {}
  init(menu: NSMenu, library: AtmosphereLibrary = .shared) { self.menu = menu; self.library = library }
  var canSave: Bool { !Preferences.liveWeather && AtmospherePreset.current(name: library.name).isValid }
  func savePreset(name: String) {
    guard canSave else { return }
    library.save(.current(name: name, id: library.selectedID)); navigation.page = ""; revision += 1
  }
  func renameDraft(_ name: String) { library.name = name; revision += 1 }
  func newPreset() { library.newDraft(); beginNewPreset(); revision += 1 }
  func createPresetForEditing() { newPreset(); navigation.category = 0; navigation.page = "manual" }
  func switchPreset(_ preset: AtmospherePreset) { selectPreset(preset); navigation.expandedPreset = nil; navigation.page = "" }
  func editPreset(_ preset: AtmospherePreset) { selectPreset(preset); navigation.expandedPreset = nil; navigation.category = 0; navigation.page = "manual" }
  func togglePresetOptions(_ id: UUID) { navigation.expandedPreset = navigation.expandedPreset == id ? nil : id }
  func removePreset(_ id: UUID) {
    library.remove(id)
    if library.presets.isEmpty { library.newDraft(); beginNewPreset() }
    navigation.expandedPreset = nil; navigation.page = ""
    revision += 1
  }
  func refresh(weather: LiveWeather, scene: WeatherScene? = nil, updater: AppUpdater? = nil) {
    reading = weather.current; place = weather.locationName; status = weather.status
    activeScene = reading == nil ? nil : scene ?? reading.map { WeatherScene(weather: $0) }
    provider = weather.provider; providerURL = weather.providerURL; attribution = weather.attributionMark
    if let updater {
      lastUpdateCheck = updater.lastCheckedAt; updateStatus = updater.checkStatus
      updateAvailable = updater.updateAvailable
    }
    revision += 1
  }
  func item(_ title: String) -> NSMenuItem? { menu.items.first { $0.title.hasPrefix(title) } }
  var manual: NSMenu? { item("Manual Effects")?.submenu }
  var settings: NSMenu? { item("Settings")?.submenu }
  var details: NSMenu? { item("Local Weather")?.submenu }
  var updateItem: NSMenuItem? { menu.items.first { $0.action.map(NSStringFromSelector) == "checkForUpdates" } }
  func commands(in menu: NSMenu) -> [NSMenuItem] {
    var items = menu.items.filter { !$0.isHidden && $0.view == nil && $0.action.map(NSStringFromSelector) != "openWeatherProvider" }
    while items.first?.isSeparatorItem == true { items.removeFirst() }
    while items.last?.isSeparatorItem == true { items.removeLast() }
    return items
  }
  func effect(_ effect: WeatherEffect) -> NSMenuItem? {
    manual?.items.first { $0.representedObject as? String == effect.rawValue }
  }
}

final class AtmosMenuController: NSObject, NSWindowDelegate {
  let model: AtmosMenuModel
  private var panel: NSPanel?
  private weak var button: NSStatusBarButton?
  private var localMonitor: Any?
  private var globalMonitor: Any?
  private(set) var lastClosed = Date.distantPast
  var isShown: Bool { panel?.isVisible == true }
  init(menu: NSMenu) {
    model = AtmosMenuModel(menu: menu)
    super.init()
    model.close = { [weak self] in self?.close() }
  }
  deinit { removeMonitors() }
  func show(from button: NSStatusBarButton) {
    guard panel == nil, let anchorWindow = button.window else { return }
    self.button = button
    if !Preferences.liveWeather && model.library.presets.isEmpty && !model.library.hasDraft { model.newPreset() }
    let screen = anchorWindow.screen ?? NSScreen.main!
    let visible = screen.visibleFrame
    let height = min(520, visible.height - 30), width: CGFloat = 320
    let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let origin = CGPoint(x: min(visible.maxX-width-8, max(visible.minX+8, anchor.midX-width/2)),
      y: max(visible.minY+8, anchor.minY-height-3))
    let panel = AtmosDropdownPanel(contentRect: CGRect(origin: origin, size: CGSize(width: width, height: height)),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
    panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
    panel.level = AtmosPanelPresentation.level; panel.identifier = AtmosPanelPresentation.identifier
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    panel.delegate = self
    panel.contentView = NSHostingView(rootView: AtmosMenuView(model: model, pointerX: anchor.midX-origin.x).frame(width: width, height: height))
    self.panel = panel
    button.highlight(true)
    panel.makeKeyAndOrderFront(nil)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = panel.contentView?.layer {
      layer.add(AtmosPanelPresentation.settle(layer: layer, scales: [0.97, 1], keyTimes: [0, 1], duration: 0.2), forKey: "menuEntrance")
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
      if event.window !== panel { self?.close() }
      return event
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
  }
  func close() {
    guard let panel else { return }
    self.panel = nil; lastClosed = Date()
    button?.highlight(false); removeMonitors()
    panel.orderOut(nil); panel.contentView = nil
  }
  private func removeMonitors() {
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
  }
  func windowDidResignKey(_ notification: Notification) { close() }
}
private final class AtmosDropdownPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private struct MenuSurface: NSViewRepresentable {
  var pointerX: CGFloat
  func makeNSView(context: Context) -> MenuBubbleSurface { MenuBubbleSurface(frame: .zero, welcome: true, divider: false) }
  func updateNSView(_ view: MenuBubbleSurface, context: Context) { view.pointerX = pointerX; view.needsDisplay = true }
}

/// One continuous outline avoids a seam between the pointer and the panel.
private final class MenuBubbleSurface: AtmosPanelSurface {
  var pointerX: CGFloat = 160
  override var surfacePath: NSBezierPath {
    let b = bounds.insetBy(dx: 0.5, dy: 0.5), r: CGFloat = 22, k: CGFloat = 0.55228475
    let top = b.maxY-9, x = min(b.maxX-r-8, max(b.minX+r+8, pointerX))
    let p = NSBezierPath()
    p.move(to: CGPoint(x:b.minX+r,y:b.minY))
    p.line(to: CGPoint(x:b.maxX-r,y:b.minY))
    p.curve(to: CGPoint(x:b.maxX,y:b.minY+r), controlPoint1: CGPoint(x:b.maxX-r+k*r,y:b.minY), controlPoint2: CGPoint(x:b.maxX,y:b.minY+r-k*r))
    p.line(to: CGPoint(x:b.maxX,y:top-r))
    p.curve(to: CGPoint(x:b.maxX-r,y:top), controlPoint1: CGPoint(x:b.maxX,y:top-r+k*r), controlPoint2: CGPoint(x:b.maxX-r+k*r,y:top))
    p.line(to: CGPoint(x:x+8,y:top)); p.line(to: CGPoint(x:x,y:b.maxY)); p.line(to: CGPoint(x:x-8,y:top))
    p.line(to: CGPoint(x:b.minX+r,y:top))
    p.curve(to: CGPoint(x:b.minX,y:top-r), controlPoint1: CGPoint(x:b.minX+r-k*r,y:top), controlPoint2: CGPoint(x:b.minX,y:top-r+k*r))
    p.line(to: CGPoint(x:b.minX,y:b.minY+r))
    p.curve(to: CGPoint(x:b.minX+r,y:b.minY), controlPoint1: CGPoint(x:b.minX,y:b.minY+r-k*r), controlPoint2: CGPoint(x:b.minX+r-k*r,y:b.minY))
    p.close(); return p
  }
}

struct AtmosMenuView: View {
  @ObservedObject var model: AtmosMenuModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject private var navigation: AtmosMenuNavigation
  private var page: String { get { navigation.page } nonmutating set { navigation.page = newValue } }
  private var category: Int { get { navigation.category } nonmutating set { navigation.category = newValue } }
  @State private var nested: [NSMenu] = []
  @State private var nestedTitles: [String] = []
  @State private var parentPage = "settings"
  @State private var draftName: String
  private var expandedPreset: UUID? { get { navigation.expandedPreset } nonmutating set { navigation.expandedPreset = newValue } }
  private var live: Bool { Preferences.liveWeather }
  private let categories = ["Weather", "Drift", "Wildlife", "Advanced"]
  var pointerX: CGFloat
  init(model: AtmosMenuModel, page: String = "", category: Int = 0, pointerX: CGFloat = 160) {
    self.model = model
    self.pointerX = pointerX
    navigation = model.navigation
    _draftName = State(initialValue: model.library.name)
    model.navigation.page = page; model.navigation.category = category
  }
  private var animation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.2) }
  var body: some View {
    VStack(spacing: 0) {
      header.padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 12)
      if page.isEmpty { modeSwitcher.padding(.horizontal, 16).padding(.bottom, 8) }
      if page.isEmpty && live {
        VStack(spacing: 12) { overview }
          .padding(.horizontal, 16).padding(.vertical, 4)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      } else {
      ScrollView {
        VStack(spacing: 12) {
          if page.isEmpty { overview }
          else if page == "manual" { manual }
          else if page == "weather" { weatherDetails }
          else if page == "presets" { presets }
          else { settings }
        }.padding(.horizontal, 16).padding(.vertical, 4)
      }.scrollIndicators(.hidden).id(page)
      }
      footer.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
    }
    .background(MenuSurface(pointerX: pointerX))
    .onExitCommand { if page.isEmpty { model.close() } else { back() } }
    .animation(animation, value: page)
    .animation(animation, value: category)
    .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.5, dampingFraction: 0.92), value: model.reading != nil)
    .animation(animation, value: model.activeLayers)
  }
  private var header: some View {
    HStack(spacing: 11) {
      if !page.isEmpty {
        Button(action: back) { Image(systemName: "chevron.left").frame(width: 23, height: 30) }
          .buttonStyle(MenuPressStyle()).help("Back")
          .accessibilityLabel("Back")
      } else if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
        Image(nsImage: image).resizable().frame(width: 29, height: 29)
      } else { Image(systemName: "cloud.sun.fill").font(.system(size: 28)).symbolRenderingMode(.palette).foregroundStyle(.orange, .blue) }
      VStack(alignment: .leading, spacing: 3) {
        Text(page.isEmpty ? "Atmos" : page == "manual" ? "Make it yours" : page == "presets" ? "Your atmospheres" : page == "weather" ? "Local weather" : nestedTitles.last ?? "Settings")
          .font(.system(size: 16, weight: .semibold, design: .rounded))
        Text(page.isEmpty ? "A little atmosphere on your desktop." : page == "manual" ? "Three layers. Your own little world." : page == "weather" ? model.provider : "Just the way you like it.")
          .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      if page.isEmpty {
        Button { navigate("settings") } label: { Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 30, height: 30) }
          .buttonStyle(MenuPressStyle()).accessibilityLabel("Settings").help("Settings")
      }
    }
  }
  private var modeSwitcher: some View {
      HStack(spacing: 4) {
        mode("Live weather", symbol: "location.fill", selected: live) {
          if !live, let item = model.item("Live Weather") { model.invoke(item) }
        }
        mode("My atmosphere", symbol: "slider.horizontal.3", selected: !live) {
          if live, let item = model.item("Live Weather") { model.invoke(item) }
          if model.library.presets.isEmpty && !model.library.hasDraft { model.newPreset() }
          navigate("")
        }
      }.padding(4).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 15))
  }
  private var overview: some View {
    Group {
      if !live {
        if model.library.presets.isEmpty { manual }
        else { presets }
      } else {
      Button { navigate(live ? "weather" : "presets") } label: {
        hero.overlay(alignment: .topTrailing) {
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).padding(11)
        }
      }.buttonStyle(MenuPressStyle()).help(live ? "Local weather, details and source" : "Switch saved atmospheres")
      if model.reading != nil, live {
        activeEffects.transition(.opacity.combined(with: .offset(y: 6)))
        attribution.transition(.opacity)
      }
      }
    }
  }
  private var hero: some View {
    HStack(spacing: 12) {
      let scene = Preferences.manualScene
      let effect = live ? model.reading?.effect ?? .clouds : scene.primary == .none ? scene.stacked ?? scene.wildlife ?? .none : scene.primary
      VStack(alignment: .leading, spacing: 5) {
        if live, let reading = model.reading {
          Text(model.place.components(separatedBy: ",").first ?? model.place)
            .font(.system(size: 11, weight: .medium)).lineLimit(1).help(model.place)
          Text(Preferences.weatherUnits.temperature(reading.temperature)).font(.system(size: 36, weight: .ultraLight, design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.8)
          Text(reading.condition.localizedCapitalized).font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
          Text(live ? "Finding your sky…" : model.library.name)
            .font(.system(size: 19, weight: .light, design: .rounded))
          Text(live ? model.status : scene.summary)
            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(3)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if live && model.reading == nil {
        ProgressView().progressViewStyle(.circular).controlSize(.regular)
          .frame(width: 69, height: 69).accessibilityLabel("Loading local weather")
      } else {
      Group {
        if live, let reading = model.reading, effect == .none {
          Image(systemName: reading.weatherCode == 0 ? (reading.isDay == 1 ? "sun.max" : "moon.stars") : (reading.isDay == 1 ? "cloud.sun" : "cloud.moon"))
        } else { EffectIcon(effect: effect, size: 47) }
      }
        .font(.system(size: 47, weight: .light)).symbolRenderingMode(.palette)
        .foregroundStyle(Color.orange.opacity(0.9), Color.blue.opacity(0.8), Color.cyan.opacity(0.55))
        .shadow(color: .blue.opacity(0.15), radius: 15, y: 6).frame(width: 69, height: 69)
      }
    }.frame(maxWidth: .infinity).padding(16)
      .background(LinearGradient(colors: [.blue.opacity(0.065), .cyan.opacity(0.02), .orange.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
  }
  private var activeEffects: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("On your desktop").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
      if model.activeLayers.isEmpty {
        Label("A quiet sky", systemImage: "moon.stars").font(.system(size: 11)).foregroundStyle(.secondary)
      } else {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
          ForEach(model.activeLayers) { layer in
            HStack(spacing: 7) {
              EffectIcon(effect: layer.effect, size: 13).font(.system(size: 13)).foregroundStyle(tint(layer.effect))
                .frame(width: 16, height: 16).accessibilityHidden(true)
              Text(layer.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
              Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 8)
              .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
              .accessibilityElement(children: .combine)
          }
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
      .accessibilityElement(children: .contain).accessibilityLabel("On your desktop")
  }
  private func metric(_ measurement: WeatherMenuMeasurement) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(measurement.title, systemImage: measurement.symbol)
        .font(.system(size: 10)).foregroundStyle(.secondary)
      Text(measurement.value).font(.system(size: 16, weight: .medium, design: .rounded))
        .lineLimit(1).minimumScaleFactor(0.85)
      if let detail = measurement.detail {
        Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
      } else if measurement.value == "—" {
        Text("Not reported").font(.system(size: 9)).foregroundStyle(.secondary)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
      .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
      .accessibilityElement(children: .combine)
  }
  private func mode(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 11))
        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
    }.buttonStyle(MenuPressStyle()).accessibilityAddTraits(selected ? .isSelected : [])
  }
  private var manual: some View {
    VStack(spacing: 17) {
      VStack(spacing: 8) {
        HStack {
          TextField("Atmosphere name", text: $draftName)
            .textFieldStyle(.plain).font(.system(size: 17, weight: .medium, design: .rounded))
            .accessibilityLabel("Atmosphere name")
            .onChange(of: draftName) { _, name in model.renameDraft(name) }
            .onSubmit { saveCurrentPreset() }
        }
        if !model.library.presets.isEmpty {
        Button { navigate("") } label: {
          HStack { Label("Saved atmospheres", systemImage: "square.stack"); Spacer(); Text("\(model.library.presets.count)"); Image(systemName: "chevron.right") }
            .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.vertical, 5)
        }.buttonStyle(MenuPressStyle())
        }
      }.onAppear { draftName = model.library.name }
      if live {
        Label("Choose a layer to switch to manual", systemImage: "hand.tap")
          .font(.system(size: 10.5)).foregroundStyle(.secondary)
      }
      HStack(spacing: 4) {
        ForEach(0..<4) { index in
          Button { category = index } label: {
            VStack(spacing: 5) {
              Image(systemName: ["cloud.sun", "leaf", "bird", "slider.horizontal.3"][index]).font(.system(size: 14))
              Text(categories[index]).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
            }.frame(maxWidth: .infinity).padding(.vertical, 9)
              .background(category == index ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 11))
              .foregroundStyle(category == index ? Color.accentColor : Color.secondary)
          }.buttonStyle(MenuPressStyle()).accessibilityLabel(categories[index])
        }
      }.padding(3).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
      if category != 3 {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
        ForEach(effects, id: \.rawValue) { effect in
          if let item = model.effect(effect) {
            Button { model.invoke(item) } label: {
              VStack(spacing: 9) {
                EffectIcon(effect: effect).font(.system(size: 27, weight: .light)).symbolRenderingMode(.palette)
                  .foregroundStyle(tint(effect), tint(effect).opacity(0.55)).frame(height: 35)
                Text(effect.title).font(.system(size: 9.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
              }.frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(item.state == .on ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
                .overlay(alignment: .topTrailing) {
                  if item.state == .on { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor).padding(6) }
                }
            }.buttonStyle(MenuPressStyle()).disabled(!item.isEnabled)
              .accessibilityAddTraits(item.state == .on ? .isSelected : [])
              .help(item.state == .on ? "Turn off \(effect.title)" : effect.title)
          }
        }
      }
      }
      if category == 3 && !live {
        VStack(spacing: 12) {
          HStack { Text("Intensity"); Spacer(); Text(Preferences.snowfall.title).foregroundStyle(.secondary) }.font(.system(size: 11))
          Slider(value: Binding(get: { Double(Preferences.snowfall.rawValue) }, set: { model.intensityChanged(Snowfall(rawValue: Int($0.rounded())) ?? .steady) }), in: 0...Double(Snowfall.allCases.count - 1), step: 1).accessibilityLabel("Intensity")
          HStack { Text("Wind"); Spacer(); Text(Preferences.weatherUnits.wind(Preferences.manualWindSpeed)).monospacedDigit().foregroundStyle(.secondary) }.font(.system(size: 11))
          Slider(value: Binding(get: { Preferences.manualWindSpeed }, set: { model.windChanged($0.rounded()) }), in: 0...100).accessibilityLabel("Wind speed").accessibilityValue(Preferences.weatherUnits.wind(Preferences.manualWindSpeed))
          HStack { Text("Cloud coverage"); Spacer(); Text("\(Int((Preferences.manualScene.manualCloudCover ?? 0) * 100))%").monospacedDigit().foregroundStyle(.secondary) }.font(.system(size: 11))
          Slider(value: Binding(get: { Double(Preferences.manualScene.manualCloudCover ?? 0) * 100 }, set: { model.cloudCoverageChanged($0.rounded()) }), in: 0...100).accessibilityLabel("Cloud coverage")
        }.padding(15).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 17))
      }
      if let clear = model.manual?.items.first(where: { $0.title == "Clear Scene" }) { command(clear, symbol: "wind") }
    }
  }
  private var presets: some View {
    VStack(spacing: 8) {
      Button { model.createPresetForEditing(); draftName = model.library.name } label: {
        Label("New atmosphere", systemImage: "plus.circle").font(.system(size: 12, weight: .medium))
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }.buttonStyle(MenuPressStyle())
      if model.library.presets.isEmpty {
        Text("Pick your layers, then Save. Your atmospheres will be ready here whenever you want them.")
          .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
      }
      ForEach(model.library.presets) { preset in
        VStack(spacing: 0) {
        HStack(spacing: 5) {
          Button {
            model.switchPreset(preset); draftName = preset.name
          } label: {
            HStack(spacing: 12) {
              EffectIcon(effect: preset.icon).font(.system(size: 24)).foregroundStyle(tint(preset.icon)).frame(width: 32, height: 32)
              VStack(alignment: .leading, spacing: 4) {
                Text(preset.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(preset.scene.summary).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(2)
              }
              Spacer(minLength: 0)
              if !live && model.library.selectedID == preset.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).font(.system(size: 11)) }
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
          }.buttonStyle(MenuPressStyle()).accessibilityLabel(preset.name).accessibilityHint(preset.scene.summary)
          Button { model.togglePresetOptions(preset.id) } label: {
            Image(systemName: "chevron.down").rotationEffect(.degrees(expandedPreset == preset.id ? 180 : 0))
              .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 28, height: 34)
          }.buttonStyle(MenuPressStyle()).accessibilityLabel("Options for \(preset.name)").help("Edit or delete")
        }
        if expandedPreset == preset.id {
          Divider().opacity(0.35).padding(.horizontal, 11)
          HStack(spacing: 8) {
            Button {
              model.editPreset(preset); draftName = preset.name
            } label: { Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity).padding(.vertical, 10) }
              .buttonStyle(MenuPressStyle()).accessibilityLabel("Edit \(preset.name)")
            Button {
              expandedPreset = nil; model.removePreset(preset.id); draftName = model.library.name
            } label: { Label("Delete", systemImage: "trash").foregroundStyle(.red).frame(maxWidth: .infinity).padding(.vertical, 10) }
              .buttonStyle(MenuPressStyle()).accessibilityLabel("Delete \(preset.name)")
          }.font(.system(size: 11)).padding(5)
        }
        }.background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
          .animation(animation, value: expandedPreset)
      }
    }
  }
  private func saveCurrentPreset() {
    guard model.canSave else { return }
    model.savePreset(name: draftName); draftName = model.library.name
    navigate("")
  }
  private var effects: [WeatherEffect] {
    category == 1 ? WeatherEffect.seasonal : category == 2 ? WeatherEffect.wildlife : [.snow, .rain, .drizzle, .storm, .lightning, .sleet, .hail, .mist, .clouds, .sunlight]
  }
  private func tint(_ effect: WeatherEffect) -> Color {
    switch effect {
    case .leaves, .mapleSeeds: return .orange
    case .cherryBlossoms, .rosePetals: return .pink
    case .sunlight, .fireflies: return .yellow
    case .birds, .butterflies: return .teal
    default: return .blue
    }
  }
  private var weatherDetails: some View {
    VStack(spacing: 8) {
      if let reading = model.reading {
        HStack(spacing: 10) {
          Group {
            if reading.effect == .none {
              Image(systemName: reading.weatherCode == 0 ? (reading.isDay == 1 ? "sun.max" : "moon.stars") : (reading.isDay == 1 ? "cloud.sun" : "cloud.moon"))
            } else { EffectIcon(effect: reading.effect, size: 24) }
          }.font(.system(size: 24)).foregroundStyle(.blue)
          VStack(alignment: .leading, spacing: 4) {
            Text(model.place.components(separatedBy: ",").first ?? model.place).font(.system(size: 12, weight: .medium)).lineLimit(1).help(model.place)
            Text(reading.condition.localizedCapitalized).font(.system(size: 10.5)).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
        }.padding(.vertical, 4)
      } else { hero }
      attribution
      if let reading = model.reading {
        Text("Weather measurements").font(.system(size: 11, weight: .medium))
          .frame(maxWidth: .infinity, alignment: .leading)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
          ForEach(reading.menuMeasurements) { metric($0) }
        }
        Text("Observed " + Date(timeIntervalSince1970: reading.time).formatted(date: .omitted, time: .shortened)
          + (reading.isDay == 1 ? " · Daytime" : " · Nighttime"))
          .font(.system(size: 10)).foregroundStyle(.secondary)
        ForEach(reading.visibleAlerts(), id: \.id) { alert in
          Link(destination: alert.detailsURL) {
            Label(alert.summary + "\n" + alert.source, systemImage: "exclamationmark.triangle.fill")
              .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
              .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
          }
        }
        if !reading.alertsAvailable { Text("Weather warnings unavailable").font(.system(size: 10)).foregroundStyle(.secondary) }
      }
      if let details = model.details { commands(details) }
    }
  }
  private var attribution: some View {
      Link(destination: model.providerURL) {
        HStack(spacing: 6) {
          if let mark = model.attribution, model.provider == "Apple Weather" {
            Image(nsImage: mark).renderingMode(.template).resizable().scaledToFit().frame(width: 82, height: 14)
          } else { Text(model.provider) }
          Image(systemName: "arrow.up.right").font(.system(size: 8))
        }.font(.system(size: 10)).foregroundStyle(.secondary)
      }.buttonStyle(.plain).frame(maxWidth: .infinity).padding(.vertical, 3)
  }
  private var settings: some View {
    VStack(spacing: 4) {
      if let menu = nested.last ?? model.settings { commands(menu) }
    }
  }
  private func commands(_ menu: NSMenu) -> some View {
    VStack(spacing: 2) {
    ForEach(model.commands(in: menu), id: \.self) { item in
      if item.isSeparatorItem { Divider().opacity(0.4).padding(.vertical, 7) }
      else if item.isSectionHeader { Text(item.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 7) }
      else { command(item) }
    }
    }
  }
  private func command(_ item: NSMenuItem, symbol: String? = nil) -> some View {
    Button {
      if let child = item.submenu {
        if nested.isEmpty { parentPage = page }
        page = "settings"; nested.append(child); nestedTitles.append(item.title)
      }
      else { model.invoke(item) }
    } label: {
      HStack(spacing: 10) {
        if let symbol { Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary) }
        else if let image = item.image { Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18).foregroundStyle(.secondary) }
        else { Image(systemName: item.submenu == nil ? (item.state == .on ? "checkmark.circle.fill" : "circle") : "square.grid.2x2").frame(width: 18).foregroundStyle(item.state == .on ? Color.accentColor : Color.secondary.opacity(0.65)) }
        VStack(alignment: .leading, spacing: 4) {
          Text(item.title).font(.system(size: 11.5)).multilineTextAlignment(.leading)
          if #available(macOS 14.4, *), let detail = item.subtitle, !detail.isEmpty {
            Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
          }
        }
        Spacer(minLength: 0)
        if item.submenu != nil { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
      }.padding(.horizontal, 11).padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }.buttonStyle(MenuPressStyle()).disabled(!item.isEnabled).help(item.toolTip ?? item.title)
  }
  private var footer: some View {
    VStack(spacing: 10) {
      Divider().opacity(0.4)
      if page == "manual" || (page.isEmpty && !live && model.library.presets.isEmpty) {
        HStack {
          if !model.canSave { Text("Choose an effect to save").font(.system(size: 9.5)).foregroundStyle(.secondary) }
          Spacer()
          Button { saveCurrentPreset() } label: {
            Label("Save", systemImage: "bookmark").font(.system(size: 12, weight: .medium))
              .frame(width: 104, height: 34).foregroundStyle(.white)
              .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 17))
          }.buttonStyle(MenuPressStyle()).disabled(!model.canSave).accessibilityLabel("Save")
        }
      } else {
      HStack {
        if let update = model.updateItem {
          Button { model.invoke(update) } label: {
            HStack(spacing: 10) {
              Image(systemName: "arrow.triangle.2.circlepath").frame(width: 18).foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 2) {
                Text(update.title).font(.system(size: 11.5))
                HStack(spacing: 3) {
                  Text("Last checked at: " + (model.lastUpdateCheck?.formatted(date: .omitted, time: .shortened) ?? "—") + " ·")
                    .foregroundStyle(.secondary)
                  Text(model.updateStatus).foregroundStyle(model.updateAvailable ? Color.orange : Color.secondary)
                }.font(.system(size: 8.5)).lineLimit(1).minimumScaleFactor(0.85)
              }
              Spacer(minLength: 0)
            }.padding(.horizontal, 11).padding(.vertical, 4).contentShape(Rectangle())
          }.buttonStyle(MenuPressStyle()).disabled(!update.isEnabled).frame(maxWidth: .infinity)
        }
        Button { model.close(); NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 33, height: 31).foregroundStyle(.secondary) }
          .buttonStyle(MenuPressStyle()).keyboardShortcut("q").accessibilityLabel("Quit Atmos").help("Quit Atmos")
      }
      }
    }
  }
  private func navigate(_ destination: String) { nested = []; nestedTitles = []; page = destination }
  private func back() {
    if !nested.isEmpty {
      nested.removeLast(); nestedTitles.removeLast()
      if nested.isEmpty { page = parentPage }
    } else { page = "" }
  }
}

private struct MenuPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    MenuHoverBody(configuration: configuration, calm: reduceMotion)
  }
  private struct MenuHoverBody: View {
    let configuration: Configuration
    let calm: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
      configuration.label
        .opacity(isEnabled ? 1 : 0.35)
        .background(Color.primary.opacity(configuration.isPressed ? 0.09 : hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 12))
        .scaleEffect(configuration.isPressed && !calm ? 0.98 : 1)
        .onHover { hovering = $0 }
        .animation(calm ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        .animation(calm ? nil : .easeOut(duration: 0.12), value: hovering)
    }
  }
}
