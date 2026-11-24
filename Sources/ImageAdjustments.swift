import ColorSync
import CoreGraphics
import Darwin
import Foundation

struct DeskColorValues: Equatable, Codable {
    var gamma: Double = 1
    var warmth: Double = 0
    var contrast: Double = 1

    fileprivate var valid: Bool {
        (0.6...1.6).contains(gamma) && (0...1).contains(warmth) && (0.6...1.4).contains(contrast)
    }
}

private struct AdjustmentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private struct QuartzCurves {
    let red: [Float]
    let green: [Float]
    let blue: [Float]

    init(reading display: CGDirectDisplayID) throws {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard (2...65_536).contains(capacity) else {
            throw AdjustmentError("This display has no readable color transfer table.")
        }
        var r = [Float](repeating: 0, count: Int(capacity)), g = r, b = r
        var count: UInt32 = 0
        let result = CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &count)
        guard result == .success, count >= 2, count <= capacity else {
            throw AdjustmentError("macOS could not read this display’s color calibration.")
        }
        red = Array(r.prefix(Int(count)))
        green = Array(g.prefix(Int(count)))
        blue = Array(b.prefix(Int(count)))
        guard [red, green, blue].allSatisfy({ $0.allSatisfy { (0...1).contains($0) } }) else {
            throw AdjustmentError("The current display calibration is outside the range supported by Quartz adjustments.")
        }
    }

    private init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    func adjusting(_ settings: DeskColorValues) -> QuartzCurves {
        // Remap the input to each saved calibration curve. Warmth reduces green and
        // blue contributions while preserving the original black point of every channel.
        let last = red.count - 1
        func channel(_ curve: [Float], gain: Double) -> [Float] {
            (0...last).map { index in
                let tone = pow(Double(index) / Double(last), 1 / settings.gamma)
                let level = min(1, max(0, (tone - 0.5) * settings.contrast + 0.5))
                let position = level * gain * Double(last)
                let lower = Int(position)
                let fraction = Float(position - Double(lower))
                return curve[lower] + (curve[min(last, lower + 1)] - curve[lower]) * fraction
            }
        }
        return QuartzCurves(red: channel(red, gain: 1), green: channel(green, gain: 1 - 0.14 * settings.warmth),
                            blue: channel(blue, gain: 1 - 0.48 * settings.warmth))
    }

    func matches(_ other: QuartzCurves, tolerance: Float = 0.00005) -> Bool {
        guard red.count == other.red.count else { return false }
        func close(_ a: [Float], _ b: [Float]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= tolerance } }
        return close(red, other.red) && close(green, other.green) && close(blue, other.blue)
    }

    func install(on display: CGDirectDisplayID) throws {
        let error = CGSetDisplayTransferByTable(display, UInt32(red.count), red, green, blue)
        guard error == .success else { throw AdjustmentError("macOS rejected the color table (Quartz error \(error.rawValue)).") }
    }
}

private struct ColorEdit {
    let key: String
    let original: QuartzCurves
    let applied: QuartzCurves
    let values: DeskColorValues
    var verified = true
}

/// The native HDR mode switch is offered on compatible external display links.
/// An XDR panel's EDR headroom is a different capability.
private struct NativeHDR {
    typealias Read = @convention(c) (CGDirectDisplayID) -> Int32
    typealias Write = @convention(c) (CGDirectDisplayID, Bool) -> Int32
    let supports: Read
    let enabled: Read
    let write: Write

    static let system: NativeHDR? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let support = dlsym(library, "SLSDisplaySupportsHDRMode"),
              let state = dlsym(library, "SLSDisplayIsHDRModeEnabled"),
              let set = dlsym(library, "SLSDisplaySetHDRModeEnabled") else {
            dlclose(library)
            return nil
        }
        return NativeHDR(supports: unsafeBitCast(support, to: Read.self), enabled: unsafeBitCast(state, to: Read.self),
                         write: unsafeBitCast(set, to: Write.self))
    }()

    func state(_ id: CGDirectDisplayID) -> Bool? {
        guard supports(id) == 1 else { return nil }
        switch enabled(id) { case 0: return false; case 1: return true; default: return nil }
    }

    @MainActor func set(_ target: Bool, display: CGDirectDisplayID, stillSelected: () -> Bool) async throws {
        guard stillSelected(), let current = state(display) else { throw AdjustmentError("This display mode has no native HDR switch.") }
        if current == target { return }
        let code = write(display, target)
        guard code == 0 else { throw AdjustmentError("macOS rejected the HDR mode change (display error \(code)).") }
        for attempt in 0...20 {
            if stillSelected(), state(display) == target { return }
            if attempt < 20 { try await Task.sleep(nanoseconds: 150_000_000) }
        }
        throw AdjustmentError("macOS did not confirm the requested HDR mode for this display.")
    }
}

@MainActor
final class ImageAdjustments {
    private var edits: [CGDirectDisplayID: ColorEdit] = [:]
    private var mirrorSources = Set<CGDirectDisplayID>()
    private var switchingHDR = Set<String>()

    /// Controls are available only when the current table can be read and restored.
    func settings(for screen: DeskDisplay) -> DeskColorValues? {
        guard individual(screen.id, key: screen.key), screen.mirrorSource == nil,
              let table = try? QuartzCurves(reading: screen.id) else { return nil }
        return ownedEdit(screen.id, key: screen.key, current: table)?.values ?? DeskColorValues()
    }

