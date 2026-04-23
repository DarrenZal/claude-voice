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

        // On-device only — no audio sent to Apple servers
        if #available(macOS 13, *) {
            req.requiresOnDeviceRecognition = true
        }
        req.shouldReportPartialResults = false
        req.taskHint = .dictation

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result, result.isFinal {
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    print(text)  // one transcript per line → Python reads this
                    fflush(stdout)
                }
                self.scheduleRestart()
                return
            }

            if let error = error {
                let code = (error as NSError).code
                // 301 = no speech detected (normal timeout), 203 = cancelled (our restart), 1110 = no match
                if code != 301 && code != 203 && code != 1110 {
                    fputs("warn: recognition error \(code): \(error.localizedDescription)\n", stderr)
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
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
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

fputs("stt_listen: requesting permissions\n", stderr)

requestPermissions { granted in
    guard granted else { exit(1) }
    DispatchQueue.main.async {
        let listener = ContinuousListener()
        listener.start()
        fputs("stt_listen: ready — speak to transcribe\n", stderr)
    }
}

RunLoop.main.run()
