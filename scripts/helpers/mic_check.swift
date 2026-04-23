import AVFoundation

// Exit 1 if microphone is in use by another application, 0 if free.
// Used by mic_watcher.py to detect active calls.
let device = AVCaptureDevice.default(for: .audio)
exit(device?.isInUseByAnotherApplication == true ? 1 : 0)
