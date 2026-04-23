import Speech
import AVFoundation
import Foundation

// Continuous speech-to-text using macOS SFSpeechRecognizer (same engine as Siri).
// Prints one finalized transcript per line to stdout.
// Built-in utterance boundary detection — no external VAD needed.
// Restarts automatically after each phrase.

func requestPermissions(completion: @escaping (Bool) -> Void) {
    SFSpeechRecognizer.requestAuthorization { status in
        guard status == .authorized else {
            fputs("error: speech recognition permission denied — grant in System Settings → Privacy → Speech Recognition\n", stderr)
            completion(false)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                fputs("error: microphone permission denied — grant in System Settings → Privacy → Microphone\n", stderr)
            }
            completion(granted)
        }
    }
}

class ContinuousListener {
    private let recognizer: SFSpeechRecognizer
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restarting = false
    private var silenceTimer: DispatchWorkItem?
    private let silenceDelay: Double = 1.5  // seconds of silence → emit transcript
    private var lastPartial = ""

    init() {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              r.isAvailable else {
            fputs("error: SFSpeechRecognizer unavailable for en-US\n", stderr)
            exit(1)
        }
        self.recognizer = r
    }

    func start() {
        guard !restarting else { return }

        request = SFSpeechAudioBufferRecognitionRequest()
        guard let req = request else { return }

        // Prefer on-device (macOS 13+) but fall back to server if model not downloaded
        if #available(macOS 13, *) {
            req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }
        req.shouldReportPartialResults = true   // debug: log partials too
        req.taskHint = .dictation

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }

                self.lastPartial = text
                fputs("partial: \(text)\n", stderr)
                fflush(stderr)

                // Reset silence timer — emit transcript after 1.5s of no new partials
                self.silenceTimer?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self = self, !self.lastPartial.isEmpty else { return }
                    let transcript = self.lastPartial
                    self.lastPartial = ""
                    print(transcript)   // → Python reads this on stdout
                    fflush(stdout)
                    self.scheduleRestart()
                }
                self.silenceTimer = item
                DispatchQueue.main.asyncAfter(deadline: .now() + self.silenceDelay, execute: item)
                return
            }

            if let error = error {
                let code = (error as NSError).code
                // 203 = cancelled by our own restart — ignore
                if code != 203 {
                    fputs("recognition code=\(code): \(error.localizedDescription)\n", stderr)
                }
                if !self.restarting {
                    self.scheduleRestart()
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            fputs("error: audio engine failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private func scheduleRestart() {
        guard !restarting else { return }
        restarting = true
        silenceTimer?.cancel()
        silenceTimer = nil
        lastPartial = ""
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        // Brief pause before restarting to let the audio subsystem settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.restarting = false
            self?.start()
        }
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

// Global retain — prevents ARC from deallocating listener while run loop is active
var gListener: ContinuousListener?

fputs("stt_listen: requesting permissions\n", stderr)

requestPermissions { granted in
    guard granted else { exit(1) }
    DispatchQueue.main.async {
        let listener = ContinuousListener()
        gListener = listener   // keep alive for duration of process
        listener.start()
        fputs("stt_listen: ready — speak to transcribe\n", stderr)
    }
}

RunLoop.main.run()
