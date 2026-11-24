import AppKit
import ColorSync
import CoreGraphics
import IOKit.graphics

struct DeskMode: Identifiable, Hashable, Codable {
    let id: Int
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let hz: Double
    var nativeNumber: Int32? = nil

    var isHiDPI: Bool { pixelWidth > width && pixelHeight > height }

    fileprivate func hasSameFormat(as other: DeskMode) -> Bool {
        width == other.width && height == other.height &&
        pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight &&
        abs(hz - other.hz) < 0.001
    }
}

private extension DeskMode {
    init(_ mode: CGDisplayMode) {
        self.init(id: Int(mode.ioDisplayModeID), width: mode.width, height: mode.height,
                  pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                  hz: mode.refreshRate.isFinite ? max(0, mode.refreshRate) : 0)
    }
}

struct DeskDisplay: Identifiable {
    let id: CGDirectDisplayID
    let key: String
    let name: String
    let builtIn: Bool
    let isMain: Bool
    let mirrorSource: CGDirectDisplayID?
    let bounds: CGRect
    let current: DeskMode?
    let modes: [DeskMode]
    var defaultLogicalWidth: Int?
}

private struct DisplayFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }

    static func check(_ code: CGError, _ action: String) throws {
        guard code == .success else {
            throw DisplayFailure("macOS could not \(action) (Quartz error \(code.rawValue)).")
        }
    }
}

private struct Panel {
    let id: CGDirectDisplayID
    let key: String
    let uuid: CFUUID?
    let sourceID: CGDirectDisplayID?
    let mode: CGDisplayMode?
    let nativeAtCapture: NativeHiDPIModes.Entry?
    let bounds: CGRect
    var origin: CGPoint { bounds.origin }

    init(id: CGDirectDisplayID) {
        self.id = id
        let uuidRef: Unmanaged<CFUUID>? = CGDisplayCreateUUIDFromDisplayID(id)
        uuid = uuidRef?.takeRetainedValue()
        if let uuid {
            key = CFUUIDCreateString(nil, uuid) as String
        } else {
            // A provisional screen with no ColorSync identity may only match its current connection.
            key = "session-\(id)-\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
        }
        let source = CGDisplayMirrorsDisplay(id)
        sourceID = source == kCGNullDirectDisplay ? nil : source
        mode = CGDisplayCopyDisplayMode(id)
        nativeAtCapture = NativeHiDPIModes.active(id, quartz: mode)
        bounds = CGDisplayBounds(id)
    }

    var current: DeskMode? {
        guard let mode else { return nil }
        // Keep the picker identity stable while a supplemental mode is active.
        let flags = mode.ioFlags
        if flags & UInt32(kDisplayModeValidForMirroringFlag) != 0 && flags & UInt32(kDisplayModeSafeFlag) == 0,
           let value = nativeAtCapture, value.selectable {
            return value.mode
        }
        return DeskMode(mode)
    }

    func deviceName() -> String {
        if let uuid,
           let details = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue() as? [String: Any],
           let name = details[kColorSyncDeviceDescription.takeUnretainedValue() as String] as? String,
           !name.isEmpty {
            return name
        }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in display" : "Display \(id)"
    }

