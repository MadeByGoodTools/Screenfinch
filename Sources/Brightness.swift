import AppKit
import ColorSync
import CoreGraphics

struct BrightnessSample {
    let value: Double
    let method: String

    var canAdjust: Bool { method != BrightnessRoute.unavailable.rawValue }
}

enum MonitorAdjustment: Int, CaseIterable, Sendable {
    case contrast = 0x12
    case volume = 0x62

    var title: String { self == .contrast ? "Contrast" : "Speaker volume" }
}

struct MonitorInputs: Sendable {
    let current: UInt16
    let choices: [UInt16]

    var currentTitle: String {
        choices.contains(current) ? Self.title(current) : String(format: "Reported input 0x%02X", current)
    }

    static func title(_ value: UInt16) -> String {
        let standard = [
            "VGA 1", "VGA 2", "DVI 1", "DVI 2", "Composite 1", "Composite 2", "S-Video 1", "S-Video 2",
            "Tuner 1", "Tuner 2", "Tuner 3", "Component 1", "Component 2", "Component 3",
            "DisplayPort 1", "DisplayPort 2", "HDMI 1", "HDMI 2"
        ]
        return (1...standard.count).contains(Int(value)) ? standard[Int(value) - 1] : String(format: "Input 0x%02X", value)
    }

    fileprivate init?(capabilities: Data, current: UInt16) {
        // Locate the top-level vcp field, then only its 60(...) value list.
        // Model names and capability groups for other VCP controls can contain
        // the same numbers. They are never used to populate the picker.
        var document = CapabilityFields(bytes: capabilities[...])
        guard var fields = document.group(), document.atEnd else { return nil }
        var sourceChoices: [UInt16] = []
        while let field = fields.word() {
            guard var group = fields.group() else { return nil }
            if field.lowercased() != "vcp" { continue }
            while let feature = group.word() {
                let arguments = group.group()
                guard let code = Self.hexByte(feature) else { return nil }
                guard code == 0x60, var values = arguments else { continue }
                while let token = values.word() {
                    guard let choice = Self.hexByte(token), choice != 0 else { return nil }
                    if !sourceChoices.contains(choice) { sourceChoices.append(choice) }
                }
                guard values.atEnd else { return nil }
            }
            guard group.atEnd else { return nil }
        }
        guard fields.atEnd, !sourceChoices.isEmpty else { return nil }
        self.current = current
        choices = sourceChoices
    }

    private static func hexByte(_ text: String) -> UInt16? {
        guard text.utf8.count == 2, text.utf8.allSatisfy({ (48...57).contains($0) ||
            (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return UInt16(text, radix: 16)
    }
}

private struct CapabilityFields {
    var bytes: Data.SubSequence

    mutating func skipSpaces() {
        while let b = bytes.first, b == 32 || (9...13).contains(b) { bytes = bytes.dropFirst() }
    }

    var atEnd: Bool {
        mutating get { skipSpaces(); return bytes.isEmpty }
    }

    mutating func word() -> String? {
        skipSpaces()
        let token = bytes.prefix { $0 > 32 && $0 != 40 && $0 != 41 && $0 < 127 }
        guard !token.isEmpty else { return nil }
        bytes = bytes.dropFirst(token.count)
        return String(decoding: token, as: UTF8.self)
    }

    mutating func group() -> Self? {
        skipSpaces()
        guard bytes.first == 40 else { return nil }
        let rest = bytes.dropFirst()
        var depth = 1
        for index in rest.indices {
            switch rest[index] {
            case 40: depth += 1
            case 41:
                depth -= 1
                if depth == 0 {
                    bytes = rest[rest.index(after: index)...]
                    return Self(bytes: rest[..<index])
                }
            default: continue
            }
        }
        return nil
    }
}

private enum BrightnessRoute: String, Sendable {
    case apple = "Apple backlight"
    case monitor = "DDC/CI backlight"
    case software = "Software dimming"
    case unavailable = "Unavailable"

    func sample(_ level: Double) -> BrightnessSample {
        BrightnessSample(value: level, method: rawValue)
    }
}

private struct DisplayConnectionID: Equatable, Sendable {
    let display: CGDirectDisplayID
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32
    let uuid: String?

    init?(_ display: CGDirectDisplayID) {
        guard CGDisplayIsOnline(display) != 0 else { return nil }
        self.display = display
        vendor = CGDisplayVendorNumber(display)
        product = CGDisplayModelNumber(display)
        serial = CGDisplaySerialNumber(display)
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, uuidRef) as String?
        } else {
            uuid = nil
        }
    }
}

private struct AdjustmentTicket: Sendable {
    let feature: UInt8
    let sequence: UInt64
}

// A display ID can be reused after hot-plug. Both the session and the physical
// identity are checked on the I/O queue immediately before a hardware write.
private final class BrightnessConnection: @unchecked Sendable {
    let identity: DisplayConnectionID
    private let lock = NSLock()
    private var live = true
    private var revisions: [UInt8: UInt64] = [:]

