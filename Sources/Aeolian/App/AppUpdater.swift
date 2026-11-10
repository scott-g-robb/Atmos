#if APP_STORE
import AppKit

/// Store installations are updated exclusively by the Mac App Store.
final class AppUpdater {
  static let isStore = true
  var changed: () -> Void = {}
  var lastCheckedAt: Date? { nil }
  var updateAvailable: Bool { false }
  var checkStatus: String { "Managed by App Store" }
  var menuTitle: String { "App Store Updates…" }
  func setAutomaticActivity(enabled: Bool, active: Bool) {}
  func check() {
    NSWorkspace.shared.open(URL(string: "macappstore://itunes.apple.com/app/id6832753164")!)
  }
  func stop() {}
}
#else
import AppKit

final class AppUpdater {
  static let isStore = false
  var changed:()->Void = {}
  private var task:Task<Void,Never>?
  private var panel:UpdatePanel?
  private var installing=false
  private var generation=0
  private var automaticTask=false
  private var automaticTimer:Timer?
  private var automaticActive=false
  private var automaticEnabled=false
  private var checking=false
  private let service:GitHubUpdates
  private let defaults:UserDefaults
  private let currentVersion:AppVersion?
  private let now:()->Date
  private let automaticInstaller:((GitHubRelease)->Void)?
  private let canInstallAutomatically:()->Bool
  private(set) var lastCheckedAt:Date?
  private var latestCheckedVersion:AppVersion?
  private var checkFailed=false
  var updateAvailable:Bool {
    guard let latestCheckedVersion,let currentVersion else {return false}
    return latestCheckedVersion>currentVersion
  }
  var checkStatus:String {
    if checking {return "Checking…"}
    if checkFailed {return "Couldn't check"}
    if updateAvailable {return "Update available"}
    return latestCheckedVersion == nil ? "Not checked yet":"Up-To-Date"
  }
  init(service:GitHubUpdates=GitHubUpdates(),defaults:UserDefaults = .standard,
    currentVersion:AppVersion?=AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""),
    now:@escaping()->Date={Date()},automaticInstaller:((GitHubRelease)->Void)?=nil,
    canInstallAutomatically:@escaping()->Bool={FileManager.default.isWritableFile(atPath:Bundle.main.bundleURL.deletingLastPathComponent().path)}) {
    self.service=service;self.defaults=defaults;self.currentVersion=currentVersion
    self.now=now;self.automaticInstaller=automaticInstaller
    self.canInstallAutomatically=canInstallAutomatically
    if let date=defaults.object(forKey:"lastUpdateCheck") as? Date {lastCheckedAt=date}
    latestCheckedVersion=defaults.string(forKey:"latestCheckedUpdateVersion").flatMap(AppVersion.init)
    checkFailed=defaults.bool(forKey:"lastUpdateCheckFailed")
  }
  deinit {automaticTimer?.invalidate();task?.cancel()}

  func setAutomaticActivity(enabled:Bool,active:Bool) {
    automaticEnabled=enabled;automaticActive=active
    guard active,currentVersion != nil else {
      automaticTimer?.invalidate();automaticTimer=nil
      if automaticTask && !installing {cancelBackgroundTask()}
      return
    }
    // Disabling installation must not cancel a discovery request. An uncommitted
    // silent download can be cancelled; the installed app remains untouched.
    if !enabled && automaticTask && !checking && !installing {cancelBackgroundTask()}
    guard automaticTimer==nil else {return}
    let last=max(lastCheckedAt?.timeIntervalSince1970 ?? 0,defaults.double(forKey:"lastAutomaticUpdateCheck"))
    let due=max(now().timeIntervalSince1970+1,last+7200)
    let timer=Timer(fire:Date(timeIntervalSince1970:due),interval:7200,repeats:true) { [weak self] _ in self?.checkAutomatically() }
    timer.tolerance=min(120,max(0,due-now().timeIntervalSince1970)*0.1)
    RunLoop.main.add(timer,forMode:.common);automaticTimer=timer
  }
  func checkAutomatically() {
    guard automaticActive,task==nil else {return}
    generation+=1;let token=generation;automaticTask=true;checking=true
    defaults.set(now().timeIntervalSince1970,forKey:"lastAutomaticUpdateCheck")
    changed()
    task=Task { @MainActor [weak self] in
      guard let self else {return}
      do {
        let release=try await service.latest()
        try Task.checkCancellation()
        guard generation==token,automaticActive else {return}
        task=nil;automaticTask=false
        try record(release)
        if updateAvailable,automaticEnabled,canInstallAutomatically() {
          if let automaticInstaller {automaticInstaller(release)} else {download(release,automatic:true)}
        }
      } catch {if generation==token {task=nil;automaticTask=false;recordFailure()}}
    }
  }

  private(set) var menuTitle="Check for Updates…"

  func check() {
    if task != nil && automaticTask && !installing {
      cancelBackgroundTask()
    }
    if task != nil {
      if automaticTask {
        let panel=self.panel ?? UpdatePanel();self.panel=panel
        panel.show(title:"Updating Aeolian",detail:"An update is already being prepared. Aeolian will reopen when it is ready.",primary:"Keep Working")
        panel.primaryAction={ [weak self] in self?.panel?.close();self?.panel=nil }
        panel.secondaryAction=panel.primaryAction
      }
      return
    }
    generation+=1;let token=generation
    let panel=self.panel ?? UpdatePanel();self.panel=panel
    panel.show(title:"Checking for updates…",detail:"Looking for the latest Aeolian on GitHub.",primary:"",secondary:"Cancel",working:true)
    panel.secondaryAction={ [weak self] in self?.cancel() }
    setTitle("Checking for Updates…")
    checking=true;changed()
    task=Task { @MainActor [weak self, panel] in
      guard let self else {return}
      do {
        let release=try await service.latest()
        try Task.checkCancellation()
        guard generation==token else {return}
        guard let latest=release.version,let current=currentVersion else {throw UpdateError.invalidRelease}
        try record(release)
        task=nil;setTitle("Check for Updates…")
        if latest>current {
          _=try release.installer()
          panel.show(title:"Aeolian \(latest) is available",detail:"You're using Aeolian \(current). Download and install the latest version?",primary:"Download & Install",secondary:"Not Now")
          panel.primaryAction={ [weak self] in self?.download(release) }
        } else {
          panel.show(title:"Aeolian is up to date.",detail:"You're using Aeolian \(current).",primary:"Done")
          panel.primaryAction={ [weak self] in self?.cancel() }
        }
      } catch {if generation==token {recordFailure();finish(error)}}
    }
  }
  private func download(_ release:GitHubRelease,automatic:Bool=false) {
    guard task==nil,let version=release.version else {return}
    let panel=automatic ? nil:self.panel
    automaticTask=automatic
    generation+=1;let token=generation
    panel?.show(title:"Downloading Aeolian \(version)",detail:"Your atmosphere will be ready in a moment.",primary:"",secondary:"Cancel",working:true)
    panel?.secondaryAction={ [weak self] in self?.cancel() }
    if !automatic {setTitle("Downloading Aeolian…")}
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
        let image=directory.appendingPathComponent("Aeolian.dmg")
        let downloader=UpdateDownload(destination:image) { [weak panel] fraction,written,total in panel?.setProgress(fraction,written:written,total:total) }
        try await downloader.download(asset)
        try Task.checkCancellation()
        panel?.show(title:"Preparing Aeolian \(version)",detail:"Verifying the download and app signature.",primary:"",secondary:"Cancel",working:true)
        let actual=try await Task.detached(priority:.utility){try UpdateFiles.hash(image)}.value
        guard actual==expected else {throw UpdateError.badChecksum}
        let installed=Bundle.main.bundleURL
        let prepared=try await UpdateFiles.prepare(image:image,in:directory,installed:installed,version:version)
        try Task.checkCancellation()
        installing=true
        panel?.show(title:"Installing Aeolian \(version)",detail:"Aeolian will close briefly and reopen with your settings.",primary:"",working:true)
        if !automatic {setTitle("Installing Aeolian…")}
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
    task?.cancel();task=nil;checking=false;automaticTask=false
    panel?.close();panel=nil;setTitle("Check for Updates…")
  }
  private func finish(_ error:Error) {
    task=nil;setTitle("Check for Updates…")
    if error is CancellationError || (error as? URLError)?.code == .cancelled {return}
    guard let panel else {return}
    let detail=(error as? UpdateError)?.localizedDescription
      ?? "The update couldn't be completed. Check your connection and try again. Your current app is unchanged."
    panel.show(title:"Couldn't update Aeolian",detail:detail,primary:"Try Again",secondary:"Close")
    panel.primaryAction={ [weak self] in self?.check() }
    panel.secondaryAction={ [weak self] in self?.cancel() }
  }
  private func setTitle(_ title:String){menuTitle=title;changed()}

  private func record(_ release:GitHubRelease) throws {
    guard let latest=release.version,let currentVersion else {throw UpdateError.invalidRelease}
    if latest>currentVersion {_=try release.installer()}
    latestCheckedVersion=latest;lastCheckedAt=now();checkFailed=false;checking=false
    defaults.set(lastCheckedAt,forKey:"lastUpdateCheck")
    defaults.set(latest.description,forKey:"latestCheckedUpdateVersion")
    defaults.set(false,forKey:"lastUpdateCheckFailed")
    reschedule();changed()
  }
  private func recordFailure() {
    checking=false;checkFailed=true;lastCheckedAt=now()
    defaults.set(lastCheckedAt,forKey:"lastUpdateCheck")
    defaults.set(true,forKey:"lastUpdateCheckFailed")
    reschedule();changed()
  }
  private func reschedule() {
    automaticTimer?.invalidate();automaticTimer=nil
    setAutomaticActivity(enabled:automaticEnabled,active:automaticActive)
  }
  private func cancelBackgroundTask() {
    generation+=1;task?.cancel();task=nil;automaticTask=false;checking=false;changed()
  }
  func stop() {
    automaticTimer?.invalidate();automaticTimer=nil;automaticActive=false
    if !installing {generation+=1;task?.cancel();task=nil;automaticTask=false;checking=false}
  }
}

#endif
