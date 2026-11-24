import AppKit
import ServiceManagement
import SwiftUI

private enum PreferencePage: String, CaseIterable {
    case displays = "Displays", application = "Application", menu = "Menu", keyboard = "Keyboard", about = "About"
    var icon: String {
        switch self {
        case .displays: return "display.2"
        case .application: return "switch.2"
        case .menu: return "menubar.rectangle"
        case .keyboard: return "keyboard"
        case .about: return "tag"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var desk: DeskState
    @ObservedObject var options: DeskOptions
    @ViewState private var page = PreferencePage.displays
    @ViewState private var login = SMAppService.mainApp.status == .enabled
    @ViewState private var removal: VirtualProfile?
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(PreferencePage.allCases, id: \.rawValue) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).frame(height: 33).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .background(page == item ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(page == item ? .white : Color.primary)
                }
                Spacer()
                Toggle("Show details", isOn: $options.detailed).toggleStyle(.switch).controlSize(.small)
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 10).padding(.vertical, 16).frame(width: 170).background(.regularMaterial)
            Divider()
            VStack(spacing: 0) {
                if page == .displays {
                    selector
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 19) {
                        switch page {
                        case .displays:
                            if let display = desk.displays.first(where: { $0.key == desk.settingsTarget }) {
                                displayOptions(display)
                            } else { overview }
                        case .application: applicationOptions
                        case .menu: menuOptions
                        case .keyboard: keyboardOptions
                        case .about: about
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: desk.settingsTarget) { _ in page = .displays }
        .alert("Forget this virtual screen?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                if let removal { desk.virtual.forget(removal); desk.reload() }
                removal = nil
            }
        } message: { Text("This removes its saved configuration and disconnects it if active.") }
    }

