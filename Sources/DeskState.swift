import AppKit
import Combine
import CoreGraphics
import Foundation

extension DeskMode {
    var sizeLabel: String { "\(width) × \(height)" }
    var rateLabel: String { Self.rateText(hz) }
    var modeLabel: String { "\(sizeLabel) · \(isHiDPI ? "HiDPI" : "1×") · \(rateLabel)" }

    static func rateText(_ hz: Double) -> String {
        guard hz > 0 else { return "System default" }
        return hz.formatted(.number.precision(.fractionLength(0...2))) + " Hz"
    }

    func matchesTiming(_ other: DeskMode) -> Bool {
        width == other.width && height == other.height && pixelWidth == other.pixelWidth &&
        pixelHeight == other.pixelHeight && abs(hz - other.hz) < 0.005
    }
}

extension DeskDisplay {
    var symbol: String { builtIn ? "laptopcomputer" : "display" }

    // The resolution slider follows the present aspect, scale and refresh rate.
    // The full mode menu also offers the other timings advertised by Quartz.
    var sliderModes: [DeskMode] {
        guard let current else { return [] }
        let choices = modes.filter {
            $0.isHiDPI == current.isHiDPI && abs($0.hz - current.hz) < 0.01 &&
            abs(Double($0.width) / Double($0.height) - Double(current.width) / Double(current.height)) < 0.025
        }
        var seen = Set<String>()
        return choices.sorted { $0.width < $1.width }.filter { seen.insert($0.sizeLabel).inserted }
    }

    var refreshModes: [DeskMode] {
        guard let current else { return [] }
        return modes.filter {
            $0.width == current.width && $0.height == current.height &&
            $0.pixelWidth == current.pixelWidth && $0.pixelHeight == current.pixelHeight
        }.sorted { $0.hz > $1.hz }
    }
}

@MainActor
final class DeskOptions: ObservableObject {
    private let defaults: UserDefaults
    @Published var brightness: Bool { didSet { save(brightness, "showBrightness") } }
    @Published var resolution: Bool { didSet { save(resolution, "showResolution") } }
    @Published var hardware: Bool { didSet { save(hardware, "showHardware") } }
    @Published var pinMenu: Bool { didSet { save(pinMenu, "pinMenu") } }
    @Published var dockForSettings: Bool { didSet { save(dockForSettings, "dockForSettings") } }
    @Published var shortcuts: Bool { didSet { save(shortcuts, "enableShortcuts") } }
    @Published var detailed: Bool { didSet { save(detailed, "showDetails") } }

    init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["showBrightness": true, "showResolution": true,
                                     "showHardware": true, "dockForSettings": true])
        brightness = defaults.bool(forKey: "showBrightness")
        resolution = defaults.bool(forKey: "showResolution")
        hardware = defaults.bool(forKey: "showHardware")
        pinMenu = defaults.bool(forKey: "pinMenu")
        dockForSettings = defaults.bool(forKey: "dockForSettings")
        shortcuts = defaults.bool(forKey: "enableShortcuts")
        detailed = defaults.bool(forKey: "showDetails")
    }

    private func save(_ value: Bool, _ key: String) { defaults.set(value, forKey: key) }
}

struct FavoriteMode: Identifiable, Codable {
    var id = UUID()
    let screen: String
    let mode: DeskMode
}

@MainActor
final class DeskState: ObservableObject {
    let options: DeskOptions
    let preview = DisplayPreview()
    let virtual: VirtualScreens
    let brightnessControl = BrightnessControl()
    let streams = DisplayStreams()
    let images = ImageAdjustments()
    let connections = ScreenConnections()
    private let defaults: UserDefaults

