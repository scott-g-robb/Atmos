import AppKit
import CryptoKit
import Security

struct AppVersion: Equatable, Comparable, CustomStringConvertible {
  let major: Int
  let minor: Int
  let patch: Int
  init?(_ text: String) {
    let parts=text.split(separator:".",omittingEmptySubsequences:false)
    guard parts.count==3,parts.allSatisfy({!$0.isEmpty && $0.utf8.allSatisfy{48...57 ~= $0}}),
      let major=Int(parts[0]),let minor=Int(parts[1]),let patch=Int(parts[2]) else {return nil}
    self.major=major;self.minor=minor;self.patch=patch
  }
  var description:String {"\(major).\(minor).\(patch)"}
  static func <(lhs:Self,rhs:Self)->Bool {
    if lhs.major != rhs.major {return lhs.major<rhs.major}
    if lhs.minor != rhs.minor {return lhs.minor<rhs.minor}
    return lhs.patch<rhs.patch
  }
}

struct GitHubRelease: Decodable {
  struct Asset: Decodable {
    let name:String
    let browserDownloadURL:URL
    let size:Int64
    let digest:String?
    enum CodingKeys:String,CodingKey {case name,size,digest;case browserDownloadURL="browser_download_url"}
    var sha256:String? {
      guard let digest,digest.hasPrefix("sha256:") else {return nil}
      let value=String(digest.dropFirst(7)).lowercased()
      return UpdateFiles.isSHA256(value) ? value : nil
    }
  }
  let name:String
  let draft:Bool
  let prerelease:Bool
  let assets:[Asset]
  var version:AppVersion? {
    guard !draft,!prerelease,name.hasPrefix("Atmos ") else {return nil}
    return AppVersion(String(name.dropFirst(6)))
  }
  func installer() throws -> Asset {
    guard let version else {throw UpdateError.invalidRelease}
    let candidates=["Atmos-\(version).dmg","Atmos.dmg"]
    guard let asset=candidates.compactMap({name in assets.first{$0.name==name}}).first,
      asset.size>0,asset.size<=UpdateFiles.maximumDownload,Self.isOfficialAsset(asset.browserDownloadURL)
    else {throw UpdateError.missingInstaller}
    return asset
  }
  static func isOfficialAsset(_ url:URL)->Bool {
    url.scheme=="https" && url.host?.lowercased()=="github.com" && url.user==nil && url.password==nil
      && (url.port==nil || url.port==443)
      && url.path.lowercased().hasPrefix("/scott-g-robb/atmos/releases/download/")
  }
}

enum UpdateError: LocalizedError, Equatable {
  case invalidRelease,missingInstaller,network(Int),badChecksum,invalidApp,wrongPublisher,unsupportedInstall,installFailed,cancelled
  var errorDescription:String? {
    switch self {
    case .invalidRelease:"The latest release could not be read. Please try again later."
    case .missingInstaller:"This release does not include a compatible Atmos installer."
    case .network(let code):code==403 || code==429 ? "GitHub is busy. Please try again in a few minutes." : "GitHub could not be reached. Please try again."
    case .badChecksum:"The download could not be verified. Your current Atmos is unchanged."
    case .invalidApp:"The downloaded app is not a compatible Atmos update. Your current app is unchanged."
    case .wrongPublisher:"The update's signature does not match Atmos's publisher. Your current app is unchanged."
    case .unsupportedInstall:"Move Atmos into Applications before installing an update."
    case .installFailed:"The update could not be installed. Your current Atmos is unchanged."
    case .cancelled:"The update was cancelled."
    }
  }
}

