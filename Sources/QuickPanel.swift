import AppKit
import SwiftUI

// Use the state property wrapper also supplied by Command Line Tools without SwiftUI macros.
typealias ViewState<Value> = SwiftUI.State<Value>

private struct MenuHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct QuickPanel: View {
    @ObservedObject var desk: DeskState
    @ObservedObject var options: DeskOptions
    let measured: (CGFloat) -> Void
    let close: () -> Void

    var body: some View {
        GeometryReader { viewport in
          VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(desk.displays) { screen in QuickScreen(desk: desk, options: options, screen: screen) }
                    ForEach(desk.disconnected) { item in
                        HStack {
                            Image(systemName: item.builtIn ? "laptopcomputer" : "display")
                            Text(item.name).lineLimit(1)
                            Spacer()
                            Toggle("Reconnect \(item.name)", isOn: Binding(get: { false }, set: { if $0 { desk.reconnect(item) } }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                        }.padding(.horizontal, 10).frame(height: 32).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if desk.displays.isEmpty && desk.disconnected.isEmpty {
                        Text("Waiting for displays…").foregroundStyle(.secondary).padding()
                    }
                    Button { desk.toolsExpanded.toggle() } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "ellipsis.circle.fill").foregroundStyle(.secondary)
                            Text("Tools"); Spacer()
                            Image(systemName: desk.toolsExpanded ? "chevron.up" : "chevron.down").font(.caption2)
                        }.padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(.quaternary.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                    if desk.toolsExpanded {
                        MenuAction("Displays and Virtual Screens", icon: "display.2") { desk.settingsTarget = nil; desk.showSettings?() }
                        MenuAction("Create Virtual Screen…", icon: "plus.rectangle.on.rectangle") { desk.showNewScreen?() }
                        MenuAction("Redetect Displays", icon: "arrow.clockwise") { desk.reload() }
                        if desk.streams.activeCount > 0 {
                            MenuAction("Stop All Streams", icon: "stop.circle") { desk.streams.stopAll() }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 2)
                    .background(GeometryReader { proxy in Color.clear.preference(key: MenuHeight.self, value: proxy.size.height) })
            }.frame(width: viewport.size.width, height: max(0, viewport.size.height - 32), alignment: .top)
            HStack(spacing: 8) {
                if let remaining = desk.countdown {
                    Button("Review change (\(remaining)s)") { desk.presentPreview?() }.buttonStyle(.plain).font(.caption)
                } else if let message = desk.notice {
                    Button { desk.showMessage?(message) } label: { Image(systemName: "exclamationmark.triangle") }
                        .help(message).buttonStyle(.plain)
                }
                Spacer()
                FooterButton("Settings", symbol: "gearshape") { desk.showSettings?() }
                Menu {
                    Toggle("Keep Menu Open", isOn: $options.pinMenu)
                    Button("Create Virtual Screen…") { desk.showNewScreen?() }
                    Divider()
                    Button("Quit Screenfinch") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More options")
                FooterButton("Close menu", symbol: "xmark") { close() }
            }.padding(.horizontal, 10).frame(height: 32)
          }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
        }.font(.system(size: 13)).onPreferenceChange(MenuHeight.self) { measured(ceil($0) + 32) }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    init(_ title: String, symbol: String, action: @escaping () -> Void) { self.title = title; self.symbol = symbol; self.action = action }
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 19, height: 19).background(.quaternary, in: Circle()) }
            .buttonStyle(.plain).accessibilityLabel(title).help(title)
    }
}

struct MenuAction: View {
    let title: String
    let icon: String
    var chevron: String?
    let action: () -> Void
    @ViewState private var hovered = false
    init(_ title: String, icon: String, chevron: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.chevron = chevron; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium)).frame(width: 20, height: 20)
                    .background(.quaternary, in: Circle())
                Text(title).lineLimit(1)
                Spacer(minLength: 1)
                if let chevron { Image(systemName: chevron).font(.caption2).foregroundStyle(.secondary) }
            }.padding(.horizontal, 8).frame(height: 25).contentShape(Rectangle())
        }.buttonStyle(.plain).background(hovered ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
    }
}

