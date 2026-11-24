import AppKit
import CoreGraphics
import Darwin

struct RestorableScreen: Identifiable {
    let id: CGDirectDisplayID
    let key: String
    let name: String
    let builtIn: Bool
    fileprivate let time: Date
}

private struct ConnectionFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
final class ScreenConnections {
    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Int32) -> CGError
    private let configure: ConfigureEnabled?
    private(set) var disconnected: [RestorableScreen] = []
    var available: Bool { configure != nil }

    init() {
        let module = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL)
        configure = module.flatMap { dlsym($0, "CGSConfigureDisplayEnabled") }.map {
            unsafeBitCast($0, to: ConfigureEnabled.self)
        }
    }

    func reconcile(_ screens: [DeskDisplay]) {
        disconnected.removeAll { item in
            guard let attached = screens.first(where: { $0.id == item.id }) else { return false }
            if attached.key != item.key { return true }
            return Date().timeIntervalSince(item.time) > 2 && CGDisplayIsActive(attached.id) != 0
        }
    }

    func canDisconnect(_ display: DeskDisplay, screens: [DeskDisplay], virtualIDs: Set<CGDirectDisplayID>,
                       confirmedPhysical: Set<CGDirectDisplayID>) -> Bool {
        available && display.mirrorSource == nil && !virtualIDs.contains(display.id) &&
        !screens.contains(where: { $0.mirrorSource == display.id }) &&
        screens.contains { other in
            other.id != display.id && other.mirrorSource == nil && !virtualIDs.contains(other.id) &&
            (other.builtIn || confirmedPhysical.contains(other.id)) && CGDisplayIsActive(other.id) != 0
        }
    }

    func disconnect(_ display: DeskDisplay, screens: [DeskDisplay], virtualIDs: Set<CGDirectDisplayID>,
                    confirmedPhysical: Set<CGDirectDisplayID>) throws {
        let live = try DisplaySystem.list()
        guard live.contains(where: { $0.id == display.id && $0.key == display.key }),
              canDisconnect(display, screens: live, virtualIDs: virtualIDs, confirmedPhysical: confirmedPhysical)
        else { throw ConnectionFailure("Keep another physical display active and extend this display before disconnecting it.") }
        guard !disconnected.contains(where: { $0.key == display.key }) else { return }
        try setEnabled(false, id: display.id)
        disconnected.append(RestorableScreen(id: display.id, key: display.key, name: display.name,
                                              builtIn: display.builtIn, time: Date()))
    }

    func reconnect(_ item: RestorableScreen) throws {
        guard disconnected.contains(where: { $0.id == item.id && $0.key == item.key }) else { return }
        if let live = try DisplaySystem.list().first(where: { $0.id == item.id }) {
            guard live.key == item.key else {
                throw ConnectionFailure("Another display now uses this connection. Reconnect the original cable to redetect it.")
            }
            if CGDisplayIsActive(item.id) != 0 {
                disconnected.removeAll { $0.key == item.key }
                return
            }
        }
        try setEnabled(true, id: item.id)
        disconnected.removeAll { $0.key == item.key }
    }

    func restoreAll() {
        for item in disconnected { try? reconnect(item) }
    }

    private func setEnabled(_ enabled: Bool, id: CGDirectDisplayID) throws {
        guard let configure else { throw ConnectionFailure("This macOS version does not expose display connection control.") }
        var draft: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&draft) == .success, let draft else {
            throw ConnectionFailure("macOS could not start a display configuration.")
        }
        let code = configure(draft, id, enabled ? 1 : 0)
        guard code == .success else {
            CGCancelDisplayConfiguration(draft)
            throw ConnectionFailure("macOS declined the connection change (Quartz error \(code.rawValue)).")
        }
        let applied = CGCompleteDisplayConfiguration(draft, .forAppOnly)
        guard applied == .success else { throw ConnectionFailure("The connection change failed (Quartz error \(applied.rawValue)).") }
    }
}
