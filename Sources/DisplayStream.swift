import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import QuartzCore
import ScreenCaptureKit

private struct StreamRoute: Hashable {
    let source: CGDirectDisplayID
    let destination: CGDirectDisplayID?
}

private struct DisplayStreamError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private func screenForStream(_ id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }
}

@MainActor
final class DisplayStreams {
    private var sessions: [StreamRoute: DisplayStreamSession] = [:]
    var onError: ((String) -> Void)?
    var onChange: (() -> Void)?
    var activeSources: Set<CGDirectDisplayID> { Set(sessions.keys.map(\.source)) }
    var activeCount: Int { sessions.count }

    /// Call from the person's explicit PiP or stream action. Permission is requested here.
    func open(source: CGDirectDisplayID, destination: CGDirectDisplayID? = nil) async throws {
        guard let input = screenForStream(source) else { throw DisplayStreamError("The source display is unavailable.") }
        guard destination != source else { throw DisplayStreamError("Choose a different display for full-screen streaming.") }
        let target = destination.flatMap(screenForStream)
        guard destination == nil || target != nil else { throw DisplayStreamError("The destination display is unavailable.") }
        let route = StreamRoute(source: source, destination: destination)
        if let session = sessions[route] {
            session.window.makeKeyAndOrderFront(nil)
            return
        }
        if let destination, sessions.keys.contains(where: { $0.destination == destination }) {
            throw DisplayStreamError("This destination already has a stream. Stop that stream before opening another here.")
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw DisplayStreamError("Allow Screenfinch to record the screen in System Settings → Privacy & Security, then reopen Screenfinch.")
        }

        let session = DisplayStreamSession(source: input, target: target)
        sessions[route] = session
        session.onClose = { [weak self, weak session] error in
            guard let self, let session, self.sessions[route] === session else { return }
            self.end(route)
            if let error { self.onError?(error.localizedDescription) }
        }
        onChange?()
        session.show()
        do {
            try await session.start(source: source)
        } catch {
            guard sessions[route] === session else { return }
            end(route)
            throw error
        }
    }

    func reconcile(active: Set<CGDirectDisplayID>) {
        for (route, session) in sessions {
            if !active.contains(route.source) || route.destination.map({ !active.contains($0) }) == true {
                end(route)
                onError?("The display stream closed because a selected display disconnected.")
            } else if let source = screenForStream(route.source) {
                session.updateGeometry(source: source, target: route.destination.flatMap(screenForStream))
            }
        }
    }

    func stop(source: CGDirectDisplayID) {
        for route in sessions.keys.filter({ $0.source == source }) { end(route) }
    }

    func stopAll() {
        for route in Array(sessions.keys) { end(route) }
    }

    private func end(_ route: StreamRoute) {
        guard let session = sessions.removeValue(forKey: route) else { return }
        session.dismiss()
        onChange?()
    }
}

private struct StreamFraming {
    var fill = false
    var flipped = false
    var clockwiseTurns = 0
    var zoomPercent = 100
    // Fractions of the excess content on each axis, kept stable as the window resizes.
    var pan = CGPoint.zero

    var swapsAxes: Bool { clockwiseTurns % 2 == 1 }

    func placement(image: CGSize, canvas: CGRect) -> (center: CGPoint, transform: CGAffineTransform, panLimit: CGSize) {
        let width = max(1, swapsAxes ? image.height : image.width)
        let height = max(1, swapsAxes ? image.width : image.height)
        let horizontal = canvas.width / width, vertical = canvas.height / height
        let scale = (fill ? max(horizontal, vertical) : min(horizontal, vertical)) * CGFloat(zoomPercent) / 100
        let limit = CGSize(width: max(0, (width * scale - canvas.width) / 2),
                           height: max(0, (height * scale - canvas.height) / 2))
        let center = CGPoint(x: canvas.midX + pan.x * limit.width, y: canvas.midY + pan.y * limit.height)
        var transform = CGAffineTransform(rotationAngle: -CGFloat(clockwiseTurns) * .pi / 2).scaledBy(x: scale, y: scale)
        if flipped { // Reflect the final window image across its vertical centerline.
            transform.a = -transform.a
            transform.c = -transform.c
        }
        return (center, transform, limit)
    }
}

