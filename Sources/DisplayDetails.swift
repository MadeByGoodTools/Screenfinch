import AppKit
import ColorSync
import CoreGraphics
import Darwin

@MainActor enum DisplayDetails {
    private typealias CopyDisplayInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private static let copyInfo: CopyDisplayInfo? = {
        guard let framework = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LOCAL | RTLD_LAZY),
              let symbol = dlsym(framework, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(symbol, to: CopyDisplayInfo.self)
    }()

    static func edid(for screen: DeskDisplay) -> Data? {
        guard let id = DisplaySystem.connectedID(for: screen) else { return nil }
        if let info = copyInfo?(id)?.takeRetainedValue() as? [String: Any] {
            for key in ["IODisplayEDIDOriginal", "IODisplayEDID"] {
                if let data = info[key] as? Data, validEDID(data), DisplaySystem.connectedID(for: screen) == id { return data }
            }
        }
        if let bytes = DDCopyMatchedEDID(id) as Data?, validEDID(bytes),
           DisplaySystem.connectedID(for: screen) == id { return bytes }
        return nil
    }

    private static func validEDID(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 128, bytes.count == (Int(bytes[126]) + 1) * 128,
              bytes.starts(with: [0, 255, 255, 255, 255, 255, 255, 0]) else { return false }
        return stride(from: 0, to: bytes.count, by: 128).allSatisfy { offset in
            bytes[offset..<(offset + 128)].reduce(UInt8(0), &+) == 0
        }
    }

    static func rotationChoices(for screen: DeskDisplay) -> [Int] {
        guard let id = DisplaySystem.connectedID(for: screen), CGDisplayIsActive(id) != 0,
              liveID(id: id, key: screen.key) == id, CGDisplayIsInMirrorSet(id) == 0, DDCanRotateDisplay(id) else { return [] }
        return [0, 90, 180, 270]
    }

    static func information(for screen: DeskDisplay) -> String {
        guard let id = DisplaySystem.connectedID(for: screen) else { return "\(screen.name) is disconnected." }
        let physical = CGDisplayScreenSize(id)
        let rect = CGDisplayBounds(id)
        var lines = [screen.name, "Display ID  \(id)", "Display UUID  \(screen.key)",
                     String(format: "Vendor  0x%04X   Product  0x%04X", CGDisplayVendorNumber(id), CGDisplayModelNumber(id))]
        if CGDisplaySerialNumber(id) != 0 {
            lines.append(String(format: "Serial number  0x%08X", CGDisplaySerialNumber(id)))
        }
        if let live = CGDisplayCopyDisplayMode(id) {
            lines.append("Desktop  \(live.width) × \(live.height)")
            lines.append("Backing pixels  \(live.pixelWidth) × \(live.pixelHeight)")
            lines.append(live.refreshRate > 0 ? String(format: "Refresh rate  %.2f Hz", live.refreshRate) : "Refresh rate  System managed")
        }
        lines.append(String(format: "Rotation  %.0f°", CGDisplayRotation(id)))
        lines.append(String(format: "Desktop origin  %.0f, %.0f", rect.minX, rect.minY))
        if physical.width > 0, physical.height > 0 {
            lines.append(String(format: "Reported size  %.0f × %.0f mm", physical.width, physical.height))
        }
        let source = CGDisplayMirrorsDisplay(id)
        lines.append(source == kCGNullDirectDisplay ? "Mirror source  None" : "Mirror source  Display \(source)")
        if let raw = edid(for: screen) {
            lines.append("EDID  \(raw[18]).\(raw[19]), \(raw.count) bytes")
        }
        return lines.joined(separator: "\n")
    }
}

private struct OrientationError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MonitorPanel writes a system orientation directly. A short-lived copy of this executable
// owns the change and its timeout, even if the main app crashes before confirmation.
@MainActor final class DisplayRotationPreview {
    fileprivate static let workerFlag = "--display-desk-rotation-preview"
    private let process = Process()
    private let socket: FileHandle
    private let id: CGDirectDisplayID
    private let key: String
    private let original: Int
    private let selected: Int

    init(id: CGDirectDisplayID, key: String, original: Int, selected: Int) throws {
        self.id = id
        self.key = key
        self.original = original
        self.selected = selected
        var ends = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else {
            throw OrientationError("Could not prepare rotation rollback.")
        }
        socket = FileHandle(fileDescriptor: ends[0], closeOnDealloc: true)
        let child = FileHandle(fileDescriptor: ends[1], closeOnDealloc: true)
        _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        for fd in ends {
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout.size(ofValue: on)))
        }
        guard let executable = Bundle.main.executableURL else { throw OrientationError("Could not find the rotation helper.") }
        process.executableURL = executable
        process.arguments = [Self.workerFlag, String(id), key, String(original), String(selected)]
        process.standardInput = child
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try child.close()
        guard receiveRotationByte(ends[0], timeout: 3000) == .ready else {
            if process.isRunning { process.terminate() }
            throw OrientationError("The rotation helper did not start.")
        }
        guard sendRotationByte(.start, to: ends[0]),
              receiveRotationByte(ends[0], timeout: 6000) == .applied else {
            throw OrientationError("macOS did not confirm the requested orientation.")
        }
    }

    func finish(keep: Bool) throws {
        let command: RotationByte = keep ? .keep : .revert
        let fd = socket.fileDescriptor
        if process.isRunning, sendRotationByte(command, to: fd),
           receiveRotationByte(fd, timeout: keep ? 1000 : 6000) == command { return }

        // The watchdog can already have expired, or the original monitor can have been unplugged.
        guard let live = DisplayDetails.liveID(id: id, key: key) else {
            if keep { throw OrientationError("The display disconnected before the change was kept.") }
            return
        }
        let current = Int(CGDisplayRotation(live).rounded())
        if keep {
            throw OrientationError("The rotation preview expired or the display changed. Select the angle again.")
        }
        if current == selected {
            // Retry through the same verified mechanism when an earlier restore was interrupted.
            let recovery = try DisplayRotationPreview(id: live, key: key, original: selected, selected: original)
            try recovery.finish(keep: true)
        }
    }
}