    func quartzModes() -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        return CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    }

    func availableModes(in all: [CGDisplayMode]) -> [CGDisplayMode] {
        let excluded = UInt32(kDisplayModeInterlacedFlag | kDisplayModeNeverShowFlag)
        let safe = UInt32(kDisplayModeValidFlag | kDisplayModeSafeFlag)
        return all.filter {
            $0.width > 0 && $0.height > 0 && $0.isUsableForDesktopGUI() &&
            ($0.ioFlags & excluded) == 0 && ($0.ioFlags & safe) == safe
        }
    }

    func menuModes(_ all: [CGDisplayMode]) -> [DeskMode] {
        // Prefer the exact active timing when Quartz exposes duplicate color-depth variants.
        var result = [DeskMode]()
        if let current { result.append(current) }
        for raw in availableModes(in: all) {
            let mode = DeskMode(raw)
            if !result.contains(where: { $0.id == mode.id || $0.hasSameFormat(as: mode) }) {
                result.append(mode)
            }
        }
        if sourceID == nil, let native = NativeHiDPIModes.table(id, quartz: mode) {
            let quartzFormats = all.map(DeskMode.init)
            for entry in native.entries where entry.selectable {
                let supplemental = entry.mode
                // Retain Quartz's existing filtering and prefer its public route
                // whenever that timing already occurs in the Quartz catalogue.
                if !quartzFormats.contains(where: { $0.hasSameFormat(as: supplemental) }),
                   !result.contains(where: { $0.hasSameFormat(as: supplemental) }) {
                    result.append(supplemental)
                }
            }
        }
        return result.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth > $1.pixelWidth }
            if $0.pixelHeight != $1.pixelHeight { return $0.pixelHeight > $1.pixelHeight }
            return $0.hz > $1.hz
        }
    }

    func resolveMode(_ requested: DeskMode) throws -> ModeRoute {
        if let number = requested.nativeNumber {
            guard requested.id == Int(UInt32.max) + 1 + Int(number),
                  let native = NativeHiDPIModes.table(id, quartz: mode) else {
                throw DisplayFailure("The supplemental display mode is no longer available.")
            }
            let matches = native.entries.filter { $0.selectable && $0.mode.hasSameFormat(as: requested) }
            if let exact = matches.first(where: { $0.number == number }) { return .native(exact.number) }
            if matches.count == 1 { return .native(matches[0].number) }
            throw DisplayFailure("The supplemental display timing changed. Choose it again.")
        }
        // The active mode can be valid even when Quartz omits it from the selectable list.
        if let mode, DeskMode(mode) == requested { return .quartz(mode) }
        let matches = availableModes(in: quartzModes()).filter { DeskMode($0).hasSameFormat(as: requested) }
        if let result = matches.first(where: { Int($0.ioDisplayModeID) == requested.id }) ?? matches.first {
            return .quartz(result)
        }
        throw DisplayFailure("The selected resolution or refresh rate is no longer available.")
    }
}

private enum ModeRoute {
    case quartz(CGDisplayMode)
    case native(Int32)

    func configure(_ config: CGDisplayConfigRef, display: CGDirectDisplayID) -> CGError {
        switch self {
        case let .quartz(mode): return CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        case let .native(number): return NativeHiDPIModes.configure(config, display: display, number: number)
        }
    }
}

private struct DisplayState {
    let panels: [Panel]
    let mainID = CGMainDisplayID()

    init() throws {
        var reported: UInt32 = 0
        try DisplayFailure.check(CGGetOnlineDisplayList(0, nil, &reported), "count online displays")
        // Leave room for a screen that connects between the count and list calls.
        var capacity = max(8, Int(reported) + 1)
        while true {
            var ids = [CGDirectDisplayID](repeating: 0, count: capacity)
            var found: UInt32 = 0
            try DisplayFailure.check(CGGetOnlineDisplayList(UInt32(capacity), &ids, &found), "read online displays")
            if Int(found) < capacity {
                panels = ids.prefix(Int(found)).filter { CGDisplayIsOnline($0) != 0 }.map(Panel.init)
                return
            }
            capacity *= 2
        }
    }

    /// Prefer the selected connection; allow a unique matching UUID when macOS renumbers it.
    func find(id: CGDirectDisplayID, key: String) -> Panel? {
        if let exact = panels.first(where: { $0.id == id && $0.key == key }) { return exact }
        let matches = panels.filter { $0.key == key }
        return matches.count == 1 ? matches[0] : nil
    }

    func require(_ display: DeskDisplay) throws -> Panel {
        guard let result = find(id: display.id, key: display.key) else {
            throw DisplayFailure("\(display.name) is no longer connected.")
        }
        return result
    }

    func source(of panel: Panel) -> Panel? {
        guard let source = panel.sourceID else { return nil }
        return panels.first { $0.id == source }
    }

    var desktopFrames: [CGDirectDisplayID: CGRect] {
        Dictionary(uniqueKeysWithValues: panels.filter { $0.sourceID == nil && !$0.bounds.isEmpty }.map { ($0.id, $0.bounds) })
    }
}

enum DisplaySystem {
    static func connectedID(for screen: DeskDisplay) -> CGDirectDisplayID? {
        try? DisplayState().require(screen).id
    }

