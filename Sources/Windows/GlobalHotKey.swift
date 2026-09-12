import AppKit
import Carbon

/// A registered shortcut needs no Accessibility or input-monitoring permission.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: () -> Void = {}

    func register() -> Bool {
        unregister()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x53485542, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in owner.action() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return false }
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey | cmdKey),
                                         EventHotKeyID(signature: 0x53485542, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { unregister() }
        return result == noErr
    }
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
