import Foundation
import UIKit
import AVFoundation
import Speech
import SwiftSignalKit

// Speech recognizer for reminder notes. The recognizer cannot detect the language itself, so it listens in the
// language of the Telegram interface (`languageCode`) first, then in the device's languages. The region of a locale
// often has no recognizer of its own (Russian on a phone set to Vietnam is "ru_VN"), so the language is matched on
// its own too.
public func replyReminderSpeechRecognizer(languageCode: String? = nil) -> SFSpeechRecognizer? {
    let supported = SFSpeechRecognizer.supportedLocales()
    var candidates: [Locale] = []
    if let languageCode, !languageCode.isEmpty {
        candidates.append(Locale(identifier: languageCode))
    }
    candidates.append(contentsOf: Locale.preferredLanguages.map { Locale(identifier: $0) })
    candidates.append(Locale.current)
    for locale in candidates {
        if supported.contains(locale), let recognizer = SFSpeechRecognizer(locale: locale) {
            return recognizer
        }
        guard let languageCode = locale.languageCode else {
            continue
        }
        let sameLanguage = supported.filter { $0.languageCode == languageCode }
        // Prefer the language's home region: ru-RU, de-DE; en-US for English.
        let preferred = sameLanguage.first(where: { $0.regionCode == languageCode.uppercased() || $0.identifier == "en-US" || $0.identifier == "en_US" }) ?? sameLanguage.first
        if let preferred, let recognizer = SFSpeechRecognizer(locale: preferred) {
            return recognizer
        }
    }
    return SFSpeechRecognizer()
}

private final class LevelThrottle {
    var lastTime: CFAbsoluteTime = 0.0
}

private final class RecognitionTaskBox {
    var task: SFSpeechRecognitionTask?
}

// Recognizes a recorded audio file (AAC) into text; nil when there is no permission or nothing was recognized.
public func replyReminderTranscribeAudioFile(path: String, languageCode: String? = nil) -> Signal<String?, NoError> {
    return Signal { subscriber in
        let box = RecognitionTaskBox()
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized, let recognizer = replyReminderSpeechRecognizer(languageCode: languageCode), recognizer.isAvailable else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
                request.shouldReportPartialResults = false
                if #available(iOS 16.0, *) {
                    request.addsPunctuation = true
                }
                box.task = recognizer.recognitionTask(with: request, resultHandler: { result, error in
                    if let result, result.isFinal {
                        subscriber.putNext(result.bestTranscription.formattedString)
                        subscriber.putCompletion()
                    } else if error != nil {
                        subscriber.putNext(nil)
                        subscriber.putCompletion()
                    }
                })
            }
        }
        return ActionDisposable {
            DispatchQueue.main.async {
                box.task?.cancel()
            }
        }
    }
}

// Dictation of the reminder note: while recording only the voice level is shown; the recognized text is handed over
// once the recording is finished.
final class ReplyReminderDictation {
    // The language of the Telegram interface, listened for first.
    private let languageCode: String?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasInputTap = false
    private var prefix = ""
    private var transcript: String?
    private var finishCompletion: ((String?) -> Void)?

    private(set) var isRunning = false
    // 0...1, about 20 times a second.
    var levelUpdated: ((CGFloat) -> Void)?
    var stateUpdated: ((Bool) -> Void)?

    // The note as it would be now: the typed prefix plus what was recognized so far.
    var currentText: String? {
        guard let transcript, !transcript.isEmpty else {
            return nil
        }
        let separator = self.prefix.isEmpty || self.prefix.hasSuffix(" ") ? "" : " "
        return self.prefix + separator + transcript
    }

    init(languageCode: String?) {
        self.languageCode = languageCode
    }

    deinit {
        self.cancel()
    }

    // `prefix` is the note typed so far; what is said is added after it.
    func start(prefix: String) {
        if self.isRunning {
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            return
                        }
                        self?.begin(prefix: prefix)
                    }
                }
            }
        }
    }

    private func begin(prefix: String) {
        guard !self.isRunning, let recognizer = replyReminderSpeechRecognizer(languageCode: self.languageCode), recognizer.isAvailable else {
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        // Recognition may use the network: forcing on-device recognition fails right away when the language model
        // is not downloaded.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        self.request = request
        self.prefix = prefix
        self.transcript = nil

        let inputNode = self.audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0.0, format.channelCount > 0 else {
            self.request = nil
            return
        }
        let levelThrottle = LevelThrottle()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)

            let now = CFAbsoluteTimeGetCurrent()
            guard now - levelThrottle.lastTime > 0.05, let channel = buffer.floatChannelData?[0] else {
                return
            }
            levelThrottle.lastTime = now
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 {
                return
            }
            // The peak, like the chat recorder's waveform: it follows syllables and pauses far better than the average.
            var peak: Float = 0.0
            for i in 0 ..< frameCount {
                peak = max(peak, abs(channel[i]))
            }
            let level = CGFloat(min(1.0, peak))
            DispatchQueue.main.async {
                self?.levelUpdated?(level)
            }
        }
        self.hasInputTap = true
        self.audioEngine.prepare()
        do {
            try self.audioEngine.start()
        } catch {
            self.cancel()
            return
        }

        self.task = recognizer.recognitionTask(with: request, resultHandler: { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if result?.isFinal == true || error != nil {
                    self.deliverFinish()
                }
            }
        })

        self.isRunning = true
        self.stateUpdated?(true)
    }

    private func stopAudio() {
        if self.audioEngine.isRunning {
            self.audioEngine.stop()
        }
        if self.hasInputTap {
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.hasInputTap = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Ends the recording and hands over the final note (nil when nothing was recognized). The recognizer gets a
    // moment to finish the last words.
    func finish(completion: @escaping (String?) -> Void) {
        guard self.isRunning else {
            completion(nil)
            return
        }
        self.finishCompletion = completion
        self.stopAudio()
        self.request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: { [weak self] in
            self?.deliverFinish()
        })
    }

    private func deliverFinish() {
        guard self.isRunning else {
            return
        }
        self.isRunning = false
        self.stopAudio()
        self.task?.cancel()
        self.task = nil
        self.request = nil
        let completion = self.finishCompletion
        self.finishCompletion = nil
        self.stateUpdated?(false)
        completion?(self.currentText)
    }

    func cancel() {
        self.stopAudio()
        self.request?.endAudio()
        self.request = nil
        self.task?.cancel()
        self.task = nil
        self.finishCompletion = nil
        if self.isRunning {
            self.isRunning = false
            self.stateUpdated?(false)
        }
    }
}