    @Published private(set) var displays: [DeskDisplay] = []
    @Published private(set) var samples: [CGDirectDisplayID: BrightnessSample] = [:]
    @Published private(set) var extras: [CGDirectDisplayID: [MonitorAdjustment: Double]] = [:]
    @Published private(set) var imageValues: [CGDirectDisplayID: DeskColorValues] = [:]
    @Published private(set) var hdrStates: [CGDirectDisplayID: Bool] = [:]
    @Published private(set) var rotations: [CGDirectDisplayID: [Int]] = [:]
    @Published private(set) var inputs: [CGDirectDisplayID: MonitorInputs] = [:]
    @Published private(set) var readingInputs = Set<CGDirectDisplayID>()
    @Published private(set) var favorites: [FavoriteMode]
    @Published private(set) var disconnected: [RestorableScreen] = []
    @Published private(set) var countdown: Int?
    @Published var notice: String?
    @Published var settingsTarget: String?
    @Published var expanded: Set<String> = []
    @Published var toolsExpanded = false
    var virtualTemplate: DeskDisplay?

    var showSettings: (() -> Void)?
    var showMenu: (() -> Void)?
    var showNewScreen: (() -> Void)?
    var showModes: ((DeskDisplay) -> Void)?
    var showInfo: ((DeskDisplay) -> Void)?
    var showOverride: ((DeskDisplay) -> Void)?
    var showMessage: ((String) -> Void)?
    var presentPreview: (() -> Void)?
    var closePreview: (() -> Void)?

