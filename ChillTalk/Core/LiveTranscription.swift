import Speech
import AVFoundation
import Foundation

class LiveTranscription: NSObject {
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    var onPartialResult: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    
    private var isRecognizing = false
    private var lastPartialTranscript: String = ""
    /// Text from earlier segments. After a pause the recognizer can start a new segment and
    /// report only that, which would otherwise wipe what was already said from the HUD.
    private var committedTranscript: String = ""
    /// Bumped on every start so results from a previous, still-finalizing task are ignored.
    private var generation = 0
    
    /// The recognizer (and Speech's models) load on first use, since streaming providers
    /// show their own live text and never need it.
    override init() {
        super.init()
    }
    
    /// Switches the recognizer language (takes effect on the next start).
    func setLocale(_ identifier: String) {
        guard !isRecognizing, speechRecognizer?.locale.identifier != identifier,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) else { return }
        recognizer.defaultTaskHint = .dictation
        speechRecognizer = recognizer
    }

    
    func startRecognition() {
        if speechRecognizer == nil { setLocale("zh-CN") }
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            let error = NSError(domain: "LiveTranscription", code: 1, 
                              userInfo: [NSLocalizedDescriptionKey: "Speech recognizer not available"])
            onError?(error)
            return
        }
        
        guard !isRecognizing else {
            print("⚠️ Recognition already in progress")
            return
        }
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            let error = NSError(domain: "LiveTranscription", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to create recognition request"])
            onError?(error)
            return
        }
        
        // Configure request for live recognition
        recognitionRequest.shouldReportPartialResults = true
        
        // Try on-device recognition first if available for better privacy and lower latency
        if #available(macOS 13.0, *) {
            if speechRecognizer.supportsOnDeviceRecognition {
                recognitionRequest.requiresOnDeviceRecognition = true
                print("✅ Using on-device speech recognition")
            } else {
                print("⚠️ On-device recognition not available, using cloud")
            }
        } else {
            // macOS < 13.0, cloud only
            print("⚠️ macOS < 13.0, using cloud recognition")
        }
        
        // Start recognition task
        isRecognizing = true
        lastPartialTranscript = ""
        committedTranscript = ""
        generation += 1
        let taskGeneration = generation
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async {
                    guard self.generation == taskGeneration, self.isRecognizing else { return }
                    print("❌ Speech recognition error: \(error.localizedDescription)")
                    self.isRecognizing = false
                    self.onError?(error)
                }
                return
            }
            
            if let result = result {
                let transcript = result.bestTranscription.formattedString
                
                DispatchQueue.main.async {
                    guard self.generation == taskGeneration else { return }
                    let previous = self.lastPartialTranscript
                    // A much shorter hypothesis that doesn't continue the previous one means
                    // a new segment started: keep the old one.
                    if !previous.isEmpty,
                       transcript.count < previous.count / 2,
                       !previous.hasPrefix(transcript) {
                        self.committedTranscript += previous
                    }
                    self.lastPartialTranscript = transcript
                    let full = self.committedTranscript + transcript
                    // Final results replace the partial text too.
                    self.onPartialResult?(full)
                }
            }
        }
        
        print("✅ Live transcription started")
    }
    
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecognizing else { return }
        recognitionRequest?.append(buffer)
    }
    
    func stopRecognition(completion: (() -> Void)? = nil) {
        guard isRecognizing else {
            completion?()
            return
        }
        
        isRecognizing = false
        lastPartialTranscript = ""
        committedTranscript = ""
        
        // Detach the current task/request so a recording started within the grace period
        // below gets its own, untouched instances.
        let task = recognitionTask
        recognitionRequest?.endAudio()
        recognitionTask = nil
        recognitionRequest = nil
        
        // Give it a moment to finalize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            task?.cancel()
            completion?()
        }
    }
    
    deinit {
        recognitionTask?.cancel()
    }
}