struct PillSlider: View {
    let title: String
    let symbol: String
    let value: Double
    var leftText: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    var rightText: (Double) -> String = { _ in "" }
    var step: Double = 0.05
    var live: ((Double) -> Void)?
    let commit: (Double) -> Void
    @ViewState private var dragValue: Double?
    @ViewState private var pointerHover = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let level = min(1, max(0, dragValue ?? value))
        GeometryReader { proxy in
            let radius: CGFloat = 10
            let span = max(1, proxy.size.width - 2 * radius)
            let x = radius + CGFloat(level) * span
            ZStack(alignment: .leading) {
                Capsule().fill(scheme == .dark ? Color.black.opacity(0.27) : Color.black.opacity(0.19))
                Capsule().fill(scheme == .dark ? Color.white.opacity(0.40) : .white.opacity(0.94))
                    .frame(width: min(proxy.size.width, x + radius))
                HStack(spacing: 5) {
                    Image(systemName: symbol).frame(width: 14)
                    Text(leftText(level))
                    Spacer(minLength: 0)
                    Text(rightText(level))
                }.font(.system(size: 10)).foregroundStyle(.primary.opacity(0.76))
                    .padding(.leading, x < 50 ? x + radius + 3 : 7)
                    .padding(.trailing, !rightText(level).isEmpty && x > proxy.size.width - 68 ? proxy.size.width - x + radius + 3 : 7)
                Circle().fill(scheme == .dark ? .white.opacity(0.87) : .white).frame(width: 19, height: 19)
                    .shadow(color: .black.opacity(0.23), radius: 1.5, y: 0.5).offset(x: x - 9.5)
                Capsule().strokeBorder(Color.primary.opacity(pointerHover ? 0.42 : 0.23), lineWidth: 0.7)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let newValue = min(1, max(0, Double((gesture.location.x - radius) / span)))
                dragValue = newValue; live?(newValue)
            }.onEnded { gesture in
                let newValue = min(1, max(0, Double((gesture.location.x - radius) / span)))
                dragValue = nil; commit(newValue)
            })
        }
        .frame(height: 21).opacity(enabled ? 1 : 0.5).onHover { pointerHover = $0 }
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
        .accessibilityValue([leftText(level), rightText(level)].joined(separator: " "))
        .accessibilityAdjustableAction { direction in commit(min(1, max(0, level + (direction == .increment ? step : -step)))) }
        .focusable().onMoveCommand { direction in
            if direction == .left || direction == .right { commit(min(1, max(0, level + (direction == .right ? step : -step)))) }
        }.help(title)
    }
}

private enum QuickSection { case modes, refresh, mirror, stream, move, rotation, image, ddc, input }

