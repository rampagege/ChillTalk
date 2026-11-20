import Foundation

/// Ends recordings nobody is using, so an accidental or forgotten one doesn't keep the mic
/// open and stream (and bill) for hours:
/// - nothing said in the first 30 s: cancel, it was probably started by mistake
/// - a minute of silence after speaking: stop and transcribe
/// - the length limit: stop and transcribe, with the last 30 s counted down in the HUD
final class RecordingLimits {
    enum Reason: Equatable {
        case noSpeech, silence, maxDuration
    }

    enum Decision: Equatable {
        /// `countdown`: whole seconds left before the length limit, during the last 30 s.
        case keepGoing(countdown: Int?)
        case stop(Reason)
    }

    static let noSpeechTimeout: TimeInterval = 30
    static let silenceTimeout: TimeInterval = 60
    static let maxDuration: TimeInterval = 600
    static let countdownFrom: TimeInterval = 30

    /// Main queue. The limits are already stopped when it's called.
    var onLimit: ((Reason) -> Void)?
    /// Main queue. Seconds left before the length limit during the last 30 s, then nil.
    var onCountdown: ((Int?) -> Void)?

    private let lock = NSLock()
    private var speech = SpeechActivity()
    private var startTime: TimeInterval = 0
    private var maxDuration = RecordingLimits.maxDuration
    private var timer: Timer?
    private var countdown: Int?

    /// Main queue.
    func start(maxDuration: TimeInterval) {
        stop()
        lock.withLock { speech = SpeechActivity() }
        startTime = Self.now
        self.maxDuration = maxDuration
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Main queue.
    func stop() {
        timer?.invalidate()
        timer = nil
        if countdown != nil {
            countdown = nil
            onCountdown?(nil)
        }
    }

    /// Input level 0…1 (-60…0 dB). Audio thread.
    func add(level: Double) {
        let now = Self.now
        lock.withLock { speech.add(level: level, at: now) }
    }

    private func tick() {
        let now = Self.now
        let lastSpeech = lock.withLock { speech.lastSpeech }
        switch Self.decide(elapsed: now - startTime, silence: lastSpeech.map { now - $0 }, maxDuration: maxDuration) {
        case .stop(let reason):
            stop()
            onLimit?(reason)
        case .keepGoing(let secondsLeft):
            guard secondsLeft != countdown else { return }
            countdown = secondsLeft
            onCountdown?(secondsLeft)
        }
    }

    /// `silence`: time since the user last spoke, nil if they haven't yet.
    static func decide(elapsed: TimeInterval, silence: TimeInterval?, maxDuration: TimeInterval) -> Decision {
        if elapsed >= maxDuration { return .stop(.maxDuration) }
        if let silence {
            if silence >= silenceTimeout { return .stop(.silence) }
        } else if elapsed >= noSpeechTimeout {
            return .stop(.noSpeech)
        }
        let left = maxDuration - elapsed
        return .keepGoing(countdown: left <= countdownFrom ? Int(left.rounded(.up)) : nil)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Tells speaking from background noise by loudness: clearly louder than the background
/// (tracked as it changes) for a moment counts as speech. It errs toward hearing speech:
/// that only delays an automatic stop, while missing speech would cut a dictation short.
struct SpeechActivity {
    /// How much louder than the background counts as speech: 12 dB on the 60 dB scale.
    static let margin = 0.2
    /// Loud for at least this long, so clicks and taps don't count.
    static let minDuration: TimeInterval = 0.15
    /// The background estimate falls at once but rises slowly (2 dB/s), so speech doesn't
    /// pull it up while a lasting change in noise (a fan turning on) is followed.
    static let floorRisePerSecond = 2.0 / 60

    /// When speech was last heard.
    private(set) var lastSpeech: TimeInterval?
    private var floor: Double?
    private var lastTime: TimeInterval?
    private var loudSince: TimeInterval?

    mutating func add(level: Double, at time: TimeInterval) {
        let elapsed = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
        // 0 is digital silence (a device starting up, a muted input), not the room.
        guard level > 0 else {
            loudSince = nil
            return
        }
        let floor = min(level, (self.floor ?? level) + Self.floorRisePerSecond * elapsed)
        self.floor = floor

        guard level >= floor + Self.margin else {
            loudSince = nil
            return
        }
        let since = loudSince ?? time
        loudSince = since
        if time - since >= Self.minDuration { lastSpeech = time }
    }
}