struct GitHubUpdates {
  static let latestURL=URL(string:"https://api.github.com/repos/scott-g-robb/Atmos/releases/latest")!
  static let releasesURL=URL(string:"https://github.com/scott-g-robb/Atmos/releases")!
  let session:URLSession
  init(session:URLSession = URLSession(configuration:.ephemeral)) {self.session=session}
  func latest() async throws -> GitHubRelease {
    var request=URLRequest(url:Self.latestURL,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:25)
    request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
    request.setValue("Atmos-Updater",forHTTPHeaderField:"User-Agent")
    let (data,response)=try await session.data(for:request)
    guard let response=response as? HTTPURLResponse,response.statusCode==200 else {
      throw UpdateError.network((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    guard data.count<2_000_000 else {throw UpdateError.invalidRelease}
    guard let release=try? JSONDecoder().decode(GitHubRelease.self,from:data),release.version != nil else {throw UpdateError.invalidRelease}
    return release
  }
  func expectedHash(for asset:GitHubRelease.Asset,in release:GitHubRelease) async throws -> String {
    if let digest=asset.sha256 {return digest}
    guard let checksum=release.assets.first(where:{$0.name==asset.name+".sha256"}),
      checksum.size>0,checksum.size<16_384,GitHubRelease.isOfficialAsset(checksum.browserDownloadURL) else {throw UpdateError.badChecksum}
    let (data,response)=try await session.data(from:checksum.browserDownloadURL)
    guard (response as? HTTPURLResponse)?.statusCode==200,data.count<16_384,
      let text=String(data:data,encoding:.utf8),let hash=text.split(whereSeparator:{$0.isWhitespace}).first,
      UpdateFiles.isSHA256(String(hash)) else {throw UpdateError.badChecksum}
    return hash.lowercased()
  }
}

/// No persistent background updater, account, token or third-party runtime.
final class UpdateDownload:NSObject,URLSessionDownloadDelegate,URLSessionTaskDelegate,@unchecked Sendable {
  private var continuation:CheckedContinuation<Void,Error>?
  private var session:URLSession?
  private let taskLock=NSLock()
  private var taskStorage:URLSessionDownloadTask?
  private var task:URLSessionDownloadTask? {
    get {taskLock.lock();defer{taskLock.unlock()};return taskStorage}
    set {taskLock.lock();taskStorage=newValue;taskLock.unlock()}
  }
  private let destination:URL
  private let progress:(Double,Int64,Int64)->Void
  private var failure:Error?
  init(destination:URL,progress:@escaping(Double,Int64,Int64)->Void) {self.destination=destination;self.progress=progress}
  func download(_ asset:GitHubRelease.Asset) async throws {
    try await withTaskCancellationHandler(operation:{
      try await withCheckedThrowingContinuation { continuation in
        self.continuation=continuation
        let config=URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest=45;config.timeoutIntervalForResource=900
        let queue=OperationQueue();queue.maxConcurrentOperationCount=1
        queue.name="Atmos.update.download"
        session=URLSession(configuration:config,delegate:self,delegateQueue:queue)
        task=session!.downloadTask(with:asset.browserDownloadURL)
        task?.resume()
        if Task.isCancelled {task?.cancel()}
      }
    },onCancel:{self.task?.cancel()})
  }
  func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64) {
    if totalBytesWritten>UpdateFiles.maximumDownload {failure=UpdateError.invalidApp;downloadTask.cancel();return}
    let fraction=totalBytesExpectedToWrite>0 ? Double(totalBytesWritten)/Double(totalBytesExpectedToWrite) : 0
    DispatchQueue.main.async {self.progress(fraction,totalBytesWritten,totalBytesExpectedToWrite)}
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
    let allowed=["github.com","release-assets.githubusercontent.com","objects.githubusercontent.com"]
    let valid=request.url.map{$0.scheme=="https" && allowed.contains($0.host?.lowercased() ?? "") && $0.user==nil && $0.password==nil} ?? false
    completionHandler(valid ? request : nil)
  }
  func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL) {
    do {
      guard (downloadTask.response as? HTTPURLResponse)?.statusCode==200 else {throw UpdateError.network((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)}
      try FileManager.default.moveItem(at:location,to:destination)
    } catch {failure=error}
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
    let continuation=self.continuation;self.continuation=nil
    if let error=failure ?? error {continuation?.resume(throwing:error)}
    else if !FileManager.default.fileExists(atPath:destination.path) {continuation?.resume(throwing:UpdateError.network(0))}
    else {continuation?.resume()}
    session.finishTasksAndInvalidate();self.session=nil;self.task=nil
  }
}

enum UpdateFiles {
  static let maximumDownload:Int64=512*1024*1024
  static func isSHA256(_ text:String)->Bool {text.utf8.count==64 && text.lowercased().utf8.allSatisfy{48...57 ~= $0 || 97...102 ~= $0}}
  static func hash(_ file:URL) throws -> String {
    let handle=try FileHandle(forReadingFrom:file);defer {try? handle.close()}
    var hasher=SHA256()
    while let data=try handle.read(upToCount:1024*1024),!data.isEmpty {hasher.update(data:data)}
    return hasher.finalize().map{String(format:"%02x",$0)}.joined()
  }
  static func signingRequirement(for app:URL) throws -> String {
    var code:SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL,[],&code)==errSecSuccess,let code else {throw UpdateError.wrongPublisher}
    var info:CFDictionary?
    guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
      let data=info as? [String:Any],let team=data[kSecCodeInfoTeamIdentifier as String] as? String,
      !team.isEmpty,team.utf8.allSatisfy({48...57 ~= $0 || 65...90 ~= $0}),
      let identifier=data[kSecCodeInfoIdentifier as String] as? String,
      identifier.utf8.allSatisfy({48...57 ~= $0 || 65...90 ~= $0 || 97...122 ~= $0 || $0==46 || $0==45})
    else {throw UpdateError.wrongPublisher}
    return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
  }
  static func validate(_ app:URL,against installed:URL,version:AppVersion) throws -> String {
    let infoURL=app.appendingPathComponent("Contents/Info.plist")
    guard (try? app.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true,
      let info=try PropertyListSerialization.propertyList(from:Data(contentsOf:infoURL),format:nil) as? [String:Any],
      let current=Bundle(url:installed)?.bundleIdentifier,
      info["CFBundleIdentifier"] as? String==current,
      info["CFBundleShortVersionString"] as? String==version.description,
      info["CFBundleExecutable"] as? String=="Atmos" else {throw UpdateError.invalidApp}
    if let minimum=info["LSMinimumSystemVersion"] as? String {
      let components=minimum.split(separator:".").compactMap{Int($0)}
      let os=ProcessInfo.processInfo.operatingSystemVersion
      guard components.count>=2,components.count<=3,
        [components[0],components[1],components.count==3 ? components[2]:0].lexicographicallyPrecedes([os.majorVersion,os.minorVersion,os.patchVersion])
          || components==[os.majorVersion,os.minorVersion] || components==[os.majorVersion,os.minorVersion,os.patchVersion]
      else {throw UpdateError.invalidApp}
    }
    let requirement=try signingRequirement(for:installed)
    var expected:SecRequirement?,code:SecStaticCode?
    guard SecRequirementCreateWithString(requirement as CFString,[],&expected)==errSecSuccess,
      SecStaticCodeCreateWithPath(app as CFURL,[],&code)==errSecSuccess,let code,
      SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate|kSecCSCheckAllArchitectures),expected)==errSecSuccess
    else {throw UpdateError.wrongPublisher}
    return requirement
  }
  static func run(_ executable:String,_ arguments:[String]) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      let process=Process(),output=Pipe()
      process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments
      process.standardOutput=output;process.standardError=FileHandle.nullDevice
      process.terminationHandler={process in
        let data=output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus==0 {continuation.resume(returning:data)} else {continuation.resume(throwing:UpdateError.installFailed)}
      }
      do {try process.run()} catch {continuation.resume(throwing:error)}
    }
  }
  static func prepare(image:URL,in workspace:URL,installed:URL,version:AppVersion) async throws -> (app:URL,requirement:String) {
    let mount=workspace.appendingPathComponent("mounted",isDirectory:true)
    try FileManager.default.createDirectory(at:mount,withIntermediateDirectories:true)
    _=try await run("/usr/bin/hdiutil",["attach",image.path,"-readonly","-nobrowse","-noautoopen","-mountpoint",mount.path,"-plist"])
    let app=workspace.appendingPathComponent("Atmos.app",isDirectory:true)
    do {
      let source=mount.appendingPathComponent("Atmos.app",isDirectory:true)
      guard source.resolvingSymlinksInPath().deletingLastPathComponent()==mount.resolvingSymlinksInPath() else {throw UpdateError.invalidApp}
      try FileManager.default.copyItem(at:source,to:app)
      let requirement=try validate(app,against:installed,version:version)
      #if arch(arm64)
      let arch="arm64"
      #else
      let arch="x86_64"
      #endif
      _=try await run("/usr/bin/lipo",[app.appendingPathComponent("Contents/MacOS/Atmos").path,"-verify_arch",arch])
      _=try await run("/usr/bin/hdiutil",["detach",mount.path,"-quiet"])
      return (app,requirement)
    } catch {
      _=try? await run("/usr/bin/hdiutil",["detach",mount.path,"-quiet"])
      throw error
    }
  }
  static func shellQuote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
  static func appleScriptQuote(_ text:String)->String {"\""+text.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""}

  /// Stage and validate before quitting. The short-lived child swaps siblings on
  /// the same filesystem, restores the previous app on failure, and then exits.
  static let swapScript="""
    atmos_swap() {
      /bin/mv "$1" "$3" || return 1
      if /bin/mv "$2" "$1"; then return 0; fi
      /bin/mv "$3" "$1"
      return 1
    }
    """
  static let installScript="""
    set -eu
    umask 077
    \(swapScript)
    pid="$1"; source="$2"; destination="$3"; prepared="$4"; backup="$5"; requirement="$6"; uid="$7"; version="$8"
    mode="${9:-manual}"
    other_pids="${10:-}"
    trap '/bin/rm -rf "$prepared"' EXIT
    /usr/bin/ditto --rsrc --extattr "$source" "$prepared"
    if ! /usr/bin/codesign --verify --deep --strict --all-architectures -R "=$requirement" "$prepared"; then /bin/rm -rf "$prepared"; exit 1; fi
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$prepared/Contents/Info.plist")" != "$version" ]; then /bin/rm -rf "$prepared"; exit 1; fi
    (
      trap '' HUP
      attempts=0
      while :; do
        running=false
        for old_pid in "$pid" $other_pids; do
          case "$old_pid" in ''|*[!0-9]*) exit 1;; esac
          if [ "$old_pid" -gt 0 ] && /bin/kill -0 "$old_pid" 2>/dev/null; then running=true; fi
        done
        if [ "$running" = false ]; then break; fi
        attempts=$((attempts+1)); if [ "$attempts" -gt 600 ]; then /bin/rm -rf "$prepared"; exit 1; fi
        /bin/sleep 0.1
      done
      reopen() {
        if [ "$mode" = automatic ]; then /usr/bin/open -g -n "$destination" --args --atmos-auto-update;
        elif [ "$(/usr/bin/id -u)" = "$uid" ]; then /usr/bin/open -n "$destination";
        else /bin/launchctl asuser "$uid" /usr/bin/sudo -u "#$uid" /usr/bin/open -n "$destination"; fi
      }
      if ! atmos_swap "$destination" "$prepared" "$backup"; then /bin/rm -rf "$prepared"; reopen || true; exit 1; fi
      if reopen; then /bin/rm -rf "$backup";
      else
        /bin/rm -rf "$destination"
        /bin/mv "$backup" "$destination"
        reopen || true
      fi
    ) </dev/null >/dev/null 2>&1 &
    trap - EXIT
    """
  static func scheduleInstall(app:URL,destination:URL,requirement:String,version:AppVersion,automatic:Bool=false) async throws {
    let destination=destination.resolvingSymlinksInPath(),parent=destination.deletingLastPathComponent()
    guard destination.pathExtension=="app",!destination.path.hasPrefix("/Volumes/"),
      !destination.path.contains("/AppTranslocation/"),
      (try? parent.resourceValues(forKeys:[.volumeIsReadOnlyKey]).volumeIsReadOnly) != true
    else {throw UpdateError.unsupportedInstall}
    let nonce=UUID().uuidString
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.grobb.Atmos")
      .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        && $0.bundleURL?.resolvingSymlinksInPath() == destination }
    let args=[String(ProcessInfo.processInfo.processIdentifier),app.path,destination.path,
      parent.appendingPathComponent(".Atmos-update-\(nonce).app").path,
      parent.appendingPathComponent(".Atmos-previous-\(nonce).app").path,requirement,String(getuid()),version.description,automatic ? "automatic":"manual",others.map { String($0.processIdentifier) }.joined(separator: " ")]
    for old in others { old.terminate() }
    if FileManager.default.isWritableFile(atPath:parent.path) {
      _=try await run("/bin/sh",["-c",installScript,"Atmos-update"]+args)
    } else {
      guard !automatic else { throw UpdateError.unsupportedInstall }
      let command=(["/bin/sh","-c",installScript,"Atmos-update"]+args).map(shellQuote).joined(separator:" ")
      _=try await run("/usr/bin/osascript",["-e","do shell script \(appleScriptQuote(command)) with administrator privileges"])
    }
  }
}