    @MainActor static func list() throws -> [DeskDisplay] {
        let state = try DisplayState()
        var screenNames = [CGDirectDisplayID: String]()
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                screenNames[number.uint32Value] = screen.localizedName
            }
        }
        return state.panels.map { panel in
            let quartz = panel.quartzModes()
            let baseWidth = quartz.first { $0.ioFlags & UInt32(kDisplayModeDefaultFlag) != 0 }?.width
            return DeskDisplay(id: panel.id, key: panel.key, name: screenNames[panel.id] ?? panel.deviceName(),
                        builtIn: CGDisplayIsBuiltin(panel.id) != 0, isMain: CGDisplayIsMain(panel.id) != 0,
                        mirrorSource: panel.sourceID, bounds: panel.bounds, current: panel.current, modes: panel.menuModes(quartz),
                        defaultLogicalWidth: baseWidth)
        }
    }
}

enum DeskEdge: String, CaseIterable {
    case left, right, above, below

    fileprivate func joins(_ moving: CGRect, to reference: CGRect) -> Bool {
        let verticalOverlap = min(moving.maxY, reference.maxY) > max(moving.minY, reference.minY)
        let horizontalOverlap = min(moving.maxX, reference.maxX) > max(moving.minX, reference.minX)
        switch self {
        case .left: return moving.maxX == reference.minX && verticalOverlap
        case .right: return moving.minX == reference.maxX && verticalOverlap
        case .above: return moving.maxY == reference.minY && horizontalOverlap
        case .below: return moving.minY == reference.maxY && horizontalOverlap
        }
    }
}

enum DeskLayout {
    /// Quartz's desktop origin belongs to the main display. Translate all desktops together.
    static func origins(_ frames: [CGDirectDisplayID: CGRect], main: CGDirectDisplayID) throws -> [CGDirectDisplayID: CGPoint] {
        guard let anchor = frames[main] else { throw DisplayFailure("Choose an independent display as the main display.") }
        return frames.mapValues { CGPoint(x: $0.minX - anchor.minX, y: $0.minY - anchor.minY) }
    }

    static func move(_ id: CGDirectDisplayID, beside reference: CGDirectDisplayID, edge: DeskEdge,
                     frames: [CGDirectDisplayID: CGRect], main: CGDirectDisplayID) throws -> [CGDirectDisplayID: CGPoint] {
        guard id != reference, let panel = frames[id], let anchor = frames[reference] else {
            throw DisplayFailure("Choose two different independent displays to arrange.")
        }
        if edge.joins(panel, to: anchor) { return try origins(frames, main: main) }

        let obstacles = frames.filter { $0.key != id }
        let isSide = edge == .left || edge == .right
        // Slide along the chosen edge to find the nearest unobstructed placement.
        let length = isSide ? panel.height : panel.width
        let low = (isSide ? anchor.minY : anchor.minX) - length + 1
        let high = (isSide ? anchor.maxY : anchor.maxX) - 1
        let center = ((isSide ? anchor.midY : anchor.midX) - length / 2).rounded()
        var offsets: Set<CGFloat> = [center, low, high]
        for frame in obstacles.values {
            let start = (isSide ? frame.minY : frame.minX) - length
            let end = isSide ? frame.maxY : frame.maxX
            // Include a one-point contact as well as each nonoverlapping boundary.
            offsets.formUnion([start, start + 1, end - 1, end])
        }
        let ordered = offsets.filter { low...high ~= $0 }.sorted {
            let a = abs($0 - center), b = abs($1 - center)
            return a == b ? $0 < $1 : a < b
        }
        for offset in ordered {
            let point: CGPoint
            switch edge {
            case .left: point = CGPoint(x: anchor.minX - panel.width, y: offset)
            case .right: point = CGPoint(x: anchor.maxX, y: offset)
            case .above: point = CGPoint(x: offset, y: anchor.minY - panel.height)
            case .below: point = CGPoint(x: offset, y: anchor.maxY)
            }
            let proposed = CGRect(origin: point, size: panel.size)
            guard !obstacles.values.contains(where: { !$0.intersection(proposed).isEmpty }) else { continue }
            var positioned = obstacles
            positioned[id] = proposed
            if connected(positioned, from: main) { return try origins(positioned, main: main) }
        }
        throw DisplayFailure("That edge is occupied or would leave a display detached. Choose another edge.")
    }

