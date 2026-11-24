import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

private final class AppMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var fitContent: ((NSSize) -> Void)?
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        fitContent?(contentRect(forFrameRect: frame).size)
    }
}

// The window owns the viewport. The hosting view's ideal height describes its
// scroll document; allowing AppKit to use that intrinsic size clips the viewport.
private final class MenuViewport: NSView {
    private let material: NSVisualEffectView
    private let host: NSHostingView<QuickPanel>
    init(size: NSSize, panel: QuickPanel) {
        let rect = NSRect(origin: .zero, size: size)
        material = NSVisualEffectView(frame: rect)
        host = NSHostingView(rootView: panel)
        super.init(frame: rect)
        autoresizingMask = [.width, .height]
        wantsLayer = true; layer?.cornerRadius = 10; layer?.masksToBounds = true
        material.material = .popover; material.state = .active; material.blendingMode = .behindWindow
        material.autoresizingMask = [.width, .height]
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        addSubview(material)
        addSubview(host)
        fit(size)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(_ size: NSSize) {
        let rect = NSRect(origin: .zero, size: size)
        if frame.size != size { setFrameSize(size) }
        material.frame = rect
        host.frame = rect
        needsLayout = true
    }
    override func layout() {
        super.layout()
        material.frame = bounds
        host.frame = bounds
    }
}

@MainActor
private final class KeyBindings {
    private var handler: EventHandlerRef?
    private var registered = [EventHotKeyRef]()
    let action: (UInt32) -> Void
    init(action: @escaping (UInt32) -> Void) { self.action = action }