    private var selector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 13) {
                selectorButton("Overview", icon: "list.bullet.circle.fill", key: nil)
                Divider().frame(height: 48)
                ForEach(desk.displays) { screen in
                    selectorButton(screen.name, icon: desk.virtual.ids.contains(screen.id) ? "rectangle.on.rectangle" : screen.symbol, key: screen.key)
                }
            }.padding(.horizontal, 16).frame(minHeight: 91)
        }.frame(height: 91).background(.regularMaterial)
    }

    private func selectorButton(_ label: String, icon: String, key: String?) -> some View {
        Button { desk.settingsTarget = key } label: {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 30, weight: .medium))
                    .foregroundStyle(desk.settingsTarget == key ? Color.accentColor : .secondary)
                Text(label).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            }.frame(minWidth: 72, maxWidth: 140).padding(.horizontal, 4).frame(height: 73).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(desk.settingsTarget == key ? .isSelected : [])
    }

    @ViewBuilder private var overview: some View {
        PrefGroup("Connected Displays") {
            ArrangementView(desk: desk).frame(height: 121)
            Divider()
            ForEach(desk.displays) { screen in
                HStack {
                    Image(systemName: screen.symbol).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(screen.name)
                        if let mode = screen.current { Text(mode.modeLabel).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Configure") { desk.settingsTarget = screen.key }
                }
            }
        }
        PrefGroup("Virtual Screens") {
            HStack {
                Text("Saved virtual screens")
                Spacer()
                Button("Create Virtual Screen…") { desk.showNewScreen?() }
            }
            ForEach(desk.virtual.profiles) { profile in
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "rectangle.on.rectangle")
                        VStack(alignment: .leading) {
                            Text(profile.name)
                            Text("\(profile.width) × \(profile.height) · \(profile.hiDPI ? "HiDPI" : "1×")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(desk.virtual.connectedID(for: profile) == nil ? "Connect" : "Disconnect") {
                            do {
                                if let id = desk.virtual.connectedID(for: profile) {
                                    if let live = desk.displays.first(where: { $0.id == id }) { desk.removeVirtual(live) }
                                    else { desk.virtual.remove(id) }
                                } else { _ = try desk.virtual.connect(profile) }
                                desk.reload(); desk.queueRefresh()
                            } catch { desk.report(error) }
                        }
                        Button { removal = profile } label: { Image(systemName: "trash") }.help("Forget \(profile.name)")
                    }
                    Toggle("Reconnect when Screenfinch opens", isOn: Binding(get: { profile.reconnectOnLaunch }, set: {
                        desk.virtual.setReconnect($0, for: profile); desk.objectWillChange.send()
                    })).font(.caption)
                }
            }
        }
        HStack { Button("Redetect Displays") { desk.reload() }; Spacer(); Button("Open App Menu") { desk.showMenu?() } }
    }

    @ViewBuilder private func displayOptions(_ screen: DeskDisplay) -> some View {
        PrefGroup("Video Control Settings") {
            if let level = desk.samples[screen.id] {
                HStack {
                    Label("Brightness", systemImage: "sun.max"); Spacer()
                    Text("\(Int((level.value * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { desk.samples[screen.id]?.value ?? level.value }, set: { desk.setBrightness(screen, $0, final: false) }))
                    .disabled(!level.canAdjust).accessibilityLabel("Brightness for \(screen.name)")
                Text(level.method).foregroundStyle(.secondary).font(.caption)
            } else { ProgressView("Reading brightness…").controlSize(.small) }
        }
        PrefGroup("Display Mode") {
            if let mode = screen.current {
                LabeledContent("Resolution", value: mode.sizeLabel)
                LabeledContent("Refresh rate", value: mode.rateLabel)
                if options.detailed { LabeledContent("Backing pixels", value: "\(mode.pixelWidth) × \(mode.pixelHeight)") }
                HStack {
                    Button("Choose Display Mode…") { desk.showModes?(screen) }
                    Spacer()
                    Button { desk.toggleFavorite(screen, mode) } label: {
                        Label(desk.isFavorite(screen, mode) ? "Remove Favorite" : "Add Favorite", systemImage: desk.isFavorite(screen, mode) ? "star.fill" : "star")
                    }
                }
            }
        }
        if !desk.virtual.ids.contains(screen.id) {
            PrefGroup("Custom Resolutions and Scaling") {
                Button("Create Mirrored HiDPI Screen…") {
                    desk.virtualTemplate = screen
                    desk.showNewScreen?()
                }
                Button("Export Display Override…") { desk.showOverride?(screen) }
                Text("Use a virtual screen for immediate scaling, or export a per-model profile with custom resolutions.").font(.caption).foregroundStyle(.secondary)
            }
        }
        PrefGroup("Mirroring and Streaming") {
            Menu("Mirror Display") {
                Button("Extend Desktop") { desk.mirror(screen, source: nil) }
                ForEach(desk.displays.filter { $0.id != screen.id && $0.mirrorSource == nil }) { other in
                    Button(other.name) { desk.mirror(screen, source: other) }
                }
            }.frame(maxWidth: 230, alignment: .leading)
            HStack {
                Button("Picture in Picture") { desk.startStream(screen) }
                if desk.streams.activeSources.contains(screen.id) { Button("Stop Streaming") { desk.streams.stop(source: screen.id) } }
            }
        }
        HStack {
            Button("Display Information…") { desk.showInfo?(screen) }; Spacer()
            Button("Open App Menu") { desk.expanded.insert(screen.key); desk.showMenu?() }
        }
    }

    private var applicationOptions: some View {
        PrefGroup("Application") {
            Toggle("Show Dock icon while Settings is open", isOn: $options.dockForSettings)
            Divider()
            Toggle("Open at login", isOn: Binding(get: { login }, set: { enable in
                do {
                    if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    login = SMAppService.mainApp.status == .enabled
                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                } catch { desk.report(error); login = SMAppService.mainApp.status == .enabled }
            }))
            Text("Move the app to Applications to use Open at login.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var menuOptions: some View {
        PrefGroup("Customize App Menu Contents") {
            Toggle("Brightness slider", isOn: $options.brightness)
            Divider(); Toggle("Resolution slider", isOn: $options.resolution)
            Divider(); Toggle("Show DDC controls on external displays", isOn: $options.hardware)
            Divider(); Toggle("Keep menu open when clicking outside it", isOn: $options.pinMenu)
            Button("Open App Menu") { desk.showMenu?() }
        }
    }

    private var keyboardOptions: some View {
        PrefGroup("Keyboard Shortcuts") {
            Toggle("Enable global shortcuts", isOn: $options.shortcuts)
            Divider()
            LabeledContent("Open app menu", value: "⌃⌥⌘ D")
            LabeledContent("Increase brightness", value: "⌃⌥⌘ ↑")
            LabeledContent("Decrease brightness", value: "⌃⌥⌘ ↓")
            Text("Brightness shortcuts adjust the display under the pointer in 5% steps.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var about: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return PrefGroup("About Screenfinch") {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screenfinch").font(.title2).bold()
                    Text("Version \(version) · Free macOS display utility").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 12) {
                if let url = Bundle.main.url(forResource: "GoodTools", withExtension: "png"),
                   let mark = NSImage(contentsOf: url) {
                    Image(nsImage: mark).resizable().renderingMode(.original).scaledToFit().padding(3)
                        .frame(width: 40, height: 40)
                        .background(Color(red: 0.98, green: 0.97, blue: 0.93), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Made by Good Tools").font(.headline)
                    Link("goodtools.ca", destination: URL(string: "https://goodtools.ca/")!)
                }
            }
        }
    }
}

struct PrefGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold)).padding(.leading, 2)
            VStack(alignment: .leading, spacing: 10, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Color.primary.opacity(0.042), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7))
        }
    }
}

private struct ArrangementView: View {
    @ObservedObject var desk: DeskState
    var body: some View {
        GeometryReader { geometry in
            let independent = desk.displays.filter { $0.mirrorSource == nil }
            let desktop = independent.reduce(CGRect.null) { $0.union(CGDisplayBounds($1.id)) }
            let scale = desktop.isNull ? 0 : min((geometry.size.width - 12) / max(1, desktop.width), (geometry.size.height - 12) / max(1, desktop.height))
            ZStack(alignment: .topLeading) {
                ForEach(independent) { display in
                    let rect = CGDisplayBounds(display.id)
                    let w = max(12, rect.width * scale - 2), h = max(10, rect.height * scale - 2)
                    Button { desk.settingsTarget = display.key } label: {
                        ZStack(alignment: .top) {
                            RoundedRectangle(cornerRadius: 5).fill(display.isMain ? Color.accentColor.opacity(0.82) : Color.accentColor.opacity(0.50))
                            if display.isMain { Capsule().fill(.white.opacity(0.9)).frame(width: max(8, w - 10), height: 3).padding(.top, 4) }
                            Image(systemName: display.symbol).foregroundStyle(.white).frame(width: w, height: h)
                        }.frame(width: w, height: h)
                    }.buttonStyle(.plain).help(display.name).accessibilityLabel(display.name)
                        .offset(x: (geometry.size.width - desktop.width * scale) / 2 + (rect.minX - desktop.minX) * scale,
                                y: (geometry.size.height - desktop.height * scale) / 2 + (rect.minY - desktop.minY) * scale)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