    private static func connected(_ frames: [CGDirectDisplayID: CGRect], from main: CGDirectDisplayID) -> Bool {
        var seen: Set<CGDirectDisplayID> = [main]
        var pending = [main]
        while let current = pending.popLast(), let frame = frames[current] {
            for (id, other) in frames where !seen.contains(id) {
                if DeskEdge.allCases.contains(where: { $0.joins(frame, to: other) }) {
                    seen.insert(id)
                    pending.append(id)
                }
            }
        }
        return seen.count == frames.count
    }
}

private func configure(scope: CGConfigureOption, _ edits: (CGDisplayConfigRef) throws -> Void) throws {
    var config: CGDisplayConfigRef?
    try DisplayFailure.check(CGBeginDisplayConfiguration(&config), "begin the display change")
    guard let config else { throw DisplayFailure("macOS did not create a display configuration.") }
    do {
        try edits(config)
    } catch {
        CGCancelDisplayConfiguration(config)
        throw error
    }
    // A completion call always consumes the configuration, including when the commit fails.
    try DisplayFailure.check(CGCompleteDisplayConfiguration(config, scope), "apply the display change")
}

private func setOrigin(_ point: CGPoint, of display: CGDirectDisplayID, in config: CGDisplayConfigRef) throws {
    guard let x = Int32(exactly: point.x), let y = Int32(exactly: point.y) else {
        throw DisplayFailure("The display position is outside the Quartz coordinate range.")
    }
    try DisplayFailure.check(CGConfigureDisplayOrigin(config, display, x, y), "position the display")
}

private enum DisplayEdit {
    case mode(DeskDisplay, DeskMode)
    case mirror(DeskDisplay, DeskDisplay?)
    case main(DeskDisplay)
    case move(DeskDisplay, DeskDisplay, DeskEdge)

    var display: DeskDisplay {
        switch self {
        case let .mode(display, _), let .mirror(display, _), let .main(display), let .move(display, _, _): return display
        }
    }

    func isApplied(in state: DisplayState) -> Bool {
        guard let panel = state.find(id: display.id, key: display.key) else { return false }
        switch self {
        case let .mode(_, selected):
            if let number = selected.nativeNumber {
                guard let active = panel.nativeAtCapture, active.selectable,
                      active.mode.hasSameFormat(as: selected) else { return false }
                if active.number == number { return true }
                if case let .native(updated)? = try? panel.resolveMode(selected) { return active.number == updated }
                return false
            }
            return panel.current?.hasSameFormat(as: selected) == true
        case let .mirror(_, source):
            guard let source else { return panel.sourceID == nil }
            guard let master = state.find(id: source.id, key: source.key) else { return false }
            return panel.sourceID == master.id
        case .main: return panel.id == state.mainID && panel.sourceID == nil
        case let .move(_, relative, edge):
            guard panel.sourceID == nil, let other = state.find(id: relative.id, key: relative.key),
                  other.sourceID == nil, other.id != panel.id else { return false }
            return edge.joins(panel.bounds, to: other.bounds)
        }
    }

    func layout(in state: DisplayState) throws -> [CGDirectDisplayID: CGPoint] {
        let id = try state.require(display).id
        switch self {
        case .main: return try DeskLayout.origins(state.desktopFrames, main: id)
        case let .move(_, reference, edge):
            return try DeskLayout.move(id, beside: state.require(reference).id, edge: edge,
                                       frames: state.desktopFrames, main: state.mainID)
        default: return [:]
        }
    }

