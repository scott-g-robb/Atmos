import AVFAudio
import Foundation
import QuartzCore

/// The welcome owns playback, so silent updates and ordinary launches never
/// play an intro. Navigating between setup pages does not restart the clip.
final class WelcomeAudio {
  private var player: AVAudioPlayer?
  private var stopping: Task<Void, Never>?
  private var played = false
  /// Audio and Core Animation share a future start, after decoding/preparation.
  @discardableResult func play() -> CFTimeInterval {
    guard !played, let url=Bundle.main.url(forResource:"IntroAudio",withExtension:"mp3"),
      let sound=try? AVAudioPlayer(contentsOf:url) else { return CACurrentMediaTime()+0.12 }
    sound.prepareToPlay();sound.numberOfLoops=0
    let start=CACurrentMediaTime()+0.12
    if sound.play(atTime:sound.deviceCurrentTime+0.12) {player=sound;played=true}
    return start
  }
  func stop() {
    guard let sound=player,stopping==nil else {return}
    sound.setVolume(0,fadeDuration:0.35)
    stopping=Task { @MainActor in
      try? await Task.sleep(nanoseconds:380_000_000)
      sound.stop()
    }
    player=nil
  }
  deinit {player?.stop()}
}
