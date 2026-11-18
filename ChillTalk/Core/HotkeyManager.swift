import Carbon
import Cocoa
import os

/// Global hotkeys: one starts dictation, an optional second one corrects the last insertion.
///
/// - Modifier+key combos use a Carbon hotkey (consumes the keystroke, fires on press).
/// - A single modifier (e.g. right Option) fires on *release*, and only if nothing else was
///   pressed while it was held. Using ⌥ to type special characters, or ⌘ in a shortcut,
///   therefore never toggles recording.
///
/// Also reports Esc presses so the app can cancel an in-progress dictation, and any typing or
/// clicking in other apps so the app knows the last insertion may have been edited.
///
/// While `capturesEscape` is on, an event tap takes Esc so it cancels the dictation without
/// also reaching the app the user is typing in (closing its dialog, leaving vim's insert mode).
/// Otherwise nothing is intercepted.
final class HotkeyManager {
    enum Action: UInt32 {
        case dictate = 1
        case correct = 2
    }

    var onHotkeyPressed: ((Action) -> Void)?
    /// Called on the main queue.
    var onEscapePressed: (() -> Void)?

    /// Turn on while a dictation is in progress (main thread).
    var capturesEscape = false {
        didSet {
            guard capturesEscape != oldValue else { return }
            escapeState.withLock { $0.capturing = capturesEscape }
            updateEscapeTap()
        }
    }
    /// A key press or click that went to another app.
    var onUserInput: (() -> Void)?

    // Carbon combo hotkeys
    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private static let signature = OSType(0x4348544B) // 'CHTK'

    // Event monitors (modifier taps + Esc)
    private var monitors: [Any] = []
    /// Modifier keyCode → what tapping it does.
    private var modifierActions: [Int: Action] = [:]
    private var heldModifier: Int?
    private var isTapCandidate = false

    // Esc event tap. Its callback runs on a thread of its own, so a busy main thread can never
    // hold up the user's typing while the tap is on.
    private var escapeTap: CFMachPort?
    private struct EscapeState {
        var capturing = false
        /// A captured Esc is still held down: its repeats and key-up are swallowed too, even
        /// after the cancel turned capturing off, so none of it reaches the other app.
        var holding = false
    }
    private let escapeState = OSAllocatedUnfairLock(initialState: EscapeState())

    init() {
        installMonitors()
    }

    deinit {
        unregisterAll()
        monitors.forEach { NSEvent.removeMonitor($0) }
        if let escapeTap { CFMachPortInvalidate(escapeTap) }
    }

    /// Returns false if the combo is already taken by another app or the system.
    @discardableResult
    func register(_ config: HotkeyConfig, for action: Action) -> Bool {
        unregister(action)
        if config.isModifierOnly {
            modifierActions[config.keyCode] = action
            print("✅ Registered modifier-tap hotkey \(action): keyCode=\(config.keyCode)")
            return true
        }
        return registerCombinationHotkey(keyCode: config.keyCode, modifiers: config.modifiers, action: action)
    }