    func enable() -> Bool {
        disable()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
                  key.signature == 0x44534B31 else { return OSStatus(eventNotHandledErr) }
            let shortcuts = Unmanaged<KeyBindings>.fromOpaque(context).takeUnretainedValue()
            let id = key.id
            Task { @MainActor in shortcuts.action(id) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return false }
        for (index, key) in [kVK_ANSI_D, kVK_UpArrow, kVK_DownArrow].enumerated() {
            let id = EventHotKeyID(signature: 0x44534B31, id: UInt32(index + 1))
            var reference: EventHotKeyRef?
            guard RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey | cmdKey), id,
                                      GetApplicationEventTarget(), 0, &reference) == noErr, let reference else {
                disable(); return false
            }
            registered.append(reference)
        }
        return true
    }

    func disable() {
        for key in registered { UnregisterEventHotKey(key) }
        registered.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

@MainActor
private final class DeskApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let desk = DeskState()
    private var status: NSStatusItem!
    private var quick: AppMenuPanel!
    private var windows: [String: NSWindow] = [:]
    private var clickMonitor: Any?
    private var insideClickMonitor: Any?
    private var lastLogoPress = -Double.infinity
    private var menuScreenNumber: NSNumber?
    private var menuAnchorX: CGFloat?
    private var subscriptions = Set<AnyCancellable>()
    private var desiredHeight: CGFloat = 255
    private lazy var keys = KeyBindings { [weak self] id in
        guard let self else { return }
        if id == 1 { toggleMenu(nil); return }
        guard let screen = desk.focusDisplay, let current = desk.samples[screen.id], current.canAdjust else { return }
        desk.setBrightness(screen, current.value + (id == 2 ? 0.05 : -0.05))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildQuickPanel()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = status.button {
            button.image = NSImage(named: "ScreenfinchStatusTemplate")
            button.image?.isTemplate = true
            button.image?.accessibilityDescription = "Screenfinch"
            button.setAccessibilityLabel("Screenfinch")
            button.toolTip = "Screenfinch"
            button.target = self; button.action = #selector(toggleMenu(_:))
            // One action per press. A menu-bar mouse-up can be delivered by a
            // separate system window after the panel has already closed.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        desk.showMenu = { [weak self] in self?.openMenu() }
        desk.showSettings = { [weak self] in self?.openSettings() }
        desk.showNewScreen = { [weak self] in self?.newScreen() }
        desk.showModes = { [weak self] display in self?.openModes(display) }
        desk.showInfo = { [weak self] display in self?.openInfo(display) }
        desk.showOverride = { [weak self] screen in self?.openOverride(screen) }
        desk.presentPreview = { [weak self] in self?.openConfirmation() }
        desk.closePreview = { [weak self] in self?.windows["confirm"]?.close() }
        desk.showMessage = { [weak self] message in self?.showError(message) }
        desk.options.$dockForSettings.dropFirst().sink { [weak self] enabled in
            guard let self, windows["settings"]?.isVisible == true else { return }
            NSApp.setActivationPolicy(enabled ? .regular : .accessory)
        }.store(in: &subscriptions)
        desk.options.$shortcuts.removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            if enabled && !keys.enable() {
                DispatchQueue.main.async {
                    self.desk.options.shortcuts = false
                    self.showError("Another app is using one of the global shortcuts. The shortcuts could not be registered.")
                }
            } else if !enabled { keys.disable() }
        }.store(in: &subscriptions)
        desk.start()
#if MENU_REGRESSION
        // The fixture supplies its own pointer events. A real click in the
        // user's foreground app must not dismiss this background test panel.
        if !CommandLine.arguments.contains("--verify-menu") { installOutsideClickMonitors() }
#else
        installOutsideClickMonitors()
#endif
        DispatchQueue.main.async {
            if CommandLine.arguments.contains("--settings") { self.openSettings() }
            else if CommandLine.arguments.contains("--show-menu") { self.openMenu() }
#if MENU_REGRESSION
            if CommandLine.arguments.contains("--verify-menu") { self.verifyLogoToggle() }
#endif
        }
    }

    private func installOutsideClickMonitors() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let point = NSEvent.mouseLocation, timestamp = event.timestamp
            Task { @MainActor in self?.outsidePress(at: point, timestamp: timestamp) }
        }
        insideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, let clicked = event.window, windows.values.contains(where: { $0 === clicked }) {
                outsidePress(at: NSEvent.mouseLocation, timestamp: event.timestamp)
            }
            return event
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let insideClickMonitor { NSEvent.removeMonitor(insideClickMonitor) }
        keys.disable(); desk.stop()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === windows["settings"] { NSApp.setActivationPolicy(.accessory) }
        if let key = windows.first(where: { $0.value === window })?.key { windows.removeValue(forKey: key) }
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Screenfinch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let owner = NSMenuItem(); main.addItem(owner); main.setSubmenu(app, for: owner)
        let edit = NSMenu(title: "Edit")
        for (title, command, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(command), keyEquivalent: key)
        }
        let editItem = NSMenuItem(); main.addItem(editItem); main.setSubmenu(edit, for: editItem)
        NSApp.mainMenu = main
    }

    private func buildQuickPanel() {
        quick = AppMenuPanel(contentRect: NSRect(x: 0, y: 0, width: 284, height: desiredHeight),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        quick.title = "Screenfinch Menu"; quick.level = .floating; quick.isFloatingPanel = true
        quick.isOpaque = false; quick.backgroundColor = .clear; quick.hasShadow = true
        quick.isReleasedWhenClosed = false; quick.hidesOnDeactivate = false
        quick.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let content = QuickPanel(desk: desk, options: desk.options, measured: { [weak self] height in
            guard let self, height > 35, abs(height - desiredHeight) > 0.5 else { return }
            desiredHeight = height
            DispatchQueue.main.async { [weak self] in
                guard let self, self.quick.isVisible else { return }
                self.placeMenu()
            }
        }, close: { [weak self] in self?.hideMenu() })
        let viewport = MenuViewport(size: quick.frame.size, panel: content)
        quick.contentView = viewport
        quick.fitContent = { [weak viewport] size in viewport?.fit(size) }
    }

    @objc func toggleMenu(_ sender: Any?) {
        if sender is NSStatusBarButton {
            let now = ProcessInfo.processInfo.systemUptime
            if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .rightMouseDown,
               abs(event.timestamp - now) < 1 { lastLogoPress = event.timestamp } else { lastLogoPress = now }
            if NSApp.currentEvent?.type == .rightMouseDown { openSettings(); return }
            let point = NSEvent.mouseLocation
            if let screen = menuBarScreen(at: point) {
                menuScreenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                menuAnchorX = point.x
            }
        }
        if quick.isVisible { hideMenu() } else { openMenu() }
    }
    private func menuBarScreen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            let edge = screen.frame.maxY
            let bottom = min(screen.visibleFrame.maxY, edge - NSStatusBar.system.thickness)
            return point.x >= screen.frame.minX && point.x < screen.frame.maxX &&
                   point.y >= bottom - 1 && point.y <= edge + 1
        }
    }
    private func outsidePress(at point: CGPoint, timestamp: TimeInterval) {
        guard quick.isVisible, !desk.options.pinMenu, !quick.frame.contains(point) else { return }
        if abs(lastLogoPress - timestamp) < 0.005 { return }
        if let button = status.button, let window = button.window,
           window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -1, dy: -1).contains(point) { return }
        // The system can forward the same status-item press from a different
        // menu-bar window on each monitor. The status button owns all such
        // presses. Only a desktop/window press belongs to outside dismissal.
        guard menuBarScreen(at: point) == nil else { return }
        hideMenu()
    }
    @objc private func settingsAction() { openSettings() }
    private func hideMenu() {
        quick.orderOut(nil)
        status.button?.state = .off; status.button?.highlight(false)
    }
    private func openMenu() {
        desk.reload()
        placeMenu()
        quick.makeKeyAndOrderFront(nil)
        status.button?.state = .on
        status.button?.highlight(true)
    }
    private func placeMenu() {
        let button = status?.button
        let barWindow = button?.window
        let clickedScreen = NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == menuScreenNumber }
        guard let screen = clickedScreen ?? barWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let anchor: CGRect? = button.flatMap { b in b.window?.convertToScreen(b.convert(b.bounds, to: nil)) }
        let usableAnchor = anchor.flatMap { candidate in
            candidate.midX >= screen.frame.minX && candidate.midX <= screen.frame.maxX &&
            abs(candidate.minY - visible.maxY) < 96 ? candidate : nil
        }
        let top = min(visible.maxY, usableAnchor?.minY ?? visible.maxY) - 3
        let width: CGFloat = 284
        let height = min(max(100, desiredHeight), max(100, top - visible.minY - 6))
        let x = max(visible.minX + 4, min(visible.maxX - width - 4, (usableAnchor?.midX ?? menuAnchorX ?? visible.maxX) - width/2))
        quick.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
    }

    private func openSettings() {
        hideMenu()
        if desk.options.dockForSettings { NSApp.setActivationPolicy(.regular) }
        desk.reload()
        window("settings", title: "Screenfinch Settings", size: CGSize(width: 820, height: 608), resizable: true,
               content: SettingsView(desk: desk, options: desk.options))
    }
    private func newScreen() {
        hideMenu()
        let target = desk.virtualTemplate
        desk.virtualTemplate = nil
        if target != nil { windows["new"]?.close() }
        window("new", title: "Virtual Screen", size: CGSize(width: 458, height: 326),
               content: NewScreenForm(desk: desk, close: { [weak self] in self?.windows["new"]?.close() }, target: target))
    }
    private func openModes(_ screen: DeskDisplay) {
        hideMenu()
        let key = "modes-\(screen.key)"
        window(key, title: "Display Mode", size: CGSize(width: 500, height: 480), resizable: true,
               content: ModeBrowser(desk: desk, screenKey: screen.key, close: { [weak self] in self?.windows[key]?.close() }))
    }
    private func openInfo(_ screen: DeskDisplay) {
        hideMenu()
        window("info-\(screen.key)", title: "Display Information", size: CGSize(width: 450, height: 353), content: InfoView(desk: desk, key: screen.key))
    }
    private func openOverride(_ screen: DeskDisplay) {
        hideMenu()
        let key = "override-\(screen.key)"
        window(key, title: "Display Override", size: CGSize(width: 490, height: 462), resizable: true,
               content: OverrideForm(desk: desk, screen: screen, close: { [weak self] in self?.windows[key]?.close() }))
    }
    private func openConfirmation() {
        hideMenu()
        window("confirm", title: "Confirm Display Change", size: CGSize(width: 375, height: 115), closable: false,
               floating: true, content: ConfirmView(desk: desk))
    }
    private func showError(_ message: String) {
        hideMenu()
        windows["notice"]?.close()
        window("notice", title: "Screenfinch", size: CGSize(width: 410, height: 154), floating: true, content:
            VStack(alignment: .leading, spacing: 12) {
                Text(message).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("OK") { [weak self] in self?.desk.notice = nil; self?.windows["notice"]?.close() }.keyboardShortcut(.defaultAction) }
            }.padding(18))
    }

    private func window<V: View>(_ key: String, title: String, size: CGSize, resizable: Bool = false, closable: Bool = true,
                                 floating: Bool = false, content: V) {
        if let existing = windows[key] {
            NSApp.activate(ignoringOtherApps: true); existing.makeKeyAndOrderFront(nil); return
        }
        var style: NSWindow.StyleMask = [.titled]
        if closable { style.insert(.closable) }
        if resizable { style.formUnion([.resizable, .miniaturizable]) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.delegate = self; window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.setContentSize(size)
        if resizable { window.contentMinSize = key == "settings" ? CGSize(width: 660, height: 415) : CGSize(width: 390, height: 320) }
        if floating { window.level = .floating; window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary] }
        window.center()
        if key == "settings" { window.setFrameAutosaveName("DisplayDeskSettings") }
        windows[key] = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }

