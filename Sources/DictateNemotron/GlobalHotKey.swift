import Carbon.HIToolbox
import Foundation

final class GlobalHotKey {
    enum RegistrationError: LocalizedError {
        case eventHandler(OSStatus)
        case hotKey(OSStatus)

        var errorDescription: String? {
            switch self {
            case .eventHandler(let status):
                return "Could not install the global hotkey handler (\(status))."
            case .hotKey(let status):
                return "Could not register Cmd+Shift+D (\(status))."
            }
        }
    }

    private let handler: () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    init(handler: @escaping () -> Void) throws {
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                hotKey.handler()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            throw RegistrationError.eventHandler(handlerStatus)
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4449_4354), id: 1) // "DICT"
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard hotKeyStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            eventHandler = nil
            throw RegistrationError.hotKey(hotKeyStatus)
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