    func apply(in state: DisplayState, scope: CGConfigureOption) throws {
        let panel = try state.require(display)
        switch self {
        case let .mode(_, selected):
            guard panel.sourceID == nil else { throw DisplayFailure("Change the display mode on the source of this mirror group.") }
            guard panel.mode != nil else { throw DisplayFailure("macOS has not reported this display’s current mode yet.") }
            try configure(scope: scope) { config in
                // WindowServer can renumber a timing when a cable or topology changes.
                // Reconfirm the connection and native timing inside the transaction.
                let live = selected.nativeNumber == nil ? panel : try DisplayState().require(display)
                guard live.sourceID == nil, live.id == panel.id else {
                    throw DisplayFailure("The display connection changed. Choose a current resolution.")
                }
                let raw = try live.resolveMode(selected)
                try DisplayFailure.check(raw.configure(config, display: live.id), "select this display mode")
            }
        case let .mirror(_, source):
            let master = try source.map { try state.require($0) }
            if let master {
                guard master.id != panel.id else { throw DisplayFailure("Choose a different display as the mirror source.") }
                guard master.sourceID == nil else { throw DisplayFailure("Choose the source display of the existing mirror group.") }
                guard !state.panels.contains(where: { $0.sourceID == panel.id }) else {
                    throw DisplayFailure("Disconnect this display’s existing mirrors before choosing another source.")
                }
            }
            try configure(scope: scope) { config in
                if master == nil && panel.sourceID == nil {
                    // Quartz rejects detaching a screen twice. Setting its independent origin
                    // promotes the same extended layout to the login session when Keep is clicked.
                    try setOrigin(panel.origin, of: panel.id, in: config)
                } else {
                    try DisplayFailure.check(CGConfigureDisplayMirrorOfDisplay(config, panel.id, master?.id ?? kCGNullDirectDisplay),
                                             "change this display’s mirror source")
                }
            }
        case .main, .move:
            let positions = try layout(in: state)
            let current = state.desktopFrames
            try configure(scope: scope) { config in
                for (id, point) in positions.sorted(by: { $0.key < $1.key }) {
                    if scope == .forSession || point != current[id]?.origin {
                        try setOrigin(point, of: id, in: config)
                    }
                }
            }
        }
    }
}

@MainActor final class DisplayPreview {
    private final class Preview {
        let edit: DisplayEdit
        let before: DisplayState
        var after: DisplayState?
        var firstNativeTransition: DisplayState?
        init(_ edit: DisplayEdit, _ before: DisplayState) {
            self.edit = edit
            self.before = before
        }
    }

    private var active: Preview?
    private var rotation: DisplayRotationPreview?
    var pending: Bool { active != nil || rotation != nil }

    func previewMode(display: DeskDisplay, mode: DeskMode) throws { try start(.mode(display, mode)) }

    func previewMirror(display: DeskDisplay, source: DeskDisplay?) throws { try start(.mirror(display, source)) }

    func previewMain(display: DeskDisplay) throws { try start(.main(display)) }

    func previewMove(display: DeskDisplay, relativeTo other: DeskDisplay, edge: DeskEdge) throws {
        try start(.move(display, other, edge))
    }

    func previewRotation(display: DeskDisplay, degrees: Int) throws {
        guard !pending else { throw DisplayFailure("Keep or revert the current preview first.") }
        guard DisplayDetails.rotationChoices(for: display).contains(degrees),
              let id = DisplaySystem.connectedID(for: display),
              let original = Int(exactly: CGDisplayRotation(id)), [0, 90, 180, 270].contains(original) else {
            throw DisplayFailure("This display does not currently support that rotation.")
        }
        if degrees != original {
            rotation = try DisplayRotationPreview(id: id, key: display.key, original: original, selected: degrees)
        }
    }

    private func start(_ edit: DisplayEdit) throws {
        guard !pending else { throw DisplayFailure("Keep or revert the current preview first.") }
        let baseline = try DisplayState()
        _ = try baseline.require(edit.display)
        if edit.isApplied(in: baseline) { return }
        try edit.apply(in: baseline, scope: .forAppOnly)
        let preview = Preview(edit, baseline)
        active = preview
        observe(preview, retries: 12)
    }