private enum RotationByte: UInt8 {
    case ready = 1, start, applied, keep, revert, failed
}

@discardableResult private func sendRotationByte(_ value: RotationByte, to fd: Int32) -> Bool {
    var byte = value.rawValue
    return Darwin.send(fd, &byte, 1, 0) == 1
}

private func receiveRotationByte(_ fd: Int32, timeout: Int32) -> RotationByte? {
    var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&event, 1, timeout) > 0 else { return nil }
    var byte: UInt8 = 0
    guard Darwin.recv(fd, &byte, 1, 0) == 1 else { return nil }
    return RotationByte(rawValue: byte)
}

extension DisplayDetails {
    fileprivate static func liveID(id: CGDirectDisplayID, key: String) -> CGDirectDisplayID? {
        func matches(_ connection: CGDirectDisplayID) -> Bool {
            guard CGDisplayIsOnline(connection) != 0,
                  let ref: Unmanaged<CFUUID> = CGDisplayCreateUUIDFromDisplayID(connection) else { return false }
            return (CFUUIDCreateString(nil, ref.takeRetainedValue()) as String) == key
        }
        if matches(id) { return id }
        // Rotation or a driver mode change may transiently renumber the same monitor.
        guard UUID(uuidString: key) != nil, let uuid = CFUUIDCreateFromString(nil, key as CFString) else { return nil }
        let connected = CGDisplayGetDisplayIDFromUUID(uuid)
        return connected != kCGNullDirectDisplay && matches(connected) ? connected : nil
    }

    private static func awaitAngle(_ angle: Int, id: CGDirectDisplayID, key: String, seconds: Double) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if let live = liveID(id: id, key: key), abs(CGDisplayRotation(live) - Double(angle)) < 0.1 { return true }
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.025), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        } while ProcessInfo.processInfo.systemUptime < end
        return false
    }

    /// Call before normal app startup. A private socket carries the decision and closes if its owner dies.
    static func handleRotationWorker() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == DisplayRotationPreview.workerFlag else { return false }
        let fd = STDIN_FILENO
        guard args.count == 6, let id = UInt32(args[2]), let original = Int(args[4]), let selected = Int(args[5]),
              original != selected, [0, 90, 180, 270].contains(original), [0, 90, 180, 270].contains(selected),
              sendRotationByte(.ready, to: fd), receiveRotationByte(fd, timeout: 3000) == .start else { return true }
        let key = args[3]
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let update: CGDisplayReconfigurationCallBack = { _, _, _ in }
        guard CGDisplayRegisterReconfigurationCallback(update, nil) == .success else {
            sendRotationByte(.failed, to: fd)
            return true
        }
        defer { CGDisplayRemoveReconfigurationCallback(update, nil) }
        guard let target = liveID(id: id, key: key), CGDisplayIsInMirrorSet(target) == 0, DDCanRotateDisplay(target),
              CGDisplayRotation(target) == Double(original), DDRequestRotation(target, Int32(selected)) else {
            sendRotationByte(.failed, to: fd)
            return true
        }
        let applied = awaitAngle(selected, id: id, key: key, seconds: 4)
        if applied, sendRotationByte(.applied, to: fd) {
            let decision = receiveRotationByte(fd, timeout: 19000)
            // Consume WindowServer events accumulated while the UI was awaiting a decision.
            _ = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: false)
            if decision == .keep, let live = liveID(id: id, key: key),
               CGDisplayRotation(live) == Double(selected), sendRotationByte(.keep, to: fd) { return true }
        } else {
            sendRotationByte(.failed, to: fd)
        }
        guard let connected = liveID(id: id, key: key) else { sendRotationByte(.revert, to: fd); return true }
        let live = Int(CGDisplayRotation(connected).rounded())
        if applied && live != selected {
            // The user or another app already chose a different angle.
            sendRotationByte(.revert, to: fd)
            return true
        }
        // Submit the original angle even after a delayed/declined apply to cancel an in-flight request.
        let restored = DDRequestRotation(connected, Int32(original)) && awaitAngle(original, id: id, key: key, seconds: 4)
        sendRotationByte(restored ? .revert : .failed, to: fd)
        return true
    }
}