#if MENU_REGRESSION
    // The test executable is given its own bundle identifier and preferences.
    // Press the actual status item's button and exercise its outside-click path.
    private func verifyLogoToggle() {
        guard let button = status.button, let bar = button.window else { exit(2) }
        var failures = 0
        func verify(_ label: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        func settle(_ seconds: Double = 0.035) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func press() { button.performClick(nil); settle() }
        let logo = bar.convertToScreen(button.convert(button.bounds, to: nil))
        let center = CGPoint(x: logo.midX, y: logo.midY)
        verify("Status button displays the Screenfinch template artwork",
               button.image?.name() == "ScreenfinchStatusTemplate" && button.image?.isTemplate == true &&
               button.image?.size == NSSize(width: 21, height: 19))
        hideMenu()
        verify("Starts closed", !quick.isVisible)
        press()
        verify("One logo press opens", quick.isVisible)
        settle(0.3)
        verify("All visible content fits the initial viewport",
               abs(quick.frame.height - min(desiredHeight, (quick.screen?.visibleFrame.height ?? 0) - 9)) < 2)
        outsidePress(at: center, timestamp: lastLogoPress)
        settle(0.2)
        verify("The same logo press is excluded from outside dismissal", quick.isVisible)
        press()
        verify("Second logo press closes", !quick.isVisible)
        press()
        verify("Third logo press opens", quick.isVisible)
        let outside = CGPoint(x: quick.frame.minX - 4, y: quick.frame.midY)
        outsidePress(at: outside, timestamp: ProcessInfo.processInfo.systemUptime)
        verify("Outside press dismisses", !quick.isVisible)
        let pinned = desk.options.pinMenu
        desk.options.pinMenu = true
        press(); outsidePress(at: outside, timestamp: ProcessInfo.processInfo.systemUptime)
        verify("Pinned menu ignores an outside press", quick.isVisible)
        press()
        verify("Logo closes even when pinned", !quick.isVisible)
        desk.options.pinMenu = pinned
        if let screen = bar.screen {
            let otherIcon = CGPoint(x: screen.frame.minX + 40, y: screen.frame.maxY - 3)
            verify("Test event targets a visible menu bar", menuBarScreen(at: otherIcon) != nil)
            press()
            outsidePress(at: otherIcon, timestamp: ProcessInfo.processInfo.systemUptime)
            press(); settle(0.24)
            verify("System menu-bar event cannot reopen a closed menu", !quick.isVisible)
            press()
            outsidePress(at: otherIcon, timestamp: lastLogoPress)
            settle(0.24)
            verify("Forwarded status-item event preserves an open menu", quick.isVisible)
        }
        hideMenu(); desk.stop(); fflush(stdout); exit(failures == 0 ? 0 : 1)
    }
#endif
}

@main
private struct DeskLauncher {
    @MainActor static func main() {
        if DisplayDetails.handleRotationWorker() { return }
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--list-displays") {
            do {
                let report: [[String: Any]] = try DisplaySystem.list().map { screen in
                    ["name": screen.name, "id": screen.id, "builtIn": screen.builtIn, "main": screen.isMain,
                     "availableModes": screen.modes.count, "activeMode": screen.current?.modeLabel ?? "Unknown"]
                }
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
            } catch { FileHandle.standardError.write(Data(error.localizedDescription.utf8)); exit(1) }
            return
        }
        let delegate = DeskApplication()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