private struct QuickScreen: View {
    @ObservedObject var desk: DeskState
    @ObservedObject var options: DeskOptions
    let screen: DeskDisplay
    @ViewState private var section: QuickSection?
    @ViewState private var confirmDisconnect = false
    @ViewState private var selectedInput: UInt16?
    private var expanded: Bool { desk.expanded.contains(screen.key) }
    private var isVirtual: Bool { desk.virtual.ids.contains(screen.id) }
    private var others: [DeskDisplay] { desk.displays.filter { $0.id != screen.id } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { desk.toggleExpanded(screen) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isVirtual ? "rectangle.on.rectangle" : screen.symbol).frame(width: 17)
                        Text(screen.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if screen.isMain { Image(systemName: "m.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary).help("Main display") }
                        if screen.mirrorSource != nil { Image(systemName: "rectangle.on.rectangle").font(.caption2) }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("Show or hide controls for \(screen.name)")
                Toggle("Disconnect \(screen.name)", isOn: Binding(get: { true }, set: { if !$0 { confirmDisconnect = true } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(!isVirtual && !desk.connections.canDisconnect(screen, screens: desk.displays, virtualIDs: desk.virtual.ids,
                        confirmedPhysical: Set(desk.samples.filter { $0.value.method == "Apple backlight" || $0.value.method == "DDC/CI backlight" }.keys)))
                    .help(isVirtual ? "Disconnect this virtual screen" : "Disconnect this display for this app session")
            }
            .padding(.horizontal, 10).frame(height: 32).background(.quaternary.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            if options.brightness || options.resolution {
                VStack(spacing: 10) {
                    if options.brightness {
                        let sample = desk.samples[screen.id]
                        PillSlider(title: "Brightness · \(sample?.method ?? "Reading…")", symbol: "sun.max", value: sample?.value ?? 0,
                                   leftText: { sample == nil ? "Reading…" : "\(Int(($0 * 100).rounded()))%" },
                                   live: { desk.setBrightness(screen, $0, final: false) }) { desk.setBrightness(screen, $0) }
                            .disabled(sample?.canAdjust != true)
                    }
                    if options.resolution, let current = screen.current {
                        let modes = screen.sliderModes
                        let steps = max(1, modes.count - 1)
                        let index = modes.firstIndex { $0.id == current.id || $0.matchesTiming(current) } ?? 0
                        PillSlider(title: "Resolution for \(screen.name)", symbol: "macwindow", value: Double(index) / Double(steps),
                                   leftText: { v in
                                       guard !modes.isEmpty else { return "–" }
                                       let m = modes[min(modes.count - 1, Int((v * Double(steps)).rounded()))]
                                       guard let baseline = screen.defaultLogicalWidth else { return m.isHiDPI ? "HiDPI" : "1×" }
                                       return "\(Int((100 * Double(baseline) / Double(max(1, m.width))).rounded()))%"
                                   }, rightText: { v in
                                       guard !modes.isEmpty else { return current.sizeLabel }
                                       return modes[min(modes.count - 1, Int((v * Double(steps)).rounded()))].sizeLabel
                                   }, step: 1 / Double(steps)) { v in
                            guard !modes.isEmpty else { return }
                            desk.changeMode(screen, modes[min(modes.count - 1, Int((v * Double(steps)).rounded()))])
                        }.disabled(modes.count < 2)
                    }
                }.padding(.horizontal, 11).padding(.top, 10).padding(.bottom, 4)
            }
            if expanded { expandedContent.padding(.top, 4) }
            Button {
                desk.toggleExpanded(screen)
            } label: {
                Image(systemName: expanded ? "chevron.compact.up" : "chevron.compact.down")
                    .font(.system(size: 18, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(expanded ? "Fewer controls for \(screen.name)" : "More controls for \(screen.name)")
        }
        .alert(isVirtual ? "Disconnect \(screen.name)?" : "Disconnect \(screen.name) from the desktop?", isPresented: $confirmDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect") { if isVirtual { desk.removeVirtual(screen) } else { desk.disconnect(screen) } }
        } message: {
            Text(isVirtual ? "You can reconnect this screen from Tools." : "You can reconnect it from the menu. Physical connections are restored when Screenfinch quits.")
        }
        .alert("Switch monitor input?", isPresented: Binding(get: { selectedInput != nil }, set: { if !$0 { selectedInput = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Switch Input") { if let selectedInput { desk.setInput(selectedInput, on: screen) }; selectedInput = nil }
        } message: { Text("Switching to \(selectedInput.map(MonitorInputs.title) ?? "this input") may disconnect this Mac. Use the monitor’s own controls to switch back.") }
    }

    private func sectionButton(_ item: QuickSection, _ title: String, _ symbol: String) -> some View {
        MenuAction(title, icon: symbol, chevron: section == item ? "chevron.down" : "chevron.right") {
            section = section == item ? nil : item
            if item == .ddc { desk.readExtras(screen) }
            if item == .input { desk.readInputs(screen) }
        }
    }

    @ViewBuilder private var expandedContent: some View {
        VStack(spacing: 0) {
            sectionButton(.modes, "Display Mode", "macwindow")
            if section == .modes {
                VStack(spacing: 0) {
                    ForEach(desk.favorites.filter { $0.screen == screen.key }) { favorite in
                        if let mode = screen.modes.first(where: { $0.matchesTiming(favorite.mode) }) {
                            item(mode.modeLabel, checked: screen.current?.matchesTiming(mode) == true, symbol: "star") { desk.changeMode(screen, mode) }
                        }
                    }
                    ForEach(screen.sliderModes.reversed()) { mode in
                        item(mode.sizeLabel, checked: screen.current?.matchesTiming(mode) == true) { desk.changeMode(screen, mode) }
                    }
                    item("All Display Modes…", symbol: "line.3.horizontal.decrease.circle") { desk.showModes?(screen) }
                    if let active = screen.current {
                        item(desk.isFavorite(screen, active) ? "Remove Current Favorite" : "Favorite Current Mode", symbol: "star") { desk.toggleFavorite(screen, active) }
                    }
                }.padding(.leading, 20)
            }
            sectionButton(.refresh, "Refresh Rate", "wave.3.right")
            if section == .refresh {
                ForEach(screen.refreshModes) { mode in
                    item(mode.rateLabel, checked: screen.current?.matchesTiming(mode) == true) { desk.changeMode(screen, mode) }
                }.padding(.leading, 20)
            }
            sectionButton(.mirror, "Mirror Display", "rectangle.on.rectangle")
            if section == .mirror {
                item("Extend Desktop", checked: screen.mirrorSource == nil) { desk.mirror(screen, source: nil) }.padding(.leading, 20)
                ForEach(others.filter { $0.mirrorSource == nil }) { other in
                    item(other.name, checked: screen.mirrorSource == other.id) { desk.mirror(screen, source: other) }
                }.padding(.leading, 20)
            }
            sectionButton(.stream, "Stream Display", "macwindow.on.rectangle")
            if section == .stream {
                if others.isEmpty { Text("Connect another display to stream to it.").font(.caption).foregroundStyle(.secondary).padding(4) }
                ForEach(others.filter { $0.mirrorSource == nil }) { other in
                    item("Stream to \(other.name)") { desk.startStream(screen, to: other) }
                }.padding(.leading, 20)
                if desk.streams.activeSources.contains(screen.id) {
                    item("Stop streams from this display", symbol: "stop.circle") { desk.streams.stop(source: screen.id) }.padding(.leading, 20)
                }
            }
            MenuAction("Picture in Picture", icon: "pip") { desk.startStream(screen) }
            if !others.isEmpty {
                sectionButton(.move, "Move Display", "square.grid.2x2")
                if section == .move {
                    ForEach(others.filter { $0.mirrorSource == nil }) { other in
                        Menu {
                            ForEach(DeskEdge.allCases, id: \.rawValue) { edge in
                                Button(edge.rawValue.capitalized) { desk.previewChange { try desk.preview.previewMove(display: screen, relativeTo: other, edge: edge) } }
                            }
                        } label: { Text("Relative to \(other.name)") }.padding(.horizontal, 20)
                    }
                }
            }
            if let choices = desk.rotations[screen.id], !choices.isEmpty {
                sectionButton(.rotation, "Screen Rotation", "rotate.right")
                if section == .rotation {
                    ForEach(choices, id: \.self) { degrees in
                        item("\(degrees)°", checked: Int(CGDisplayRotation(screen.id)) == degrees) {
                            desk.previewChange { try desk.preview.previewRotation(display: screen, degrees: degrees) }
                        }
                    }.padding(.leading, 20)
                }
            }
            if let values = desk.imageValues[screen.id] {
                sectionButton(.image, "Image Adjustments", "circle.lefthalf.filled")
                if section == .image { colorControls(values) }
            }
            if options.hardware && !screen.builtIn && !isVirtual {
                sectionButton(.ddc, "DDC Control", "slider.horizontal.3")
                if section == .ddc {
                    if let values = desk.extras[screen.id] {
                        if values.isEmpty { Text("No additional hardware controls reported.").font(.caption).foregroundStyle(.secondary).padding(5) }
                        ForEach(MonitorAdjustment.allCases, id: \.rawValue) { control in
                            if let value = values[control] {
                                PillSlider(title: control == .contrast ? "Contrast" : "Speaker volume",
                                           symbol: control == .contrast ? "circle.lefthalf.filled" : "speaker.wave.2", value: value,
                                           rightText: { _ in control == .contrast ? "Contrast" : "Volume" }) {
                                    desk.setExtra(screen, control, $0)
                                }.padding(.horizontal, 12).padding(.vertical, 4)
                            }
                        }
                    } else { ProgressView().controlSize(.small).padding(4) }
                }
                if desk.samples[screen.id]?.method == "DDC/CI backlight" || desk.extras[screen.id]?.isEmpty == false {
                    sectionButton(.input, "DDC Input Source", "rectangle.connected.to.line.below")
                    if section == .input {
                        if desk.readingInputs.contains(screen.id) { ProgressView().controlSize(.small).padding(4) }
                        else if let inputs = desk.inputs[screen.id] {
                            Text(inputs.currentTitle).font(.caption).foregroundStyle(.secondary)
                            ForEach(inputs.choices, id: \.self) { value in
                                item(MonitorInputs.title(value), checked: value == inputs.current) { if value != inputs.current { selectedInput = value } }
                            }.padding(.leading, 20)
                        } else { Text("This monitor did not report selectable inputs.").font(.caption).foregroundStyle(.secondary).padding(5) }
                    }
                }
            }
            if let current = screen.current {
                let matched = screen.modes.first { $0.width == current.width && $0.height == current.height && $0.isHiDPI != current.isHiDPI && abs($0.hz - current.hz) < 0.01 }
                MenuAction("High Resolution (HiDPI)", icon: current.isHiDPI ? "sparkles" : "sparkle") {
                    if let matched { desk.changeMode(screen, matched) } else { desk.showModes?(screen) }
                }
            }
            MenuAction("Set as Main Display", icon: screen.isMain ? "m.circle.fill" : "m.circle") {
                desk.previewChange { try desk.preview.previewMain(display: screen) }
            }.disabled(screen.isMain || screen.mirrorSource != nil)
            if let hdr = desk.hdrStates[screen.id] {
                MenuAction(hdr ? "Disable HDR Mode" : "Enable HDR Mode", icon: "sun.max.fill") { desk.toggleHDR(screen) }
            }
            MenuAction("Display Information", icon: "info.circle") { desk.showInfo?(screen) }
        }
    }

    @ViewBuilder private func colorControls(_ values: DeskColorValues) -> some View {
        VStack(spacing: 7) {
            PillSlider(title: "Gamma", symbol: "circle.grid.cross", value: values.gamma - 0.6,
                       leftText: { String(format: "%.2f", $0 + 0.6) }, rightText: { _ in "Gamma" }) {
                var new = values; new.gamma = 0.6 + $0; desk.setColors(new, on: screen)
            }
            PillSlider(title: "Warmth", symbol: "thermometer.medium", value: values.warmth, rightText: { _ in "Warmth" }) {
                var new = values; new.warmth = $0; desk.setColors(new, on: screen)
            }
            PillSlider(title: "Software contrast", symbol: "circle.lefthalf.filled", value: (values.contrast - 0.6) / 0.8,
                       leftText: { String(format: "%.2f", 0.6 + 0.8 * $0) }, rightText: { _ in "Contrast" }) {
                var new = values; new.contrast = 0.6 + 0.8 * $0; desk.setColors(new, on: screen)
            }
            Button("Reset Image Adjustments") { desk.setColors(DeskColorValues(), on: screen) }.font(.caption)
        }.padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func item(_ title: String, checked: Bool = false, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: checked ? "checkmark" : (symbol ?? "circle")).font(.system(size: checked || symbol != nil ? 11 : 4)).frame(width: 12)
                Text(title).lineLimit(1); Spacer()
            }.font(.system(size: 12)).padding(.horizontal, 8).frame(height: 23).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
