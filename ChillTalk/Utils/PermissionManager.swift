import AVFoundation
import ApplicationServices
import Cocoa
import Speech

class PermissionManager {
    static let shared = PermissionManager()
    
    private init() {}
    
    func checkAllPermissions() {
        DispatchQueue.main.async {
            self.checkMicrophonePermission()
            self.checkAccessibilityPermission()
            self.checkSpeechRecognitionPermission()
        }
    }
    
    // MARK: - Microphone Permission
    
    func hasMicrophonePermission() -> Bool {
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        } else {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            return status == .authorized
        }
    }
    
    @discardableResult
    func checkMicrophonePermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        
        switch status {
        case .authorized:
            print("✅ Microphone permission granted")
            return true
            
        case .notDetermined:
            print("⚠️ Microphone permission not determined, requesting...")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        print("✅ Microphone permission granted")
                    } else {
                        print("❌ Microphone permission denied")
                        self.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
            
        case .denied, .restricted:
            print("❌ Microphone permission denied or restricted")
            showMicrophonePermissionAlert()
            return false
            
        @unknown default:
            return false
        }
    }
    
    private func showMicrophonePermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = String(localized: "需要麦克风权限")
            alert.informativeText = String(localized: "ChillTalk 需要访问麦克风来进行语音录制。请在系统设置中授予权限。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "打开系统设置"))
            alert.addButton(withTitle: String(localized: "取消"))
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self.openSystemPreferences(pane: "Privacy_Microphone")
            }
        }
    }
    
    // MARK: - Accessibility Permission
    
    func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
    
    @discardableResult
    func checkAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        
        if trusted {
            print("✅ Accessibility permission granted")
            return true
        } else {
            print("⚠️ Accessibility permission not granted")
            showAccessibilityPermissionAlert()
            return false
        }
    }
    
    private func showAccessibilityPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = String(localized: "需要辅助功能权限")
            alert.informativeText = String(localized: "ChillTalk 需要辅助功能权限来插入文本到其他应用。请在系统设置中授予权限后重启应用。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "打开系统设置"))
            alert.addButton(withTitle: String(localized: "取消"))
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self.openSystemPreferences(pane: "Privacy_Accessibility")
            }
        }
    }
    
    // MARK: - Speech Recognition Permission
    
    func hasSpeechRecognitionPermission() -> Bool {
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }
    
    @discardableResult
    func checkSpeechRecognitionPermission(completion: ((Bool) -> Void)? = nil) -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        
        switch status {
        case .authorized:
            print("✅ Speech recognition permission granted")
            completion?(true)
            return true
            
        case .notDetermined:
            print("⚠️ Speech recognition permission not determined, requesting...")
            SFSpeechRecognizer.requestAuthorization { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized {
                        print("✅ Speech recognition permission granted")
                        completion?(true)
                    } else {
                        print("❌ Speech recognition permission denied")
                        self.showSpeechRecognitionPermissionAlert()
                        completion?(false)
                    }
                }
            }
            return false
            
        case .denied, .restricted:
            print("❌ Speech recognition permission denied or restricted")
            showSpeechRecognitionPermissionAlert()
            completion?(false)
            return false
            
        @unknown default:
            completion?(false)
            return false
        }
    }
    
    private func showSpeechRecognitionPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = String(localized: "需要语音识别权限")
            alert.informativeText = String(localized: "ChillTalk 需要语音识别权限来实时显示您说话的内容。请在系统设置中授予权限。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "打开系统设置"))
            alert.addButton(withTitle: String(localized: "取消"))
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                self.openSystemPreferences(pane: "Privacy_SpeechRecognition")
            }
        }
    }
    
    // MARK: - Open System Preferences
    
    private func openSystemPreferences(pane: String) {
        // macOS 13+ uses System Settings
        if #available(macOS 13.0, *) {
            let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } else {
            // macOS 12 and earlier use System Preferences
            let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