    private var changes: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var sampleTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var samplesVersion: [CGDirectDisplayID: UInt64] = [:]
    private var adjustmentTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var adjustmentEpoch: [CGDirectDisplayID: UInt64] = [:]
    private var shuttingDown = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        virtual = VirtualScreens(defaults: defaults)
        options = DeskOptions(defaults)
        favorites = defaults.data(forKey: "favoriteModes").flatMap { try? JSONDecoder().decode([FavoriteMode].self, from: $0) } ?? []
    }

    var focusDisplay: DeskDisplay? {
        let pointer = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(pointer) }
        let pointerID = pointerScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        return displays.first { $0.id == pointerID } ?? displays.first { $0.isMain } ?? displays.first
    }

    func start() {
        streams.onChange = { [weak self] in self?.objectWillChange.send() }
        streams.onError = { [weak self] message in self?.notice = message; self?.showMessage?(message) }
        for profile in virtual.profiles where profile.reconnectOnLaunch {
            do { _ = try virtual.connect(profile) } catch { report(error) }
        }
        changes.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.queueRefresh() }
        })
        changes.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.queueRefresh() }
        })
        reload()
    }

    func queueRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    func reload() {
        guard !shuttingDown else { return }
        do {
            let updated = try DisplaySystem.list()
            let active = Set(updated.map(\.id))
            let oldKeys = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.key) })
            let newKeys = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0.key) })
            for id in oldKeys.keys where newKeys[id] != oldKeys[id] {
                sampleTasks.removeValue(forKey: id)?.cancel()
                samples.removeValue(forKey: id)
                samplesVersion[id, default: 0] &+= 1
                adjustmentTasks.removeValue(forKey: id)?.cancel()
                adjustmentEpoch[id, default: 0] &+= 1
                extras.removeValue(forKey: id)
                inputs.removeValue(forKey: id)
                readingInputs.remove(id)
                imageValues.removeValue(forKey: id)
                hdrStates.removeValue(forKey: id)
                rotations.removeValue(forKey: id)
            }
            displays = updated
            brightnessControl.reconcile(active: active)
            images.reconcile(updated)
            streams.reconcile(active: active)
            connections.reconcile(updated)
            disconnected = connections.disconnected
            for screen in updated where sampleTasks[screen.id] == nil { readBrightness(screen) }
            for screen in updated where expanded.contains(screen.key) { readAdvanced(screen) }
        } catch { report(error) }
    }

    func current(_ display: DeskDisplay) -> DeskDisplay? {
        displays.first { $0.id == display.id && $0.key == display.key }
    }

    func readBrightness(_ screen: DeskDisplay) {
        let id = screen.id
        let version = samplesVersion[id, default: 0]
        sampleTasks[id] = Task {
            let result = await brightnessControl.read(id)
            guard !Task.isCancelled, !shuttingDown, current(screen) != nil,
                  version == samplesVersion[id, default: 0] else { return }
            samples[id] = result
            sampleTasks.removeValue(forKey: id)
        }
    }

    func setBrightness(_ screen: DeskDisplay, _ level: Double, final: Bool = true) {
        guard let old = samples[screen.id], old.canAdjust, current(screen) != nil else { return }
        let id = screen.id
        sampleTasks[id]?.cancel()
        samplesVersion[id, default: 0] &+= 1
        let version = samplesVersion[id]!
        let clipped = min(1, max(0, level))
        samples[id] = BrightnessSample(value: clipped, method: old.method)
        sampleTasks[id] = Task {
            if !final { try? await Task.sleep(nanoseconds: 70_000_000) }
            guard !Task.isCancelled, version == samplesVersion[id] else { return }
            do {
                let result = try await brightnessControl.set(id, value: clipped)
                guard !Task.isCancelled, current(screen) != nil, version == samplesVersion[id] else { return }
                samples[id] = result
                sampleTasks.removeValue(forKey: id)
            } catch {
                guard !Task.isCancelled, current(screen) != nil, version == samplesVersion[id] else { return }
                sampleTasks.removeValue(forKey: id)
                if !(error is CancellationError) { report(error) }
                readBrightness(screen)
            }
        }
    }

    func toggleExpanded(_ screen: DeskDisplay) {
        if expanded.remove(screen.key) == nil {
            expanded.insert(screen.key)
            readAdvanced(screen)
        }
    }

    func readAdvanced(_ screen: DeskDisplay) {
        imageValues[screen.id] = images.settings(for: screen)
        hdrStates[screen.id] = images.hdrEnabled(for: screen)
        rotations[screen.id] = DisplayDetails.rotationChoices(for: screen)
        if options.hardware { readExtras(screen) }
    }

    func setColors(_ values: DeskColorValues, on screen: DeskDisplay) {
        do { try images.apply(values, to: screen); imageValues[screen.id] = images.settings(for: screen) }
        catch { report(error) }
    }

    func mirror(_ screen: DeskDisplay, source: DeskDisplay?) {
        previewChange {
            if let source {
                try images.reset(screen)
                try images.reset(source)
            }
            try preview.previewMirror(display: screen, source: source)
        }
    }

    func toggleHDR(_ screen: DeskDisplay) {
        guard let now = images.hdrEnabled(for: screen) else { return }
        Task {
            do { try await images.setHDR(!now, for: screen); readAdvanced(screen) } catch { report(error) }
        }
    }

    func readInputs(_ screen: DeskDisplay) {
        guard current(screen) != nil, readingInputs.insert(screen.id).inserted else { return }
        Task {
            let result = await brightnessControl.inputSources(screen.id)
            guard !shuttingDown, current(screen) != nil else { return }
            inputs[screen.id] = result
            readingInputs.remove(screen.id)
        }
    }

    func setInput(_ value: UInt16, on screen: DeskDisplay) {
        Task {
            do { try await brightnessControl.setInputSource(screen.id, value: value); queueRefresh() }
            catch { report(error) }
        }
    }

    func readExtras(_ screen: DeskDisplay) {
        let id = screen.id
        guard !screen.builtIn, !virtual.ids.contains(id), adjustmentTasks[id] == nil else { return }
        let epoch = adjustmentEpoch[id, default: 0]
        adjustmentTasks[id] = Task {
            var values = [MonitorAdjustment: Double]()
            for control in MonitorAdjustment.allCases {
                if let value = await brightnessControl.readAdjustment(id, control) { values[control] = value }
            }
            guard !Task.isCancelled, current(screen) != nil, epoch == adjustmentEpoch[id, default: 0] else { return }
            extras[id] = values
            adjustmentTasks[id] = nil
        }
    }

    func setExtra(_ screen: DeskDisplay, _ control: MonitorAdjustment, _ level: Double) {
        guard current(screen) != nil else { return }
        let id = screen.id
        adjustmentTasks[id]?.cancel()
        adjustmentEpoch[id, default: 0] &+= 1
        let epoch = adjustmentEpoch[id]!
        adjustmentTasks[id] = Task {
            do {
                let value = try await brightnessControl.setAdjustment(id, control, value: level)
                guard !Task.isCancelled, current(screen) != nil, epoch == adjustmentEpoch[id] else { return }
                extras[id, default: [:]][control] = value
                adjustmentTasks[id] = nil
            } catch {
                guard !Task.isCancelled, epoch == adjustmentEpoch[id] else { return }
                adjustmentTasks[id] = nil
                report(error)
                readExtras(screen)
            }
        }
    }

    func previewChange(_ change: () throws -> Void) {
        do {
            guard !preview.pending else { presentPreview?(); return }
            try change()
            guard preview.pending else { return }
            countdown = 15
            presentPreview?()
            timerTask?.cancel()
            timerTask = Task {
                let deadline = Date().addingTimeInterval(15)
                while !Task.isCancelled, preview.pending {
                    let remaining = Int(ceil(deadline.timeIntervalSinceNow))
                    if remaining <= 0 { finishPreview(keep: false); return }
                    countdown = remaining
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            queueRefresh()
        } catch { report(error) }
    }

    func changeMode(_ screen: DeskDisplay, _ mode: DeskMode) {
        previewChange { try preview.previewMode(display: screen, mode: mode) }
    }

    func finishPreview(keep: Bool) {
        timerTask?.cancel()
        do {
            if keep { try preview.keep() } else { try preview.revert() }
        } catch {
            report(error)
            if keep { do { try preview.revert() } catch { report(error) } }
            if preview.pending { countdown = 0; presentPreview?(); return }
        }
        countdown = nil
        closePreview?()
        queueRefresh()
    }

    func toggleFavorite(_ screen: DeskDisplay, _ mode: DeskMode) {
        if let index = favorites.firstIndex(where: { $0.screen == screen.key && $0.mode.matchesTiming(mode) }) {
            favorites.remove(at: index)
        } else { favorites.append(FavoriteMode(screen: screen.key, mode: mode)) }
        if let encoded = try? JSONEncoder().encode(favorites) { defaults.set(encoded, forKey: "favoriteModes") }
    }

    func isFavorite(_ screen: DeskDisplay, _ mode: DeskMode) -> Bool {
        favorites.contains { $0.screen == screen.key && $0.mode.matchesTiming(mode) }
    }

    func newVirtual(width: Int, height: Int, hiDPI: Bool, name: String, reconnect: Bool) throws {
        let id = try virtual.create(width: width, height: height, hiDPI: hiDPI, name: name, remember: true, reconnectOnLaunch: reconnect)
        reload()
        settingsTarget = displays.first { $0.id == id }?.key
        queueRefresh()
    }

    func removeVirtual(_ screen: DeskDisplay) {
        guard current(screen) != nil, virtual.ids.contains(screen.id) else { return }
        if preview.pending { finishPreview(keep: false) }
        virtual.remove(screen.id)
        queueRefresh()
    }

    func startStream(_ screen: DeskDisplay, to target: DeskDisplay? = nil) {
        guard current(screen) != nil else { return }
        Task {
            do { try await streams.open(source: screen.id, destination: target?.id) }
            catch { report(error) }
        }
    }

    func disconnect(_ screen: DeskDisplay) {
        guard !preview.pending else { presentPreview?(); return }
        do {
            try connections.disconnect(screen, screens: displays, virtualIDs: virtual.ids,
                                       confirmedPhysical: Set(samples.filter {
                                           $0.value.method == "Apple backlight" || $0.value.method == "DDC/CI backlight"
                                       }.keys))
            disconnected = connections.disconnected
            queueRefresh()
        } catch { report(error) }
    }

    func reconnect(_ screen: RestorableScreen) {
        do { try connections.reconnect(screen); disconnected = connections.disconnected; queueRefresh() }
        catch { report(error) }
    }

    func report(_ error: Error) { notice = error.localizedDescription; showMessage?(error.localizedDescription) }

    func stop() {
        shuttingDown = true
        changes.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        changes.removeAll()
        timerTask?.cancel()
        refreshTask?.cancel()
        sampleTasks.values.forEach { $0.cancel() }
        adjustmentTasks.values.forEach { $0.cancel() }
        if preview.pending { try? preview.revert() }
        connections.restoreAll()
        streams.stopAll()
        images.shutdown()
        brightnessControl.shutdown()
        virtual.removeAll()
    }
}
