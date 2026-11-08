import AVFAudio
import Foundation

/// The welcome owns playback, so silent updates and ordinary launches never
/// play an intro. Navigating between setup pages does not restart the clip.
final class WelcomeAudio {
  private var player: AVAudioPlayer?
  private var stopping: Task<Void, Never>?
  private var played = false
  func play() {
    guard !played, let url=Bundle.main.url(forResource:"IntroAudio",withExtension:"mp3"),
      let sound=try? AVAudioPlayer(contentsOf:url) else { return }
    sound.prepareToPlay();sound.numberOfLoops=0
    if sound.play() {player=sound;played=true}
  }
  func stop() {
    guard let sound=player,stopping==nil else {return}
    sound.setVolume(0,fadeDuration:0.15)
    stopping=Task { @MainActor in
      try? await Task.sleep(nanoseconds:170_000_000)
      sound.stop()
    }
    player=nil
  }
  deinit {player?.stop()}
}