    func apply(_ values: DeskColorValues, to screen: DeskDisplay) throws {
        guard values.valid else { throw AdjustmentError("Choose gamma 0.6–1.6, warmth 0–1, and contrast 0.6–1.4.") }
        if values == DeskColorValues() { try reset(screen); return }
        guard screen.mirrorSource == nil, individual(screen.id, key: screen.key) else { throw unavailable() }
        let before = try QuartzCurves(reading: screen.id)
        let previous = ownedEdit(screen.id, key: screen.key, current: before)
        if previous?.values == values { return }
        let original = previous?.original ?? before
        let requested = original.adjusting(values)
        guard individual(screen.id, key: screen.key) else { throw unavailable() }
        try requested.install(on: screen.id)
        // Keep the original even if a readback briefly fails during a display event.
        edits[screen.id] = ColorEdit(key: screen.key, original: original, applied: requested, values: values, verified: false)
        let observed = try QuartzCurves(reading: screen.id)
        guard requested.matches(observed, tolerance: 0.0041) else {
            guard individual(screen.id, key: screen.key) else { throw unavailable() }
            try before.install(on: screen.id)
            let rolledBack = try QuartzCurves(reading: screen.id)
            guard before.matches(rolledBack, tolerance: 0.0041) else {
                edits[screen.id] = ColorEdit(key: screen.key, original: original, applied: rolledBack, values: values)
                throw AdjustmentError("macOS did not confirm the adjustment or restoration. Reset the image adjustments to retry.")
            }
            edits[screen.id] = previous.map {
                ColorEdit(key: $0.key, original: $0.original, applied: rolledBack, values: $0.values)
            }
            throw AdjustmentError("macOS returned a different color table. The previous table was restored.")
        }
        edits[screen.id] = ColorEdit(key: screen.key, original: original, applied: observed, values: values)
    }

    func reset(_ screen: DeskDisplay) throws {
        guard edits[screen.id]?.key == screen.key else { return }
        guard screen.mirrorSource == nil else { throw unavailable() }
        try restore(screen.id, key: screen.key)
    }

    func hdrEnabled(for screen: DeskDisplay) -> Bool? {
        guard screen.mirrorSource == nil, individual(screen.id, key: screen.key) else { return nil }
        return NativeHDR.system?.state(screen.id)
    }

    func setHDR(_ enabled: Bool, for screen: DeskDisplay) async throws {
        guard let hdr = NativeHDR.system, screen.mirrorSource == nil else { throw AdjustmentError("Native HDR control is unavailable.") }
        guard switchingHDR.insert(screen.key).inserted else { throw AdjustmentError("An HDR mode change is in progress.") }
        defer { switchingHDR.remove(screen.key) }
        try await hdr.set(enabled, display: screen.id) { self.individual(screen.id, key: screen.key) }
    }

    func reconcile(_ screens: [DeskDisplay]) {
        mirrorSources = Set(screens.compactMap(\.mirrorSource))
        for (id, edit) in edits {
            // A display link can return with a new numeric ID after reconnection.
            var currentID = id
            if !screens.contains(where: { $0.id == id && $0.key == edit.key }) {
                let matches = screens.filter { $0.key == edit.key }
                guard matches.count == 1, let match = matches.first, edits[match.id] == nil else { continue }
                edits[id] = nil
                currentID = match.id
                edits[currentID] = edit
            }
            if individual(currentID, key: edit.key), let table = try? QuartzCurves(reading: currentID) {
                _ = ownedEdit(currentID, key: edit.key, current: table)
            }
        }
    }

    func shutdown() {
        for (id, edit) in edits { try? restore(id, key: edit.key) }
        edits.removeAll()
    }

    private func restore(_ id: CGDirectDisplayID, key: String) throws {
        guard individual(id, key: key) else { throw unavailable() }
        let current = try QuartzCurves(reading: id)
        // A ColorSync profile change or another utility may have taken control.
        guard let edit = ownedEdit(id, key: key, current: current) else { return }
        guard individual(id, key: key) else { throw unavailable() }
        try edit.original.install(on: id)
        let readback = try QuartzCurves(reading: id)
        guard edit.original.matches(readback, tolerance: 0.0041) else {
            edits[id] = ColorEdit(key: key, original: edit.original, applied: readback, values: edit.values)
            throw AdjustmentError("macOS did not confirm restoration of the saved calibration.")
        }
        edits[id] = nil
    }

    private func ownedEdit(_ id: CGDirectDisplayID, key: String, current: QuartzCurves) -> ColorEdit? {
        guard let edit = edits[id] else { return nil }
        let tolerance: Float = edit.verified ? 0 : 0.0041
        guard edit.key == key, edit.applied.matches(current, tolerance: tolerance) else {
            edits[id] = nil
            return nil
        }
        return edit
    }

    private func individual(_ id: CGDirectDisplayID, key: String) -> Bool {
        guard id != kCGNullDirectDisplay, CGDisplayIsOnline(id) != 0, CGDisplayIsActive(id) != 0,
              !mirrorSources.contains(id), CGDisplayIsInMirrorSet(id) == 0,
              CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return false }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String == key
        }
        return key == "session-\(id)-\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    private func unavailable() -> AdjustmentError { AdjustmentError("Select a connected display outside a mirror group.") }
}
