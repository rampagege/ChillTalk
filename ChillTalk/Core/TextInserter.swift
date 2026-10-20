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

        if focus == .notEditable {
            copyToClipboard(text)
            _ = postCommandV()
            completion(.success(.pastedAndKeptOnClipboard))
            return
        }

        guard paste(text) else {
            // Leave the text on the clipboard so the user can paste manually.
            completion(.failure(TextInserterError.insertionFailed))
            return
        }
        // Report success right away so the HUD disappears together with the pasted text;
        // the clipboard restore happens on its own shortly after.
        completion(.success(.pasted))
    }

    /// The field text was inserted into, so a later correction can find it again.
    struct Target {
        let pid: pid_t
        let element: AXUIElement?
    }

    /// Must be called on the main thread, right after a successful insert.
    func currentTarget() -> Target? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return Target(pid: pid, element: focusedElement())
    }

    enum ReplaceOutcome {
        case replaced
        /// The old text couldn't be found safely; the new text is only on the clipboard.
        case copiedOnly
    }

    /// Replaces `old`, which was inserted into `target` earlier and should sit right before
    /// the caret, with `new`. Prefers selecting `old` through Accessibility; if the app doesn't
    /// expose its text (terminals, some Electron apps), deletes it with Backspace, but only
    /// when `allowBlindDelete` says nothing was typed or clicked since. Must be called on the
    /// main thread.
    func replace(_ old: String, with new: String, in target: Target, allowBlindDelete: Bool,
                 completion: @escaping (Result<ReplaceOutcome, Error>) -> Void) {
        guard PermissionManager.shared.hasAccessibilityPermission() else {
            copyToClipboard(new)
            completion(.failure(TextInserterError.noAccessibilityPermission))
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            copyToClipboard(new)
            completion(.success(.copiedOnly))
            return
        }

        let element = focusedElement()
        var deleteCount = 0
        if let element, selectTextBeforeCaret(old, in: element) {
            // Pasting replaces the selection.
        } else if allowBlindDelete, Self.isSameElement(element, target.element) {
            deleteCount = old.count
            guard postBackspaces(deleteCount) else {
                copyToClipboard(new)
                completion(.failure(TextInserterError.insertionFailed))
                return
            }
        } else {
            copyToClipboard(new)
            completion(.success(.copiedOnly))
            return
        }

        // A long run of Backspaces can take the app a moment; don't restore the clipboard
        // before it gets to the paste.
        guard paste(new, restoreAfter: restoreDelay + Double(deleteCount) * 0.005) else {
            completion(.failure(TextInserterError.insertionFailed))
            return
        }
        completion(.success(.replaced))
    }

    /// Puts `text` on the clipboard, sends ⌘V, and later restores what was on the clipboard.
    private func paste(_ text: String, restoreAfter delay: TimeInterval? = nil) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Ask clipboard managers not to record this temporary entry.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChangeCount = pasteboard.changeCount

        guard postCommandV() else { return false }

        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? restoreDelay)) {
            // Only restore if nobody else changed the clipboard in the meantime.
            if pasteboard.changeCount == ourChangeCount {
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        return true
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

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        // Don't let a hung app stall insertion.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        return (focusedRef as! AXUIElement)
    }

    /// Unknown on either side counts as the same: only a positive mismatch rules it out.
    private static func isSameElement(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        guard let a, let b else { return true }
        return CFEqual(a, b)
    }

    /// Selects `expected` if it's exactly the text before the caret. False if the app doesn't
    /// expose its text, or the text there is different.
    private func selectTextBeforeCaret(_ expected: String, in element: AXUIElement) -> Bool {
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return false }
        var caret = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &caret), caret.length == 0 else { return false }

        let text = value as NSString
        let length = (expected as NSString).length
        guard length > 0, caret.location >= length, caret.location <= text.length,
              text.substring(with: NSRange(location: caret.location - length, length: length)) == expected else { return false }

        var selection = CFRange(location: caret.location - length, length: length)
        guard let newRange = AXValueCreate(.cfRange, &selection),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newRange) == .success else { return false }

        // Some apps accept the call and ignore it.
        var checkRef: CFTypeRef?
        var check = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &checkRef) == .success,
              let checkRef, CFGetTypeID(checkRef) == AXValueGetTypeID(),
              AXValueGetValue(checkRef as! AXValue, .cfRange, &check) else { return false }
        return check.location == selection.location && check.length == selection.length
    }

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

    private func postBackspaces(_ count: Int) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false) else {
                return false
            }
            // Explicit empty flags so a held modifier can't turn this into ⌥⌫ (delete word).
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
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
