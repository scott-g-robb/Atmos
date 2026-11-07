import AppKit
import XCTest
@testable import Atmos

private final class UpdateURLProtocol:URLProtocol {
  static var reply:(URLRequest)throws->(Int,Data) = {_ in (500,Data())}
  override class func canInit(with request:URLRequest)->Bool {true}
  override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
  override func startLoading() {
    do {
      let (status,data)=try Self.reply(request)
      client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
      client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    } catch {client?.urlProtocol(self,didFailWithError:error)}
  }
  override func stopLoading() {}
}

final class Update57Tests:XCTestCase {
  private let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private func release(_ name:String="Atmos 0.14.2",draft:Bool=false,prerelease:Bool=false,asset:String="Atmos-0.14.2.dmg",digest:String?=nil,url:String?=nil) throws -> Data {
    var a:[String:Any]=["name":asset,"size":100,"browser_download_url":url ?? "https://github.com/scott-g-robb/Atmos/releases/download/Experimental/\(asset)"]
    a["digest"]=digest
    return try JSONSerialization.data(withJSONObject:["name":name,"draft":draft,"prerelease":prerelease,"tag_name":"Experimental","assets":[a]])
  }
  private func service()->GitHubUpdates {
    let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[UpdateURLProtocol.self]
    return GitHubUpdates(session:URLSession(configuration:config))
  }
  func testVersionsUseNumericComponentsAndInvalidOrUnstableReleaseNamesAreRejected() throws {
    XCTAssertGreaterThan(AppVersion("0.14.10")!,AppVersion("0.14.9")!)
    XCTAssertGreaterThan(AppVersion("1.0.0")!,AppVersion("0.99.99")!)
    for value in ["v1.2.3","1.2","1.2.3.4","1.-2.3","1.2.3-beta","1.2.x",""] {XCTAssertNil(AppVersion(value))}
    for (name,draft,prerelease) in [("Atmos 0.14.2",true,false),("Atmos 0.14.2",false,true),("Other App 0.14.2",false,false),("Atmos 0.14.2 beta",false,false)] {
      let candidate=try JSONDecoder().decode(GitHubRelease.self,from:release(name,draft:draft,prerelease:prerelease))
      XCTAssertNil(candidate.version)
    }
  }
  func testLatestUsesTheReleaseNameEvenWhenTheTagIsExperimentalAndSelectsOnlyAtmosDMG() async throws {
    let fixture=try release()
    UpdateURLProtocol.reply={request in
      XCTAssertEqual(request.url,GitHubUpdates.latestURL)
      XCTAssertEqual(request.value(forHTTPHeaderField:"Accept"),"application/vnd.github+json")
      return (200,fixture)
    }
    let latest=try await service().latest()
    XCTAssertEqual(latest.version,AppVersion("0.14.2"))
    XCTAssertEqual(try latest.installer().name,"Atmos-0.14.2.dmg")
    for name in ["Atmos-source.zip","Other.dmg","Atmos-0.14.1.dmg"] {
      let invalid=try JSONDecoder().decode(GitHubRelease.self,from:release(asset:name))
      XCTAssertThrowsError(try invalid.installer())
    }
  }
  func testFailedChecksNeverReportThatTheAppIsUpToDateAndNoForeignAssetIsAccepted() async throws {
    for status in [403,404,429,500] {
      UpdateURLProtocol.reply={_ in (status,Data())}
      do {_=try await service().latest();XCTFail("HTTP \(status) must fail")} catch {XCTAssertEqual(error as? UpdateError,.network(status))}
    }
    UpdateURLProtocol.reply={_ in (200,Data("not a release".utf8))}
    do {_=try await service().latest();XCTFail("Malformed release must fail")} catch {XCTAssertEqual(error as? UpdateError,.invalidRelease)}
    for url in ["http://github.com/scott-g-robb/Atmos/releases/download/v1/Atmos.dmg","https://github.com.evil.example/scott-g-robb/Atmos/releases/download/v1/Atmos.dmg","https://github.com/other/Atmos/releases/download/v1/Atmos.dmg","https://user@github.com/scott-g-robb/Atmos/releases/download/v1/Atmos.dmg"] {
      XCTAssertFalse(GitHubRelease.isOfficialAsset(URL(string:url)!))
    }
  }
  func testDigestAndCompanionChecksumValidation() async throws {
    let hash=String(repeating:"a",count:64)
    var latest=try JSONDecoder().decode(GitHubRelease.self,from:release(digest:"sha256:"+hash))
    let directHash=try await service().expectedHash(for:latest.installer(),in:latest)
    XCTAssertEqual(directHash,hash)
    let payload:[String:Any]=["name":"Atmos 0.14.2","draft":false,"prerelease":false,"assets":[
      ["name":"Atmos.dmg","size":100,"browser_download_url":"https://github.com/scott-g-robb/Atmos/releases/download/v0.14.2/Atmos.dmg"],
      ["name":"Atmos.dmg.sha256","size":100,"browser_download_url":"https://github.com/scott-g-robb/Atmos/releases/download/v0.14.2/Atmos.dmg.sha256"]]]
    latest=try JSONDecoder().decode(GitHubRelease.self,from:JSONSerialization.data(withJSONObject:payload))
    UpdateURLProtocol.reply={_ in (200,Data((hash+"  dist/Atmos.dmg\n").utf8))}
    let companionHash=try await service().expectedHash(for:latest.installer(),in:latest)
    XCTAssertEqual(companionHash,hash)
    UpdateURLProtocol.reply={_ in (200,Data("incorrect checksum".utf8))}
    do {_=try await service().expectedHash(for:latest.installer(),in:latest);XCTFail("Bad checksum must fail")} catch {XCTAssertEqual(error as? UpdateError,.badChecksum)}
  }
  func testHashingAndShellArgumentsPreserveLiteralCharacters() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    let file=directory.appendingPathComponent("data")
    try Data("abc".utf8).write(to:file)
    XCTAssertEqual(try UpdateFiles.hash(file),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let tricky="Atmos' $(touch should-not-exist) \"quoted\" \\ tab\t"
    let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/bin/sh")
    process.arguments=["-c","printf '%s' "+UpdateFiles.shellQuote(tricky)];process.standardOutput=pipe
    try process.run();process.waitUntilExit()
    XCTAssertEqual(String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8),tricky)
    XCTAssertEqual(process.terminationStatus,0)
  }
  func testAtomicSwapPreservesTheOldAppIfTheNewRenameFails() async throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    let current=directory.appendingPathComponent("Atmos 'current'.app"),next=directory.appendingPathComponent("next.app"),backup=directory.appendingPathComponent("previous.app")
    try Data("old app".utf8).write(to:current)
    let script=UpdateFiles.swapScript+"\natmos_swap \"$1\" \"$2\" \"$3\""
    do {_=try await UpdateFiles.run("/bin/sh",["-c",script,"test",current.path,next.path,backup.path]);XCTFail("Missing staged app must fail")} catch {}
    XCTAssertEqual(try String(contentsOf:current),"old app")
    try Data("new app".utf8).write(to:next)
    _=try await UpdateFiles.run("/bin/sh",["-c",script,"test",current.path,next.path,backup.path])
    XCTAssertEqual(try String(contentsOf:current),"new app")
    XCTAssertEqual(try String(contentsOf:backup),"old app")
    _=try await UpdateFiles.run("/bin/sh",["-n","-c",UpdateFiles.installScript])
  }
  func testSignedAppValidationRejectsModifiedMetadataAndForeignSignatures() throws {
    let installed=root.appendingPathComponent("build/Atmos.app")
    guard let bundle=Bundle(url:installed),let version=bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {throw XCTSkip("Build the signed app for package validation")}
    _=try UpdateFiles.validate(installed,against:installed,version:AppVersion(version)!)
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    let altered=directory.appendingPathComponent("Atmos.app");try FileManager.default.copyItem(at:installed,to:altered)
    let path=altered.appendingPathComponent("Contents/Info.plist")
    var info=try PropertyListSerialization.propertyList(from:Data(contentsOf:path),format:nil) as! [String:Any]
    info["CFBundleIdentifier"]="other.publisher.App"
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:path)
    XCTAssertThrowsError(try UpdateFiles.validate(altered,against:installed,version:AppVersion(version)!))
    info["CFBundleIdentifier"]=bundle.bundleIdentifier
    info["CFBundleName"]="Tampered unsigned payload"
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:path)
    XCTAssertThrowsError(try UpdateFiles.validate(altered,against:installed,version:AppVersion(version)!))
  }
  func testCancelledDownloadFinishesWithoutCreatingAnInstaller() async throws {
    let fixture=try JSONDecoder().decode(GitHubRelease.self,from:release())
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    let output=directory.appendingPathComponent("Atmos.dmg")
    let download=UpdateDownload(destination:output,progress:{_,_,_ in})
    let operation=Task {try await download.download(fixture.installer())}
    operation.cancel()
    do {try await operation.value;XCTFail("Cancellation must not report a finished download")}
    catch {XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)}
    XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
  }
  func testPostExitHelperInstallsAndReopensAnIsolatedSignedFixture() async throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("Atmos-swap-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    let source=directory.appendingPathComponent("Source.app"),destination=directory.appendingPathComponent("Current.app")
    let executable=source.appendingPathComponent("Contents/MacOS/Fixture")
    try FileManager.default.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true)
    let receipt=directory.appendingPathComponent("reopened")
    let escaped=receipt.path.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
    let code=directory.appendingPathComponent("fixture.c")
    try "#include <stdio.h>\nint main(int argc,char**argv){FILE*f=fopen(\"\(escaped)\",\"w\");if(f){fputs(\"new version opened\",f);for(int i=1;i<argc;i++)fputs(argv[i],f);fclose(f);}return 0;}".write(to:code,atomically:true,encoding:.utf8)
    _=try await UpdateFiles.run("/usr/bin/clang",[code.path,"-o",executable.path])
    let identifier="dev.atmos.UpdateFixture"
    let info:[String:Any]=["CFBundleIdentifier":identifier,"CFBundleExecutable":"Fixture","CFBundlePackageType":"APPL","CFBundleShortVersionString":"2.0.0","CFBundleVersion":"2","LSBackgroundOnly":true]
    try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:source.appendingPathComponent("Contents/Info.plist"))
    _=try await UpdateFiles.run("/usr/bin/codesign",["--force","--sign","-",source.path])
    try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
    let marker=destination.appendingPathComponent("old-version")
    try Data("old".utf8).write(to:marker)
    let oldProcess=Process();oldProcess.executableURL=URL(fileURLWithPath:"/bin/sleep");oldProcess.arguments=["30"];oldProcess.terminationHandler={_ in};try oldProcess.run()
    let otherProcess=Process();otherProcess.executableURL=URL(fileURLWithPath:"/bin/sleep");otherProcess.arguments=["30"];otherProcess.terminationHandler={_ in};try otherProcess.run()
    let staged=directory.appendingPathComponent("staged.app"),backup=directory.appendingPathComponent("backup.app")
    _=try await UpdateFiles.run("/bin/sh",["-c",UpdateFiles.installScript,"fixture",String(oldProcess.processIdentifier),source.path,destination.path,staged.path,backup.path,"identifier \"\(identifier)\"",String(getuid()),"2.0.0","manual",String(otherProcess.processIdentifier)])
    XCTAssertTrue(oldProcess.isRunning)
    XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path),"The active app must be untouched while any previous instance runs")
    XCTAssertFalse(FileManager.default.fileExists(atPath:destination.appendingPathComponent("Contents/MacOS/Fixture").path))
    oldProcess.terminate()
    try await Task.sleep(nanoseconds:150_000_000)
    XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path),"Another running instance must also exit before replacement")
    otherProcess.terminate()
    let deadline=Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath:receipt.path),Date()<deadline {try await Task.sleep(nanoseconds:50_000_000)}
    XCTAssertEqual(try String(contentsOf:receipt),"new version opened")
    XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath:destination.appendingPathComponent("Contents/MacOS/Fixture").path))
    try FileManager.default.removeItem(at:receipt)
    let autoParent=Process();autoParent.executableURL=URL(fileURLWithPath:"/bin/sleep");autoParent.arguments=["0.2"];try autoParent.run()
    _=try await UpdateFiles.run("/bin/sh",["-c",UpdateFiles.installScript,"fixture",String(autoParent.processIdentifier),source.path,destination.path,staged.path,backup.path,"identifier \"\(identifier)\"",String(getuid()),"2.0.0","automatic"])
    let autoDeadline=Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath:receipt.path),Date()<autoDeadline {try await Task.sleep(nanoseconds:50_000_000)}
    XCTAssertTrue(try String(contentsOf:receipt).contains("--atmos-auto-update"))
  }
  func testPublishedGitHubDownloadAndSignatureWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["ATMOS_TEST_GITHUB"]=="1" else {throw XCTSkip("Set ATMOS_TEST_GITHUB for the live release download check")}
    let service=GitHubUpdates(),latest=try await service.latest(),asset=try latest.installer()
    let hash=try await service.expectedHash(for:asset,in:latest)
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("Atmos-update-check-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    let image=directory.appendingPathComponent("Atmos.dmg")
    let downloader=UpdateDownload(destination:image,progress:{_,_,_ in})
    try await downloader.download(asset)
    XCTAssertEqual(try UpdateFiles.hash(image),hash)
    let prepared=try await UpdateFiles.prepare(image:image,in:directory,installed:root.appendingPathComponent("build/Atmos.app"),version:latest.version!)
    XCTAssertTrue(FileManager.default.fileExists(atPath:prepared.app.path))
  }
  @MainActor func testUpdatePromptAndProgressUseTheSharedAtmosStyle() throws {
    let artwork=NSImage(contentsOf:root.appendingPathComponent("Resources/AppIcon.icon/Assets/Weather.png"))!
    let panel=UpdatePanel(icon:artwork);defer{panel.close()}
    for progress in [false,true] {
      panel.show(title:progress ? "Downloading Atmos 0.14.2":"Atmos 0.14.2 is available",
        detail:progress ? "Your atmosphere will be ready in a moment.":"You're using Atmos 0.14.1. Download and install the latest version?",
        primary:progress ? "":"Download & Install",secondary:progress ? "Cancel":"Not Now",working:progress)
      if progress {panel.setProgress(0.42,written:3_200_000,total:7_600_000)}
      let window=try XCTUnwrap(NSApp.windows.first{$0.title=="Atmos Updates" && $0.isVisible}),view=try XCTUnwrap(window.contentView)
      view.layoutSubtreeIfNeeded()
      XCTAssertTrue(view.subviews.contains{$0 is AtmosPanelSurface})
      if let output=ProcessInfo.processInfo.environment["ATMOS_RENDER_DIR"] {
        try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
        let rep=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:rep)
        try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output).appendingPathComponent(progress ? "update-download.png":"update-offer.png"))
      }
    }
  }
}
