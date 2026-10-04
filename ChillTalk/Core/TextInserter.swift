import ApplicationServices
import Carbon
import Cocoa

/// Inserts text into the focused field of the frontmost app by pasting it, then restores
/// the user's clipboard. Pasting handles any Unicode (emoji, rare CJK, combining marks)
/// and long text instantly, unlike synthesizing one key event per character.
final class TextInserter {
    enum Outcome {
        case pasted
        /// No text field seemed focused: paste was still attempted, and the text was left on
        /// the clipboard so it isn't lost.
        case pastedAndKeptOnClipboard
        /// Focus moved to a different app while processing; text was only put on the clipboard.
        case copiedOnly
    }

    private enum FocusKind {
        /// A text field, text view, search field, etc.
        case editable
        /// Nothing focused, or a control that can't take text (list, button, …).
        case notEditable
        /// Can't tell (web content, Electron apps, custom views). Treated like editable.
        case unknown
    }

    /// Delay before restoring the clipboard, giving the target app time to read it.
    private let restoreDelay: TimeInterval = 0.6

    /// Must be called on the main thread.
    /// - Parameter expectedPID: app that was frontmost when recording stopped. If another app
    ///   is frontmost now, the text is copied instead of pasted into the wrong window.
    func insert(_ text: String, expectedPID: pid_t?, completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard !text.isEmpty else {
            completion(.success(.pasted))
            return
        }

        guard PermissionManager.shared.hasAccessibilityPermission() else {
            copyToClipboard(text)
            completion(.failure(TextInserterError.noAccessibilityPermission))
            return
        }

        if let expectedPID = expectedPID,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != expectedPID {
            copyToClipboard(text)
            completion(.success(.copiedOnly))
            return
        }

        let focus = focusedFieldKind()
        let pasteboard = NSPasteboard.general

        if focus == .notEditable {
            copyToClipboard(text)
            _ = postCommandV()
            completion(.success(.pastedAndKeptOnClipboard))
            return
        }

        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Ask clipboard managers not to record this temporary entry.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChangeCount = pasteboard.changeCount

        guard postCommandV() else {
            // Leave the text on the clipboard so the user can paste manually.
            completion(.failure(TextInserterError.insertionFailed))
            return
        }

        // Report success right away so the HUD disappears together with the pasted text;
        // the clipboard restore happens on its own shortly after.
        completion(.success(.pasted))

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // Only restore if nobody else changed the clipboard in the meantime.
            if pasteboard.changeCount == ourChangeCount {
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Private

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"
    ]
    private static let nonEditableRoles: Set<String> = [
        kAXListRole, kAXOutlineRole, kAXTableRole, kAXButtonRole, kAXImageRole,
        kAXMenuRole, kAXMenuItemRole, kAXMenuBarRole, kAXCheckBoxRole, kAXRadioButtonRole,
        kAXApplicationRole
    ]

    private func focusedFieldKind() -> FocusKind {
        let systemWide = AXUIElementCreateSystemWide()
        // Don't let a hung app stall insertion.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)

        var focusedRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if error == .noValue { return .notEditable }
        guard error == .success, let focusedRef = focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return .unknown }
        let element = focusedRef as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        if Self.editableRoles.contains(role) { return .editable }

        for attribute in [kAXSelectedTextRangeAttribute, kAXValueAttribute] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success, settable.boolValue {
                return .editable
            }
        }
        return Self.nonEditableRoles.contains(role) ? .notEditable : .unknown
    }

    private func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private func postCommandV() -> Bool {
        let keyCode = Self.keyCodeForV()
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        // Explicit flags so a still-held hotkey modifier (e.g. Option) can't turn this into ⌥⌘V.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Finds the key that types "v" in the current layout (differs on Dvorak, AZERTY…).
    /// Falls back to the ANSI position, which is also what non-Latin layouts use for ⌘ shortcuts.
    private static func keyCodeForV() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallback
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> CGKeyCode in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            for keyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState, chars.count, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(("v" as Unicode.Scalar).value) {
                    return CGKeyCode(keyCode)
                }
            }
            return fallback
        }
    }
}

enum TextInserterError: LocalizedError {
    case noAccessibilityPermission
    case insertionFailed

    var errorDescription: String? {
        switch self {
        case .noAccessibilityPermission:
            return String(localized: "需要辅助功能权限才能插入文本")
        case .insertionFailed:
            return String(localized: "无法模拟粘贴")
        }
    }
}
