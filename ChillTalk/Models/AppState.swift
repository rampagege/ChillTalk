import Foundation
import Combine

enum RecordingState {
    case idle
    case recording
    case processing
    case error
    
    var displayName: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .recording:
            return String(localized: "录音中")
        case .processing:
            return String(localized: "处理中")
        case .error:
            return String(localized: "错误")
        }
    }
}

class AppState: ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var lastError: String?
    @Published var lastTranscript: String?
}
