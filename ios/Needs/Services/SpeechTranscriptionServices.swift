import Foundation
import Observation
@preconcurrency import AVFoundation
@preconcurrency import Speech

@MainActor
@Observable
public final class NativeSpeechTranscriptionService: SpeechTranscriptionService {
    public private(set) var isListening = false
    public private(set) var transcript = ""

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    public init(locale: Locale = Locale(identifier: "en_US")) {
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    public func requestAuthorization() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        let microphoneAuthorized: Bool
        if #available(iOS 17.0, *) {
            microphoneAuthorized = await AVAudioApplication.requestRecordPermission()
        } else {
            microphoneAuthorized = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        return speechAuthorized && microphoneAuthorized
    }

    public func startTranscribing() throws {
        guard !isListening else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw AppError.unavailable("Speech recognition is unavailable")
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        transcript = ""

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true { self.stopTranscribing() }
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
    }

    public func stopTranscribing() {
        guard isListening || recognitionRequest != nil else { return }
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor
@Observable
public final class MockSpeechTranscriptionService: SpeechTranscriptionService {
    public private(set) var isListening = false
    public private(set) var transcript = ""
    public var authorizationGranted = true

    public init() {}
    public func requestAuthorization() async -> Bool { authorizationGranted }
    public func startTranscribing() throws { isListening = true }
    public func stopTranscribing() { isListening = false }
    public func simulateTranscript(_ value: String) { transcript = value }
}