    init(_ identity: DisplayConnectionID) { self.identity = identity }

    func supersedeWrites(for feature: UInt8 = 0x10) -> AdjustmentTicket {
        lock.lock()
        defer { lock.unlock() }
        let sequence = (revisions[feature] ?? 0) &+ 1
        revisions[feature] = sequence
        return AdjustmentTicket(feature: feature, sequence: sequence)
    }

    func cancel(_ ticket: AdjustmentTicket) {
        lock.lock()
        if revisions[ticket.feature] == ticket.sequence {
            revisions[ticket.feature] = ticket.sequence &+ 1
        }
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        live = false
        lock.unlock()
    }

    func matches(_ ticket: AdjustmentTicket? = nil) -> Bool {
        lock.lock()
        let eligible = live && (ticket.map { revisions[$0.feature] == $0.sequence } ?? true)
        lock.unlock()
        return eligible && DisplayConnectionID(identity.display) == identity
    }
}

@MainActor
private final class DimmingWindow: NSWindow {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isRestorable = false
        isOpaque = false
        isMovable = false
        hasShadow = false
        canHide = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        ignoresMouseEvents = true
        backgroundColor = .black
        animationBehavior = .none
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }
}

private enum DisplayBrightnessError: LocalizedError {
    case disconnected, invalidValue, noIndependentScreen, inputNotListed, inputRequestFailed, hardwareReadback(String)

    var errorDescription: String? {
        switch self {
        case .disconnected: return "The selected display disconnected."
        case .invalidValue: return "Choose a value between 0% and 100%."
        case .noIndependentScreen: return "Software dimming requires a display with its own desktop."
        case .inputNotListed: return "The display did not advertise that input."
        case .inputRequestFailed: return "The monitor could not accept the input change."
        case .hardwareReadback(let method):
            return "The display could not confirm the change through \(method)."
        }
    }
}

@MainActor
final class BrightnessControl {
    @MainActor
    private final class Entry {
        let connection: BrightnessConnection
        var route: BrightnessRoute?
        var shade: DimmingWindow?
        var shadeLevel: Double = 1

        init(_ id: DisplayConnectionID) { connection = BrightnessConnection(id) }

        func clearShade() {
            shade?.close()
            shade = nil
            shadeLevel = 1
        }

        func disconnect() {
            connection.invalidate()
            clearShade()
        }
    }

    private var entries: [CGDirectDisplayID: Entry] = [:]
    private var activeIDs: Set<CGDirectDisplayID>?
    private var stopped = false
    private let hardwareQueue = DispatchQueue(label: "displaydesk.brightness.io", qos: .userInitiated)

