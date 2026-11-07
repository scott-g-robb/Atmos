import AppKit

/// Opened straight from the downloaded disk image, Atmos copies itself to Applications,
/// ejects the image and starts again from there, so it never runs from a volume that goes away.
enum AppMover {
  /// Returns true when a copy in Applications is about to start and this instance should quit.
  static func moveIfNeeded() -> Bool {
    guard let source = originalBundleURL(), source.path.hasPrefix("/Volumes/") else { return false }
    let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
      .appendingPathComponent(source.lastPathComponent)
    let files = FileManager.default
    guard files.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { return false }
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.grobb.Atmos")
      .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        && $0.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() }
    let pids = ([ProcessInfo.processInfo.processIdentifier] + others.map(\.processIdentifier)).map(String.init).joined(separator: " ")
    let volume = (try? source.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? ""
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", installScript, "Atmos-manual-install", source.path, destination.path, volume, pids, UUID().uuidString]
    do { try process.run() } catch { return false }
    // The helper cannot touch the installed bundle until this instance and every
    // existing installed instance have exited. Finder/DMG installs stay manual.
    for old in others { old.terminate() }
    return true
  }

  static let installScript = """
    set -eu
    umask 077
    trap '' HUP
    source="$1"; destination="$2"; volume="$3"; pids="$4"
    prepared="${destination%/*}/.Atmos-manual-$5.app"
    backup="${destination%/*}/.Atmos-previous-$5.app"
    attempts=0
    while :; do
      running=false
      for pid in $pids; do
        case "$pid" in ''|*[!0-9]*) exit 1;; esac
        if [ "$pid" -gt 0 ] && /bin/kill -0 "$pid" 2>/dev/null; then running=true; fi
      done
      if [ "$running" = false ]; then break; fi
      attempts=$((attempts+1)); if [ "$attempts" -gt 600 ]; then exit 1; fi
      /bin/sleep 0.1
    done
    trap '/bin/rm -rf "$prepared"' EXIT
    if ! /usr/bin/ditto --rsrc --extattr "$source" "$prepared"; then /usr/bin/open "$destination"; exit 1; fi
    if [ -e "$destination" ]; then
      if ! /bin/mv "$destination" "$backup"; then /usr/bin/open "$destination"; exit 1; fi
    fi
    if ! /bin/mv "$prepared" "$destination"; then
      if [ -e "$backup" ]; then /bin/mv "$backup" "$destination"; fi
      /usr/bin/open "$destination"; exit 1
    fi
    /bin/rm -rf "$backup"
    if [ -n "$volume" ]; then
      for attempt in 1 2 3 4 5 6 7 8; do /usr/bin/hdiutil detach "$volume" -quiet 2>/dev/null && break; /bin/sleep 0.5; done
    fi
    /usr/bin/open -n "$destination"
    """

  /// Where the bundle really lives: macOS runs apps opened from a downloaded image from a randomized copy.
  private static func originalBundleURL() -> URL? {
    let url = Bundle.main.bundleURL
    typealias Original =
      @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
    guard url.path.contains("/AppTranslocation/"),
      let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
      let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
    else { return url }
    let original = unsafeBitCast(symbol, to: Original.self)
    return original(url as CFURL, nil)?.takeRetainedValue() as URL? ?? url
  }

}
