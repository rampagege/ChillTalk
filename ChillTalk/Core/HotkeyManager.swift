import Carbon
import Cocoa

/// Global dictation hotkey.
///
/// - Modifier+key combos use a Carbon hotkey (consumes the keystroke, fires on press).
/// - A single modifier (e.g. right Option) fires on *release*, and only if nothing else was
///   pressed while it was held. Using ⌥ to type special characters, or ⌘ in a shortcut,
///   therefore never toggles recording.
///
/// Also reports Esc presses so the app can cancel an in-progress dictation.
final class HotkeyManager {
    var onHotkeyPressed: (() -> Void)?
    var onEscapePressed: (() -> Void)?

    // Carbon combo hotkey
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let hotkeyID = EventHotKeyID(signature: OSType(0x4348544B), id: 1) // 'CHTK'

    // Event monitors (modifier taps + Esc)
    private var monitors: [Any] = []
    private var modifierKeyCode: Int?
    private var isModifierHeld = false
    private var isTapCandidate = false

    init() {
        installMonitors()
    }

    deinit {
        unregisterHotkey()
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    /// Returns false if the combo is already taken by another app or the system.
    @discardableResult
    func registerHotkey(_ config: HotkeyConfig) -> Bool {
        unregisterHotkey()
        if config.isModifierOnly {
            modifierKeyCode = config.keyCode
            print("✅ Registered modifier-tap hotkey: keyCode=\(config.keyCode)")
            return true
        }
        return registerCombinationHotkey(keyCode: config.keyCode, modifiers: config.modifiers)
    }

    func unregisterHotkey() {
        modifierKeyCode = nil
        isModifierHeld = false
        isTapCandidate = false

        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    // MARK: - Modifier tap detection

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(global)
        }
        // Global monitors don't see events sent to our own windows (e.g. Settings).
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            if isModifierHeld { isTapCandidate = false }
            if event.keyCode == UInt16(kVK_Escape), !event.isARepeat {
                onEscapePressed?()
            }
        default:
            // Mouse click while holding the modifier (e.g. ⌥-click) is not a tap.
            if isModifierHeld { isTapCandidate = false }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let target = modifierKeyCode, let deviceMask = Self.deviceMask(forKeyCode: target) else { return }

        guard Int(event.keyCode) == target else {
            // A different modifier changed while ours is held → it's a chord, not a tap.
            if isModifierHeld { isTapCandidate = false }
            return
        }

        // Device-dependent bits distinguish left/right, so releasing right ⌥ while left ⌥
        // is still held is detected correctly.
        let isDown = UInt(event.modifierFlags.rawValue) & deviceMask != 0
        if isDown && !isModifierHeld {
            isModifierHeld = true
            let others = event.modifierFlags
                .intersection([.command, .option, .control, .shift])
                .subtracting(Self.familyFlag(forKeyCode: target))
            isTapCandidate = others.isEmpty
        } else if !isDown && isModifierHeld {
            isModifierHeld = false
            if isTapCandidate {
                isTapCandidate = false
                DispatchQueue.main.async { self.onHotkeyPressed?() }
            }
        }
    }

    /// NX_DEVICE* masks from IOKit's IOLLEvent.h.
    private static func deviceMask(forKeyCode keyCode: Int) -> UInt? {
        switch keyCode {
        case kVK_Control: return 0x0000_0001
        case kVK_Shift: return 0x0000_0002
        case kVK_RightShift: return 0x0000_0004
        case kVK_Command: return 0x0000_0008
        case kVK_RightCommand: return 0x0000_0010
        case kVK_Option: return 0x0000_0020
        case kVK_RightOption: return 0x0000_0040
        case kVK_RightControl: return 0x0000_2000
        default: return nil
        }
    }

    private static func familyFlag(forKeyCode keyCode: Int) -> NSEvent.ModifierFlags {
        switch keyCode {
        case kVK_Control, kVK_RightControl: return .control
        case kVK_Shift, kVK_RightShift: return .shift
        case kVK_Command, kVK_RightCommand: return .command
        case kVK_Option, kVK_RightOption: return .option
        default: return []
        }
    }

    // MARK: - Carbon combo hotkey

    private func registerCombinationHotkey(keyCode: Int, modifiers: Int) -> Bool {
        let handler: EventHandlerUPP = { _, theEvent, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            var firedID = EventHotKeyID()
            GetEventParameter(theEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            guard firedID.id == manager.hotkeyID.id else { return OSStatus(eventNotHandledErr) }

            DispatchQueue.main.async { manager.onHotkeyPressed?() }
            return noErr
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installResult = InstallEventHandler(
            GetEventDispatcherTarget(), handler, 1, &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        guard installResult == noErr else {
            print("❌ Failed to install hotkey handler: \(installResult)")
            return false
        }

        let registerResult = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotkeyID,
            GetEventDispatcherTarget(), OptionBits(0), &hotKeyRef
        )
        if registerResult == noErr {
            print("✅ Registered combination hotkey: keyCode=\(keyCode), modifiers=\(modifiers)")
            return true
        }
        // Usually means another app (or the system, e.g. input source switching) owns it.
        print("❌ Failed to register hotkey: \(registerResult)")
        return false
    }
}

struct HotkeyConfig {
    var keyCode: Int
    var modifiers: Int

    var isModifierOnly: Bool {
        [kVK_Command, kVK_RightCommand, kVK_Option, kVK_RightOption,
         kVK_Control, kVK_RightControl, kVK_Shift, kVK_RightShift].contains(keyCode)
    }
}
