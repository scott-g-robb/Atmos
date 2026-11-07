import AppKit

final class AppUpdater {
  var changed:()->Void = {}
  private var task:Task<Void,Never>?
  private var panel:UpdatePanel?
  private var installing=false
  private var generation=0
  private var automaticTask=false
  private var automaticTimer:Timer?
  private var automaticActive=false
  private var automaticEnabled=false

  func setAutomaticActivity(enabled:Bool,active:Bool) {
    automaticEnabled=enabled;automaticActive=active
    guard enabled && active else {
      automaticTimer?.invalidate();automaticTimer=nil
      if automaticTask && !installing {generation+=1;task?.cancel();task=nil;automaticTask=false}
      return
    }
    guard automaticTimer==nil else {return}
    let last=UserDefaults.standard.double(forKey:"lastAutomaticUpdateCheck")
    let due=max(Date().timeIntervalSince1970+1,last+7200)
    let timer=Timer(fire:Date(timeIntervalSince1970:due),interval:7200,repeats:true) { [weak self] _ in self?.checkAutomatically() }
    timer.tolerance=120;RunLoop.main.add(timer,forMode:.common);automaticTimer=timer
  }
  private func checkAutomatically() {
    guard automaticEnabled && automaticActive,task==nil,
      FileManager.default.isWritableFile(atPath:Bundle.main.bundleURL.deletingLastPathComponent().path) else {return}
    generation+=1;let token=generation;automaticTask=true
    UserDefaults.standard.set(Date().timeIntervalSince1970,forKey:"lastAutomaticUpdateCheck")
    task=Task { @MainActor [weak self] in
      guard let self else {return}
      do {
        let release=try await service.latest()
        try Task.checkCancellation()
        guard generation==token,automaticEnabled,automaticActive else {return}
        task=nil;automaticTask=false
        if let latest=release.version,let current=AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""),latest>current {
          download(release,automatic:true)
        }
      } catch {if generation==token {task=nil;automaticTask=false}}
    }
  }

  private(set) var menuTitle="Check for Updates…"
  private let service=GitHubUpdates()

  func check() {
    if task != nil && automaticTask && !installing {
      generation+=1;task?.cancel();task=nil;automaticTask=false
    }
    if task != nil {
      if automaticTask {
        let panel=self.panel ?? UpdatePanel();self.panel=panel
        panel.show(title:"Updating Atmos",detail:"An update is already being prepared. Atmos will reopen when it is ready.",primary:"Keep Working")
        panel.primaryAction={ [weak self] in self?.panel?.close();self?.panel=nil }
        panel.secondaryAction=panel.primaryAction
      }
      return
    }
    generation+=1;let token=generation
    let panel=self.panel ?? UpdatePanel();self.panel=panel
    panel.show(title:"Checking for updates…",detail:"Looking for the latest Atmos on GitHub.",primary:"",secondary:"Cancel",working:true)
    panel.secondaryAction={ [weak self] in self?.cancel() }
    setTitle("Checking for Updates…")
    task=Task { @MainActor [weak self, panel] in
      guard let self else {return}
      do {
        let release=try await service.latest()
        try Task.checkCancellation()
        guard let latest=release.version,let current=AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") else {throw UpdateError.invalidRelease}
        task=nil;setTitle("Check for Updates…")
        if latest>current {
          _=try release.installer()
          panel.show(title:"Atmos \(latest) is available",detail:"You're using Atmos \(current). Download and install the latest version?",primary:"Download & Install",secondary:"Not Now")
          panel.primaryAction={ [weak self] in self?.download(release) }
        } else {
          panel.show(title:"Atmos is up to date.",detail:"You're using Atmos \(current).",primary:"Done")
          panel.primaryAction={ [weak self] in self?.cancel() }
        }
      } catch {if generation==token {finish(error)}}
    }
  }
  private func download(_ release:GitHubRelease,automatic:Bool=false) {
    guard task==nil,let version=release.version else {return}
    let panel=automatic ? nil:self.panel
    automaticTask=automatic
    generation+=1;let token=generation
    panel?.show(title:"Downloading Atmos \(version)",detail:"Your atmosphere will be ready in a moment.",primary:"",secondary:"Cancel",working:true)
    panel?.secondaryAction={ [weak self] in self?.cancel() }
    if !automatic {setTitle("Downloading Atmos…")}
    task=Task { @MainActor [weak self, panel] in
      guard let self else {return}
      var workspace:URL?
      do {
        let asset=try release.installer(),expected=try await service.expectedHash(for:asset,in:release)
        try Task.checkCancellation()
        let cache=try FileManager.default.url(for:.cachesDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
          .appendingPathComponent("dev.grobb.Atmos/Updates",isDirectory:true)
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        // Previous sessions contain only our downloads, never user documents.
        for old in (try? FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)) ?? [] {
          if old.lastPathComponent.hasPrefix("session-") {try? FileManager.default.removeItem(at:old)}
        }
        let directory=cache.appendingPathComponent("session-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);workspace=directory
        let image=directory.appendingPathComponent("Atmos.dmg")
        let downloader=UpdateDownload(destination:image) { [weak panel] fraction,written,total in panel?.setProgress(fraction,written:written,total:total) }
        try await downloader.download(asset)
        try Task.checkCancellation()
        panel?.show(title:"Preparing Atmos \(version)",detail:"Verifying the download and app signature.",primary:"",secondary:"Cancel",working:true)
        let actual=try await Task.detached(priority:.utility){try UpdateFiles.hash(image)}.value
        guard actual==expected else {throw UpdateError.badChecksum}
        let installed=Bundle.main.bundleURL
        let prepared=try await UpdateFiles.prepare(image:image,in:directory,installed:installed,version:version)
        try Task.checkCancellation()
        installing=true
        panel?.show(title:"Installing Atmos \(version)",detail:"Atmos will close briefly and reopen with your settings.",primary:"",working:true)
        if !automatic {setTitle("Installing Atmos…")}
        try await UpdateFiles.scheduleInstall(app:prepared.app,destination:installed,requirement:prepared.requirement,version:version,automatic:automatic)
        if automatic,let build=Bundle(url:prepared.app)?.infoDictionary?["CFBundleVersion"] as? String {
          SetupProgress.recordAutomaticRelaunch(release:"\(version).\(build)",path:installed.resolvingSymlinksInPath().path)
        }
        // The validated sibling is ready before this process exits. A short-lived
        // helper performs the atomic swap and reopens the same app location.
        NSApp.terminate(nil)
      } catch {
        if let workspace {try? FileManager.default.removeItem(at:workspace)}
        if generation==token {
          installing=false
          if automatic {task=nil;automaticTask=false} else {finish(error)}
        }
      }
    }
  }
  private func cancel() {
    guard !installing else {return}
    generation+=1
    task?.cancel();task=nil
    panel?.close();panel=nil;setTitle("Check for Updates…")
  }
  private func finish(_ error:Error) {
    task=nil;setTitle("Check for Updates…")
    if error is CancellationError || (error as? URLError)?.code == .cancelled {return}
    guard let panel else {return}
    let detail=(error as? UpdateError)?.localizedDescription
      ?? "The update couldn't be completed. Check your connection and try again. Your current app is unchanged."
    panel.show(title:"Couldn't update Atmos",detail:detail,primary:"Try Again",secondary:"Close")
    panel.primaryAction={ [weak self] in self?.check() }
    panel.secondaryAction={ [weak self] in self?.cancel() }
  }
  private func setTitle(_ title:String){menuTitle=title;changed()}
}