    private func onHardwareQueue<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            hardwareQueue.async { continuation.resume(returning: work()) }
        }
    }

    private func entry(for display: CGDirectDisplayID) -> Entry? {
        guard !stopped, activeIDs?.contains(display) != false,
              let identity = DisplayConnectionID(display) else {
            entries.removeValue(forKey: display)?.disconnect()
            return nil
        }
        if let current = entries[display], current.connection.identity == identity {
            return current
        }
        entries.removeValue(forKey: display)?.disconnect()
        let entry = Entry(identity)
        entries[display] = entry
        return entry
    }

    private func independentScreen(_ display: CGDirectDisplayID) -> NSScreen? {
        guard CGDisplayIsInMirrorSet(display) == 0 else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == display }
    }

    func read(_ id: CGDirectDisplayID) async -> BrightnessSample {
        guard let entry = entry(for: id) else { return BrightnessRoute.unavailable.sample(1) }
        if entry.shade != nil {
            if independentScreen(id) != nil { return BrightnessRoute.software.sample(entry.shadeLevel) }
            entry.clearShade()
        }
        let connection = entry.connection
        let hardware: (BrightnessRoute, Double)? = await onHardwareQueue {
            var value: Double = 0
            guard connection.matches() else { return nil }
            if DDReadAppleBacklight(id, &value) { return (.apple, value) }
            if DDReadMonitorVCP(id, 0x10, { connection.matches() }, &value) { return (.monitor, value) }
            return nil
        }
        guard entries[id] === entry, connection.matches() else { return BrightnessRoute.unavailable.sample(1) }
        if entry.shade != nil { return BrightnessRoute.software.sample(entry.shadeLevel) }
        let (route, value) = hardware ?? (independentScreen(id) == nil ? .unavailable : .software, 1)
        entry.route = route
        return route.sample(value)
    }

    func set(_ id: CGDirectDisplayID, value: Double) async throws -> BrightnessSample {
        try Task.checkCancellation()
        guard value.isFinite, (0...1).contains(value) else { throw DisplayBrightnessError.invalidValue }
        guard let entry = entry(for: id) else { throw DisplayBrightnessError.disconnected }
        let connection = entry.connection
        let ticket = connection.supersedeWrites()
        if entry.route == nil { _ = await read(id) }
        try Task.checkCancellation()
        guard connection.matches(ticket), entries[id] === entry else { throw CancellationError() }

        switch entry.route {
        case .apple, .monitor:
            let apple = entry.route == .apple
            let method: BrightnessRoute = apple ? .apple : .monitor
            let actual = try await writeHardware(id, entry: entry, ticket: ticket, value: value, apple: apple)
            return method.sample(actual)
        case .software:
            guard let screen = independentScreen(id) else {
                entry.clearShade()
                throw DisplayBrightnessError.noIndependentScreen
            }
            if value == 1 {
                entry.clearShade()
            } else {
                // Reserve 5% so a desktop with only software controls stays recoverable.
                let level = max(0.05, value)
                let shade = entry.shade ?? DimmingWindow(screen: screen)
                shade.setFrame(screen.frame, display: false)
                shade.alphaValue = 1 - level
                shade.orderFrontRegardless()
                entry.shade = shade
                entry.shadeLevel = level
            }
            return BrightnessRoute.software.sample(entry.shadeLevel)
        case .unavailable, nil:
            throw DisplayBrightnessError.noIndependentScreen
        }
    }

    func readAdjustment(_ id: CGDirectDisplayID, _ adjustment: MonitorAdjustment) async -> Double? {
        guard let entry = entry(for: id) else { return nil }
        let connection = entry.connection
        let feature = UInt8(adjustment.rawValue)
        let reading: Double? = await onHardwareQueue {
            var level: Double = 0
            return DDReadMonitorVCP(id, feature, { connection.matches() }, &level) ? level : nil
        }
        return entries[id] === entry && connection.matches() ? reading : nil
    }

    func setAdjustment(_ id: CGDirectDisplayID, _ adjustment: MonitorAdjustment,
                       value: Double) async throws -> Double {
        try Task.checkCancellation()
        guard value.isFinite, (0...1).contains(value) else { throw DisplayBrightnessError.invalidValue }
        guard let entry = entry(for: id) else { throw DisplayBrightnessError.disconnected }
        let ticket = entry.connection.supersedeWrites(for: UInt8(adjustment.rawValue))
        return try await writeHardware(id, entry: entry, ticket: ticket, value: value, apple: false)
    }

    private nonisolated static func loadInputs(_ id: CGDirectDisplayID, connection: BrightnessConnection,
                                               ticket: AdjustmentTicket) -> MonitorInputs? {
        var current: UInt16 = 0
        guard let capabilities = DDCopyInputCapabilities(id, { connection.matches(ticket) }, &current) else { return nil }
        return MonitorInputs(capabilities: capabilities as Data, current: current)
    }

    func inputSources(_ id: CGDirectDisplayID) async -> MonitorInputs? {
        guard let entry = entry(for: id), !Task.isCancelled else { return nil }
        let connection = entry.connection
        let ticket = connection.supersedeWrites(for: 0xf3)
        let menu = await withTaskCancellationHandler {
            await onHardwareQueue { Self.loadInputs(id, connection: connection, ticket: ticket) }
        } onCancel: {
            connection.cancel(ticket)
        }
        return entries[id] === entry && connection.matches(ticket) ? menu : nil
    }

    func setInputSource(_ id: CGDirectDisplayID, value: UInt16) async throws {
        try Task.checkCancellation()
        guard let entry = entry(for: id) else { throw DisplayBrightnessError.disconnected }
        let connection = entry.connection
        let ticket = connection.supersedeWrites(for: 0x60)
        let result: (listed: Bool, sent: Bool) = await withTaskCancellationHandler {
            await onHardwareQueue {
                guard let inputs = Self.loadInputs(id, connection: connection, ticket: ticket),
                      inputs.choices.contains(value) else { return (false, false) }
                let sent = DDRequestMonitorInput(id, inputs.current, value, { connection.matches(ticket) })
                return (true, sent)
            }
        } onCancel: {
            connection.cancel(ticket)
        }
        // A successful handoff can immediately disconnect the very display
        // selected in the menu. Receipt confirms dispatch, not the monitor's state.
        if result.sent { return }
        guard connection.matches(ticket) else { throw CancellationError() }
        throw result.listed ? DisplayBrightnessError.inputRequestFailed : DisplayBrightnessError.inputNotListed
    }

    private func writeHardware(_ id: CGDirectDisplayID, entry: Entry, ticket: AdjustmentTicket,
                               value: Double, apple: Bool) async throws -> Double {
        let connection = entry.connection
        let actual: Double? = await withTaskCancellationHandler {
            await onHardwareQueue {
                var level: Double = 0
                let current = { connection.matches(ticket) }
                let confirmed = apple
                    ? DDWriteAppleBacklight(id, value, current, &level)
                    : DDWriteMonitorVCP(id, ticket.feature, value, current, &level)
                return confirmed ? level : nil
            }
        } onCancel: {
            connection.cancel(ticket)
        }
        guard connection.matches(ticket), entries[id] === entry else { throw CancellationError() }
        guard let actual else {
            throw DisplayBrightnessError.hardwareReadback(apple ? "Apple backlight" : "DDC/CI")
        }
        return actual
    }

    func reconcile(active: Set<CGDirectDisplayID>) {
        activeIDs = active
        for (id, entry) in entries {
            guard active.contains(id), entry.connection.matches() else {
                entries.removeValue(forKey: id)?.disconnect()
                continue
            }
            if let shade = entry.shade {
                if let screen = independentScreen(id) {
                    shade.setFrame(screen.frame, display: true)
                } else {
                    entry.clearShade()
                    entry.route = nil
                }
            }
        }
    }

    func shutdown() {
        stopped = true
        for entry in entries.values { entry.disconnect() }
        entries.removeAll()
    }
}
