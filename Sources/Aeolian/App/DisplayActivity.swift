/// Full-screen suspension is event driven. A covered display gets neither animation frames nor window polling.
struct DisplayActivity {
  let renders: Bool
  let pollsWindows: Bool
  init(awake: Bool, fullScreen: Bool, visible: Bool, fading: Bool) {
    renders = awake && (!fullScreen || fading) && (visible || fading)
    pollsWindows = awake && !fullScreen
  }
}
