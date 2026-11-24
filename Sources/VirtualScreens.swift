import CoreGraphics
import Foundation

struct VirtualProfile: Identifiable, Codable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
    let hiDPI: Bool
    var reconnectOnLaunch: Bool
}

/// Main-thread controller. Each retained handle owns exactly one virtual screen.
final class VirtualScreens {
    private var handles: [CGDirectDisplayID: DDVirtualScreenHandle] = [:]
    private var serials: [CGDirectDisplayID: UInt32] = [:]
    private let defaults: UserDefaults?
    private(set) var profiles: [VirtualProfile]
    private var nextNumber = 1
    var ids: Set<CGDirectDisplayID> { Set(handles.keys) }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        profiles = defaults?.data(forKey: "virtualScreens").flatMap { try? JSONDecoder().decode([VirtualProfile].self, from: $0) } ?? []
    }

    func create(width: Int, height: Int, hiDPI: Bool, name: String? = nil,
                remember: Bool = false, reconnectOnLaunch: Bool = false) throws -> CGDirectDisplayID {
        let title = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while profiles.contains(where: { $0.name == "Screenfinch Display \(nextNumber)" }) { nextNumber += 1 }
        var serial = UInt32.random(in: 1...UInt32.max)
        while profiles.contains(where: { $0.id == serial }) || serials.values.contains(serial) { serial = UInt32.random(in: 1...UInt32.max) }
        let profile = VirtualProfile(id: serial, name: title.isEmpty ? "Screenfinch Display \(nextNumber)" : String(title.prefix(64)),
                                     width: width, height: height, hiDPI: hiDPI, reconnectOnLaunch: reconnectOnLaunch)
        let display = try connect(profile)
        nextNumber += 1
        if remember { profiles.append(profile); save() }
        return display
    }

    func connectedID(for profile: VirtualProfile) -> CGDirectDisplayID? { serials.first { $0.value == profile.id }?.key }

    func connect(_ profile: VirtualProfile) throws -> CGDirectDisplayID {
        if let existing = connectedID(for: profile) { return existing }
        let width = profile.width, height = profile.height, hiDPI = profile.hiDPI
        let scale = hiDPI ? 2 : 1
        let maximum = 8192 / scale
        guard (320...maximum).contains(width), (200...maximum).contains(height) else {
            throw VirtualScreenError("Width must be 320–\(maximum) and height must be 200–\(maximum) for this density.")
        }
        guard width * height * scale * scale <= 33_554_432 else {
            throw VirtualScreenError("The backing image exceeds 33.5 million pixels. Reduce the dimensions or turn off HiDPI.")
        }

        // macOS distinguishes simultaneous virtual panels by their hardware serial.
        let handle = try DDVirtualScreenHandle(name: profile.name,
                                               logicalWidth: UInt32(width),
                                               logicalHeight: UInt32(height),
                                               hiDPI: hiDPI,
                                               serial: profile.id)
        handles[handle.displayID] = handle
        serials[handle.displayID] = profile.id
        return handle.displayID
    }

    func remove(_ id: CGDirectDisplayID) {
        serials.removeValue(forKey: id)
        handles.removeValue(forKey: id)
    }

    func forget(_ profile: VirtualProfile) {
        if let connected = connectedID(for: profile) { remove(connected) }
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    func setReconnect(_ enabled: Bool, for profile: VirtualProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].reconnectOnLaunch = enabled
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { defaults?.set(data, forKey: "virtualScreens") }
    }

    func removeAll() {
        serials.removeAll()
        handles.removeAll()
    }
}

private struct VirtualScreenError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
