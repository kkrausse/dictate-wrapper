import AppKit

/// Preserves every pasteboard item and representation while dictation uses the
/// clipboard as a transport for synthetic paste events.
@MainActor
final class ClipboardPreserver {
    private struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            guard !items.isEmpty else { return }

            let restoredItems = items.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(restoredItems)
        }
    }

    private let pasteboard: NSPasteboard
    private let restorationDelay: DispatchTimeInterval
    private var snapshot: Snapshot?
    private var pendingRestoration: DispatchWorkItem?
    private var temporaryContentsAreActive = false
    private var isFinishing = false

    init(
        pasteboard: NSPasteboard = .general,
        restorationDelay: DispatchTimeInterval = .milliseconds(100)
    ) {
        self.pasteboard = pasteboard
        self.restorationDelay = restorationDelay
    }

    func beginSession() {
        pendingRestoration?.cancel()
        pendingRestoration = nil
        snapshot = Snapshot(pasteboard: pasteboard)
        temporaryContentsAreActive = false
        isFinishing = false
    }

    func writeTemporaryString(_ string: String) -> Bool {
        guard snapshot != nil else { return false }

        pendingRestoration?.cancel()
        pasteboard.clearContents()
        guard pasteboard.setString(string, forType: .string) else {
            restoreNow()
            return false
        }

        temporaryContentsAreActive = true
        scheduleRestoration()
        return true
    }

    func finishSession() {
        guard snapshot != nil else { return }
        isFinishing = true
        if temporaryContentsAreActive {
            scheduleRestoration()
        } else {
            restoreNow()
        }
    }

    private func scheduleRestoration() {
        pendingRestoration?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.restoreNow()
            }
        }
        pendingRestoration = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restorationDelay, execute: work)
    }

    private func restoreNow() {
        pendingRestoration?.cancel()
        pendingRestoration = nil
        snapshot?.restore(to: pasteboard)
        temporaryContentsAreActive = false
        if isFinishing {
            snapshot = nil
            isFinishing = false
        }
    }
}
