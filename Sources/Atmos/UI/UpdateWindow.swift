import AppKit
import QuartzCore

/// The updater shares Atmos's welcome surface, artwork, typography and controls.
final class UpdatePanel:NSObject {
  private let window:UpdatePanelWindow
  private let title=NSTextField(wrappingLabelWithString:"")
  private let detail=NSTextField(wrappingLabelWithString:"")
  private let status=NSTextField(labelWithString:"")
  private let progress=NSProgressIndicator()
  private let primary=AtmosPrimaryButton(title:"Done")
  private let secondary=NSButton(title:"Not Now",target:nil,action:nil)
  var primaryAction:()->Void = {}
  var secondaryAction:()->Void = {}

  init(icon:NSImage? = nil) {
    let size=CGSize(width:520,height:400)
    window=UpdatePanelWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
    super.init()
    window.title="Atmos Updates"
    window.isOpaque=false;window.backgroundColor = .clear;window.hasShadow=true
    window.level = AtmosPanelPresentation.level;window.identifier = AtmosPanelPresentation.identifier
    window.appearance=Preferences.interfaceAppearance.native
    window.isReleasedWhenClosed=false;window.isMovableByWindowBackground=true
    window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
    window.onCancel={ [weak self] in self?.secondaryAction() }
    let root=NSView(frame:CGRect(origin:.zero,size:size));root.wantsLayer=true
    root.layer?.cornerRadius=28;root.layer?.masksToBounds=true
    let surface=AtmosPanelSurface(frame:root.bounds,welcome:true)
    surface.autoresizingMask=[.width,.height];root.addSubview(surface)
    let iconURL=Bundle.main.url(forResource:"AppIcon",withExtension:"icns")
    let artwork=icon ?? iconURL.flatMap{NSImage(contentsOf:$0)} ?? NSImage(systemSymbolName:"cloud.sun.fill",accessibilityDescription:"Atmos")!
    let icon=AtmosArtworkView(image:artwork)
    icon.translatesAutoresizingMaskIntoConstraints=false
    NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant:64),icon.heightAnchor.constraint(equalToConstant:64)])
    title.font = .systemFont(ofSize:25,weight:.medium);title.alignment = .center
    detail.font = .systemFont(ofSize:13);detail.textColor = .secondaryLabelColor;detail.alignment = .center
    detail.preferredMaxLayoutWidth=424
    status.font = .systemFont(ofSize:11.5);status.textColor = .secondaryLabelColor;status.alignment = .center
    progress.style = .bar;progress.minValue=0;progress.maxValue=1;progress.controlSize = .small
    progress.translatesAutoresizingMaskIntoConstraints=false
    let stack=NSStackView(views:[icon,title,detail,progress,status])
    stack.orientation = .vertical;stack.alignment = .centerX;stack.spacing=13
    stack.setCustomSpacing(18,after:icon);stack.setCustomSpacing(10,after:title)
    stack.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(stack)
    for view in [title,detail] {view.translatesAutoresizingMaskIntoConstraints=false;view.widthAnchor.constraint(equalToConstant:424).isActive=true}
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo:root.centerXAnchor),stack.centerYAnchor.constraint(equalTo:root.centerYAnchor,constant:-38),
      progress.widthAnchor.constraint(equalToConstant:330),
    ])
    primary.target=self;primary.action=#selector(choosePrimary);primary.keyEquivalent="\r"
    secondary.target=self;secondary.action=#selector(chooseSecondary);secondary.isBordered=false;secondary.contentTintColor = .secondaryLabelColor
    for button in [primary,secondary] {button.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(button)}
    NSLayoutConstraint.activate([
      primary.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-34),primary.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-28),
      primary.heightAnchor.constraint(equalToConstant:36),primary.widthAnchor.constraint(equalToConstant:168),
      secondary.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:34),secondary.centerYAnchor.constraint(equalTo:primary.centerYAnchor),
    ])
    window.contentView=root;window.center()
  }
  @objc private func choosePrimary(){primaryAction()}
  @objc private func chooseSecondary(){secondaryAction()}
  func show(title:String,detail:String,primary:String,secondary:String?=nil,working:Bool=false) {
    self.title.stringValue=title;self.detail.stringValue=detail
    self.primary.title=primary;self.primary.isHidden=primary.isEmpty
    self.primary.isEnabled = !primary.isEmpty
    self.secondary.title=secondary ?? "";self.secondary.isHidden=secondary==nil
    progress.isHidden = !working;progress.isIndeterminate=working
    status.isHidden = !working;status.stringValue=""
    if working {progress.startAnimation(nil)} else {progress.stopAnimation(nil)}
    window.contentView?.layoutSubtreeIfNeeded()
    if !window.isVisible {
      window.alphaValue=1
      let layer=window.contentView?.layer
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,let layer {
        layer.add(AtmosPanelPresentation.settle(layer:layer,scales:[0.96,1.005,1],keyTimes:[0,0.7,1],duration:0.32),forKey:"updateEntrance")
      }
    }
    NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)
  }
  func setProgress(_ fraction:Double,written:Int64,total:Int64) {
    progress.isIndeterminate=false;progress.doubleValue=max(0,min(1,fraction))
    let bytes=ByteCountFormatter();bytes.countStyle = .file
    status.stringValue=total>0 ? "\(bytes.string(fromByteCount:written)) of \(bytes.string(fromByteCount:total))" : bytes.string(fromByteCount:written)
  }
  func close() {
    progress.stopAnimation(nil)
    NSAnimationContext.runAnimationGroup({context in
      context.duration=0.18;window.animator().alphaValue=0
    },completionHandler:{[window] in window.orderOut(nil)})
  }
}

private final class UpdatePanelWindow:NSWindow {
  var onCancel:()->Void = {}
  override var canBecomeKey:Bool {true}
  override func cancelOperation(_ sender:Any?){onCancel()}
}