    // Quartz can deliver the new topology on the next WindowServer event. Keep the first
    // confirmed state so rollback can distinguish our changes from later edits in System Settings.
    private func observe(_ preview: Preview, retries: Int) {
        guard active === preview else { return }
        if let live = try? DisplayState() {
            if preview.edit.isApplied(in: live) {
                preview.after = live
                return
            }
            // A window-server timing may be listed but fall back to a different
            // actual mode. Remember that first change for rollback; Keep still
            // requires exact logical size, backing scale and refresh readback.
            if preview.firstNativeTransition == nil, case let .mode(target, requested) = preview.edit,
               requested.nativeNumber != nil,
               let old = preview.before.find(id: target.id, key: target.key)?.current,
               let observed = live.find(id: target.id, key: target.key)?.current, old != observed {
                preview.firstNativeTransition = live
            }
        }
        if retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak preview] in
                if let preview { self?.observe(preview, retries: retries - 1) }
            }
        }
    }

    func keep() throws {
        if let rotation {
            try rotation.finish(keep: true)
            self.rotation = nil
            return
        }
        guard let preview = active else { return }
        let live = try DisplayState()
        _ = try live.require(preview.edit.display)
        guard preview.edit.isApplied(in: live) else {
            throw DisplayFailure("The previewed setting is no longer active. Revert and select a current option.")
        }
        try preview.edit.apply(in: live, scope: .forSession)
        active = nil
    }

    func revert() throws {
        if let rotation {
            try rotation.finish(keep: false)
            self.rotation = nil
            return
        }
        guard let preview = active else { return }
        let now = try DisplayState()
        let confirmed = preview.after ?? (preview.edit.isApplied(in: now) ? now : preview.firstNativeTransition)
        let target = now.find(id: preview.edit.display.id, key: preview.edit.display.key)
        let plannedOrigins = (try? preview.edit.layout(in: preview.before)) ?? [:]
        var mirrors: [(CGDirectDisplayID, CGDirectDisplayID)] = []
        var modes: [(CGDirectDisplayID, ModeRoute)] = []
        var origins: [(CGDirectDisplayID, CGPoint)] = []

        for before in preview.before.panels {
            guard let live = now.find(id: before.id, key: before.key) else { continue }
            let after = confirmed?.find(id: before.id, key: before.key)
            let wasSource = preview.before.source(of: before)
            let priorSourceID = wasSource.flatMap { now.find(id: $0.id, key: $0.key)?.id }
            let priorSourceReachable = before.sourceID == nil || priorSourceID != nil
            let isTarget = live.id == target?.id

            // Reverse the requested operation even when the user clicks Revert before
            // Quartz publishes the post-commit snapshot. A disconnected display is skipped.
            var undoMode = false
            var undoMirror = false
            var undoOrigin = false
            switch preview.edit {
            case .mode: undoMode = isTarget && confirmed == nil && live.current == before.current
            case .mirror: undoMirror = isTarget && confirmed == nil && live.sourceID == priorSourceID
            case .main, .move:
                if let planned = plannedOrigins[before.id], before.origin != planned, live.sourceID == nil {
                    undoOrigin = live.origin == planned || (confirmed == nil && live.origin == before.origin)
                }
            }
            if let after {
                undoMode = undoMode || (before.current != after.current && live.current == after.current)
                let postSource = confirmed?.source(of: after)
                let currentSource = now.source(of: live)
                undoMirror = undoMirror || (wasSource?.key != postSource?.key && currentSource?.key == postSource?.key)
                if before.sourceID == nil, live.sourceID == nil || undoMirror,
                   live.origin == after.origin, before.origin != after.origin || undoMirror {
                    undoOrigin = true
                }
            }
            if undoMirror && priorSourceReachable {
                mirrors.append((live.id, priorSourceID ?? kCGNullDirectDisplay))
            }
            // A mirrored sink reports a mode derived from its source; Quartz sets it when rejoining.
            if undoMode, before.sourceID == nil, let oldMode = before.mode {
                if let previous = before.current, previous.nativeNumber != nil {
                    modes.append((live.id, try live.resolveMode(previous)))
                } else if live.id == before.id {
                    // A mirror can hide its original mode until it has been detached in this transaction.
                    modes.append((live.id, .quartz(oldMode)))
                } else if let value = before.current {
                    modes.append((live.id, try live.resolveMode(value)))
                }
            }
            if undoOrigin { origins.append((live.id, before.origin)) }
        }

        if !mirrors.isEmpty || !modes.isEmpty || !origins.isEmpty {
            try configure(scope: .forAppOnly) { config in
                for (display, source) in mirrors {
                    try DisplayFailure.check(CGConfigureDisplayMirrorOfDisplay(config, display, source), "restore mirroring")
                }
                for (display, mode) in modes {
                    try DisplayFailure.check(mode.configure(config, display: display), "restore the display mode")
                }
                for (display, point) in origins {
                    // Configuring an origin breaks a mirror link, so only desktop sources get origins.
                    try setOrigin(point, of: display, in: config)
                }
            }
        }
        active = nil
    }
}
