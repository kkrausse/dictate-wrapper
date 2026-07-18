import AppKit

final class GlobalHotKey {
    enum ActivationMode {
        case pushToTalk
        case toggle
    }

    enum Phase {
        case pressed
        case released
    }

    private static let rightOptionKeyCode: UInt16 = 61

    private let handler: (Phase) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed = false

    init(handler: @escaping (Phase) -> Void) {
        self.handler = handler

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.rightOptionKeyCode else { return }
        isPressed.toggle()
        handler(isPressed ? .pressed : .released)
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