private enum FramingAction: Equatable {
    case fit, fill, flip, rotation(Int), zoom(Int), center, lockAspect, reset
}

/// Presents the IOSurface supplied by ScreenCaptureKit directly through Core Animation.
@MainActor
private final class StreamCanvas: NSView {
    private let picture = CALayer()
    private let status = NSTextField(labelWithString: "Starting preview…")
    private let fullScreen: Bool
    private var backingBuffer: CVPixelBuffer?
    private var imageSize = CGSize(width: 16, height: 9)
    private var dragPoint: CGPoint?
    private(set) var framing = StreamFraming()
    private(set) var locksWindowAspect = true
    var onWindowAspectChange: (() -> Void)?

    init(fullScreen: Bool) {
        self.fullScreen = fullScreen
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        picture.contentsGravity = .resizeAspect
        layer?.addSublayer(picture)
        toolTip = "Right-click for fit, fill, flip, rotation and zoom. Drag a zoomed image to pan."
        status.textColor = .white
        status.translatesAutoresizingMaskIntoConstraints = false
        addSubview(status)
        NSLayoutConstraint.activate([status.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     status.centerYAnchor.constraint(equalTo: centerYAnchor)])
        if fullScreen {
            let close = button(title: "Stop streaming", symbol: "xmark.circle.fill", action: #selector(closePreview))
            close.toolTip = "Stop streaming (Esc)"
            let group = NSStackView(views: [optionsButton(), close])
            group.spacing = 8
            group.translatesAutoresizingMaskIntoConstraints = false
            addSubview(group)
            NSLayoutConstraint.activate([group.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                                         group.topAnchor.constraint(equalTo: topAnchor, constant: 12)])
        }
    }

    required init?(coder: NSCoder) { nil }
    @objc private func closePreview() { window?.close() }

    func optionsButton() -> NSButton {
        let control = button(title: "View options", symbol: "ellipsis.circle", action: #selector(showOptions(_:)))
        control.toolTip = "View options — fit, fill, flip, rotate and zoom"
        return control
    }

    private func button(title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = icon
            button.imagePosition = .imageOnly
        }
        button.bezelStyle = .inline
        if fullScreen { button.contentTintColor = .white }
        button.setAccessibilityLabel(title)
        return button
    }

    @objc private func showOptions(_ sender: NSButton) {
        optionsMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? { optionsMenu() }

    func optionsMenu() -> NSMenu {
        let menu = NSMenu(title: "View options")
        menu.autoenablesItems = false
        func add(_ title: String, _ action: FramingAction, checked: Bool = false, to parent: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(changeFraming(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            item.state = checked ? .on : .off
            parent.addItem(item)
            return item
        }
        func submenu(_ title: String) -> NSMenu {
            let group = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = group
            menu.addItem(item)
            return group
        }
        _ = add("Fit to Window", .fit, checked: !framing.fill, to: menu)
        _ = add("Fill Window", .fill, checked: framing.fill, to: menu)
        if !fullScreen { _ = add("Lock Window Aspect Ratio", .lockAspect, checked: locksWindowAspect, to: menu) }
        menu.addItem(.separator())
        _ = add("Flip Horizontally", .flip, checked: framing.flipped, to: menu)
        let rotation = submenu("Rotate Clockwise")
        for turns in 0...3 { _ = add("\(turns * 90)°", .rotation(turns), checked: turns == framing.clockwiseTurns, to: rotation) }
        let zoom = submenu("Zoom")
        for percent in [100, 125, 150, 200, 300, 400] {
            _ = add("\(percent)%", .zoom(percent), checked: percent == framing.zoomPercent, to: zoom)
        }
        let center = add("Center Image", .center, to: menu)
        center.isEnabled = framing.pan != .zero
        menu.addItem(.separator())
        _ = add("Reset View", .reset, to: menu)
        return menu
    }

    @objc private func changeFraming(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? FramingAction else { return }
        let swapped = framing.swapsAxes, locked = locksWindowAspect
        switch action {
        case .fit: framing.fill = false
        case .fill: framing.fill = true
        case .flip: framing.flipped.toggle()
        case let .rotation(turns): framing.clockwiseTurns = turns
        case let .zoom(percent): framing.zoomPercent = percent
        case .center: framing.pan = .zero
        case .lockAspect: locksWindowAspect.toggle()
        case .reset: framing = StreamFraming(); locksWindowAspect = true
        }
        if swapped != framing.swapsAxes || locked != locksWindowAspect { onWindowAspectChange?() }
        placePicture()
    }

    private var panLimit: CGSize { framing.placement(image: imageSize, canvas: bounds).panLimit }
    override var mouseDownCanMoveWindow: Bool { panLimit == .zero }

    override func resetCursorRects() {
        super.resetCursorRects()
        if panLimit != .zero { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if panLimit == .zero { super.mouseDown(with: event); return }
        dragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragPoint else { super.mouseDragged(with: event); return }
        let limit = panLimit, point = convert(event.locationInWindow, from: nil)
        if limit.width > 0 { framing.pan.x = min(1, max(-1, framing.pan.x + (point.x - start.x) / limit.width)) }
        if limit.height > 0 { framing.pan.y = min(1, max(-1, framing.pan.y + (point.y - start.y) / limit.height)) }
        dragPoint = point
        placePicture()
    }

    override func mouseUp(with event: NSEvent) {
        if dragPoint == nil { super.mouseUp(with: event) }
        dragPoint = nil
    }

    override func layout() { super.layout(); placePicture() }

    private func placePicture() {
        let placement = framing.placement(image: imageSize, canvas: bounds)
        if placement.panLimit.width == 0 { framing.pan.x = 0 }
        if placement.panLimit.height == 0 { framing.pan.y = 0 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.bounds = CGRect(origin: .zero, size: imageSize)
        picture.position = placement.center
        picture.setAffineTransform(placement.transform)
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    func present(_ sample: CMSampleBuffer) {
        guard sample.isValid,
              let entries = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = entries.first?[.status] as? Int, let state = SCFrameStatus(rawValue: raw) else { return }
        switch state {
        case .blank, .stopped, .suspended:
            clear()
            status.stringValue = "Display paused"
            status.isHidden = false
        case .complete, .started:
            guard let buffer = sample.imageBuffer,
                  let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            if size != imageSize { imageSize = size; placePicture() }
            backingBuffer = buffer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.contents = surface
            CATransaction.commit()
            status.isHidden = true
        default:
            break // Idle frames leave the last complete picture in place.
        }
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = nil
        CATransaction.commit()
        backingBuffer = nil
    }
}

private final class StreamWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class DisplayStreamSession: NSObject, NSWindowDelegate, SCStreamOutput, SCStreamDelegate {
    let window: NSWindow
    var onClose: ((Error?) -> Void)?
    private let canvas: StreamCanvas
    private let fullScreen: Bool
    private var requestedPixels = CGSize.zero
    private var appliedPixels = CGSize.zero
    private var sourcePoints = CGSize.zero
    private var updating = false
    private var stream: SCStream?
    private var running = false
    private var closed = false
    private var startupError: Error?

    init(source: NSScreen, target: NSScreen?) {
        fullScreen = target != nil
        canvas = StreamCanvas(fullScreen: target != nil)
        let size = Self.fitted(source.frame.size, in: CGSize(width: 480, height: 320))
        window = StreamWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: target == nil ? [.titled, .closable, .resizable] : [.borderless],
                              backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.title = source.localizedName + (fullScreen ? " — Display stream" : " — Picture in picture")
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if fullScreen {
            window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            window.hasShadow = false
        } else {
            window.level = .floating
            window.isMovableByWindowBackground = true
            let options = NSTitlebarAccessoryViewController()
            let button = canvas.optionsButton()
            button.frame = CGRect(x: 0, y: 0, width: 32, height: 24)
            options.view = button
            options.layoutAttribute = .right
            window.addTitlebarAccessoryViewController(options)
            canvas.onWindowAspectChange = { [weak self] in self?.updateWindowAspect(resize: true) }
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? source
            let frame = screen.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: max(frame.minX, frame.maxX - window.frame.width - 20), y: frame.maxY - 20))
        }
        updateGeometry(source: source, target: target)
    }

    func show() { window.makeKeyAndOrderFront(nil) }

    func start(source: CGDirectDisplayID) async throws {
        try Task.checkCancellation()
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !closed else { return }
        try Task.checkCancellation()
        guard let display = shareable.displays.first(where: { $0.displayID == source }) else {
            throw DisplayStreamError("macOS could not find the selected display for streaming.")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = shareable.applications.first { $0.processID == pid } ??
            shareable.windows.lazy.compactMap(\.owningApplication).first { $0.processID == pid }
        guard let own else { throw DisplayStreamError("macOS could not exclude the preview window from capture. Reopen the preview to retry.") }
        let filter = SCContentFilter(display: display, excludingApplications: [own], exceptingWindows: [])
        if #available(macOS 14.2, *) { filter.includeMenuBar = true }
        let initial = requestedPixels
        let capture = SCStream(filter: filter, configuration: configuration(pixels: initial), delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        stream = capture
        try await capture.startCapture()
        guard !closed else {
            try? await capture.stopCapture()
            return
        }
        running = true
        try Task.checkCancellation()
        if let startupError { throw startupError }
        appliedPixels = initial
        updateCaptureSize()
    }

    func updateGeometry(source: NSScreen, target: NSScreen?) {
        let size = source.frame.size
        if fullScreen, let target, window.frame != target.frame { window.setFrame(target.frame, display: true) }
        if sourcePoints != size {
            let resized = sourcePoints != .zero
            sourcePoints = size
            updateWindowAspect(resize: resized)
        }
        let sourcePixels = CGSize(width: size.width * source.backingScaleFactor, height: size.height * source.backingScaleFactor)
        let limit = target.map { CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor) }
            ?? CGSize(width: 1920, height: 1920)
        requestedPixels = Self.fitted(sourcePixels, in: limit)
        updateCaptureSize()
    }

    private func updateWindowAspect(resize: Bool) {
        guard !fullScreen, sourcePoints.width > 0, sourcePoints.height > 0 else { return }
        guard canvas.locksWindowAspect else {
            window.contentResizeIncrements = CGSize(width: 1, height: 1)
            window.contentMinSize = CGSize(width: 160, height: 100)
            return
        }
        let size = canvas.framing.swapsAxes ? CGSize(width: sourcePoints.height, height: sourcePoints.width) : sourcePoints
        window.contentAspectRatio = size
        window.contentMinSize = Self.fitted(size, in: CGSize(width: 180, height: 120))
        if resize {
            let current = window.contentRect(forFrameRect: window.frame).size
            let ratio = size.width / size.height
            let height = sqrt(max(1, current.width * current.height) / ratio)
            var available = window.screen?.visibleFrame.size ?? size
            available.height = max(1, available.height - (window.frame.height - current.height))
            window.setContentSize(Self.fitted(CGSize(width: height * ratio, height: height), in: available))
            window.setFrame(window.constrainFrameRect(window.frame, to: window.screen), display: true)
        }
    }

    private static func fitted(_ size: CGSize, in maximum: CGSize) -> CGSize {
        let scale = min(1, maximum.width / max(1, size.width), maximum.height / max(1, size.height))
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    private func configuration(pixels: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(pixels.width)
        config.height = Int(pixels.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: fullScreen ? 60 : 30)
        config.queueDepth = 3
        config.capturesAudio = false
        config.showsCursor = true
        return config
    }

    private func updateCaptureSize() {
        guard running, let stream, !updating, requestedPixels != appliedPixels else { return }
        updating = true
        Task {
            defer { updating = false }
            while !closed, appliedPixels != requestedPixels {
                let pixels = requestedPixels
                do {
                    try await stream.updateConfiguration(configuration(pixels: pixels))
                    appliedPixels = pixels
                } catch {
                    if !closed { onClose?(error) }
                    return
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        window.delegate = nil
        onClose?(nil)
    }

    func dismiss() {
        guard !closed else { return }
        closed = true
        if window.delegate != nil {
            window.delegate = nil
            window.close()
        }
        canvas.clear()
        if let capture = stream {
            try? capture.removeStreamOutput(self, type: .screen)
            if running { capture.stopCapture { _ in } }
        }
        stream = nil
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // addStreamOutput delivers frames on the main queue. Painting retains one GPU surface.
        MainActor.assumeIsolated {
            guard !closed, type == .screen else { return }
            canvas.present(buffer)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
            if running { onClose?(error) } else { startupError = error }
        }
    }
}