    func unregister(_ action: Action) {
        modifierActions = modifierActions.filter { $0.value != action }
        if let held = heldModifier, modifierActions[held] == nil {
            heldModifier = nil
            isTapCandidate = false
        }
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    private func unregisterAll() {
        unregister(.dictate)
        unregister(.correct)
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
            if event.type != .flagsChanged, !TextInserter.isOwnEvent(event) { self?.onUserInput?() }
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
            if heldModifier != nil { isTapCandidate = false }
            if event.keyCode == UInt16(kVK_Escape), !event.isARepeat {
                onEscapePressed?()
            }
        default:
            // Mouse click while holding the modifier (e.g. ⌥-click) is not a tap.
            if heldModifier != nil { isTapCandidate = false }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)

        if let held = heldModifier, held != keyCode {
            // A different modifier changed while ours is held → it's a chord, not a tap.
            isTapCandidate = false
            return
        }
        guard let action = modifierActions[keyCode], let deviceMask = Self.deviceMask(forKeyCode: keyCode) else { return }

        // Device-dependent bits distinguish left/right, so releasing right ⌥ while left ⌥
        // is still held is detected correctly.
        let isDown = UInt(event.modifierFlags.rawValue) & deviceMask != 0
        if isDown && heldModifier == nil {
            heldModifier = keyCode
            let others = event.modifierFlags
                .intersection([.command, .option, .control, .shift])
                .subtracting(Self.familyFlag(forKeyCode: keyCode))
            isTapCandidate = others.isEmpty
        } else if !isDown && heldModifier == keyCode {
            heldModifier = nil
            if isTapCandidate {
                isTapCandidate = false
                DispatchQueue.main.async { self.onHotkeyPressed?(action) }
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

    // MARK: - Esc capture

    private func updateEscapeTap() {
        if capturesEscape {
            // Created on first use, and retried later if Accessibility wasn't granted yet. Without
            // a tap, the event monitors still report Esc; it just reaches the other app too.
            if escapeTap == nil { escapeTap = makeEscapeTap() }
            if let escapeTap { CGEvent.tapEnable(tap: escapeTap, enable: true) }
        } else if let escapeTap, !escapeState.withLock({ $0.holding }) {
            // While a captured Esc is held, the tap thread turns the tap off at its key-up.
            CGEvent.tapEnable(tap: escapeTap, enable: false)
        }
    }

    private func makeEscapeTap() -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handleTapEvent(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            print("⚠️ Couldn't create the Esc event tap (Accessibility not granted?)")
            return nil
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "ChillTalk Esc tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return tap
    }

    /// Runs on the tap's thread: decide fast, do the work on the main queue.
    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let state = escapeState.withLock { $0 }
            if state.capturing || state.holding, let escapeTap { CGEvent.tapEnable(tap: escapeTap, enable: true) }
            return pass
        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) else { return pass }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // Plain Esc only: ⌘/⌥/⌃ + Esc are other shortcuts (⌥⌘Esc is Force Quit).
            let isPlain = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty
            enum Decision { case pass, passAndStop, swallow, cancel, release }
            let decision: Decision = escapeState.withLock { state in
                if type == .keyUp {
                    guard state.holding else { return .pass }
                    state.holding = false
                    return state.capturing ? .swallow : .release
                }
                if state.capturing && isPlain && !isRepeat {
                    state.holding = true
                    return .cancel
                }
                // Repeats of a captured press; a fresh press after capture ended goes through
                // (and clears a key-up that never arrived).
                if state.holding && (isRepeat || state.capturing) { return .swallow }
                if state.holding {
                    // The key-up never arrived; this is a new press after capture ended.
                    state.holding = false
                    return .passAndStop
                }
                return .pass
            }
            switch decision {
            case .pass:
                return pass
            case .passAndStop:
                if let escapeTap { CGEvent.tapEnable(tap: escapeTap, enable: false) }
                return pass
            case .swallow:
                return nil
            case .cancel:
                DispatchQueue.main.async { self.onEscapePressed?() }
                return nil
            case .release:
                // The press is over and nothing is being captured: stop intercepting.
                if let escapeTap { CGEvent.tapEnable(tap: escapeTap, enable: false) }
                return nil
            }
        default:
            return pass
        }
    }

    // MARK: - Carbon combo hotkey

    private func installHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }
        let handler: EventHandlerUPP = { _, theEvent, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            var firedID = EventHotKeyID()
            GetEventParameter(theEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            guard firedID.signature == HotkeyManager.signature,
                  let action = Action(rawValue: firedID.id) else { return OSStatus(eventNotHandledErr) }

            // The consumed keystroke never reaches the monitors: a held modifier (e.g. right ⌥
            // of ⌥ Space) must not also count as a tap when it's released.
            manager.isTapCandidate = false
            DispatchQueue.main.async { manager.onHotkeyPressed?(action) }
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
        return true
    }

    private func registerCombinationHotkey(keyCode: Int, modifiers: Int, action: Action) -> Bool {
        guard installHandlerIfNeeded() else { return false }

        var ref: EventHotKeyRef?
        let registerResult = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: Self.signature, id: action.rawValue),
            GetEventDispatcherTarget(), OptionBits(0), &ref
        )
        if registerResult == noErr, let ref {
            hotKeyRefs[action] = ref
            print("✅ Registered combination hotkey \(action): keyCode=\(keyCode), modifiers=\(modifiers)")
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
