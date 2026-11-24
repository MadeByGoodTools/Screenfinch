import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModeBrowser: View {
    @ObservedObject var desk: DeskState
    let screenKey: String
    @ViewState private var query = ""
    @ViewState private var filter = 0
    @ViewState private var selected: Int?
    let close: () -> Void

    var body: some View {
        if let screen = desk.displays.first(where: { $0.key == screenKey }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(screen.name).font(.title2.bold())
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter by resolution or refresh rate", text: $query).textFieldStyle(.plain)
                }.padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Picker("Display modes", selection: $filter) {
                    Text("All modes").tag(0)
                    Text("HiDPI").tag(1)
                    Text("Favorites").tag(2)
                }.labelsHidden().pickerStyle(.segmented)
                let modes = screen.modes.filter { mode in
                    let text = query.replacingOccurrences(of: "x", with: "×").replacingOccurrences(of: " ", with: "")
                    let matches = text.isEmpty || mode.modeLabel.replacingOccurrences(of: " ", with: "").localizedCaseInsensitiveContains(text)
                    return matches && (filter != 1 || mode.isHiDPI) && (filter != 2 || desk.isFavorite(screen, mode))
                }
                if modes.isEmpty {
                    Text(filter == 2 ? "Star a display mode to save it here." : "No matching display modes.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(modes, selection: $selected) { mode in
                        HStack(spacing: 9) {
                            Image(systemName: screen.current?.matchesTiming(mode) == true ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(screen.current?.matchesTiming(mode) == true ? Color.accentColor : .secondary)
                            Text(mode.sizeLabel).fontWeight(.medium)
                            if mode.isHiDPI { Text("HiDPI").font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Text(mode.rateLabel).monospacedDigit()
                            Button { desk.toggleFavorite(screen, mode) } label: { Image(systemName: desk.isFavorite(screen, mode) ? "star.fill" : "star") }
                                .buttonStyle(.borderless).help("Toggle favorite for \(mode.modeLabel)")
                        }.padding(.vertical, 2).tag(mode.id)
                    }.listStyle(.bordered(alternatesRowBackgrounds: true))
                }
                HStack {
                    Text("\(modes.count) modes").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction)
                    Button("Preview Mode") {
                        if let mode = modes.first(where: { $0.id == selected }) { desk.changeMode(screen, mode) }
                    }.keyboardShortcut(.defaultAction).disabled(!modes.contains { $0.id == selected } || selected == screen.current?.id)
                }
            }.padding(20).onAppear { selected = screen.current?.id }
        } else { Text("This display disconnected.").padding() }
    }
}

struct NewScreenForm: View {
    @ObservedObject var desk: DeskState
    let close: () -> Void
    var target: DeskDisplay?
    @ViewState private var name = ""
    @ViewState private var width = "1920"
    @ViewState private var height = "1080"
    @ViewState private var hiDPI = true
    @ViewState private var reconnect = false
    @ViewState private var mirrorKey = ""
    @ViewState private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Create Virtual Screen", systemImage: "display.2").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 12) {
                GridRow { Text("Name"); TextField("Screenfinch Display", text: $name) }
                GridRow {
                    Text("Resolution")
                    HStack {
                        TextField("Width", text: $width).accessibilityLabel("Logical width")
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", text: $height).accessibilityLabel("Logical height")
                        Menu {
                            ForEach(["1280 × 720", "1920 × 1080", "2560 × 1440", "3440 × 1440", "1080 × 1920"], id: \.self) { size in
                                Button(size) { let parts = size.components(separatedBy: " × "); width = parts[0]; height = parts[1] }
                            }
                        } label: { Image(systemName: "chevron.down") }.fixedSize().help("Common sizes")
                    }
                }
                GridRow { Text("Pixel density"); Toggle("High Resolution (HiDPI)", isOn: $hiDPI) }
                GridRow {
                    Text("Desktop")
                    Picker("Desktop", selection: $mirrorKey) {
                        Text("Extend desktop").tag("")
                        ForEach(desk.displays.filter { !desk.virtual.ids.contains($0.id) && $0.mirrorSource == nil }) { screen in
                            Text("Mirror onto \(screen.name)").tag(screen.key)
                        }
                    }.labelsHidden()
                }
            }
            if let w = Int(width), let h = Int(height), (1...8192).contains(w), (1...8192).contains(h) {
                Text("\(w * (hiDPI ? 2 : 1)) × \(h * (hiDPI ? 2 : 1)) backing pixels · 60 Hz").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Reconnect this virtual screen when Screenfinch opens", isOn: $reconnect)
            if let errorText { Text(errorText).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                Spacer(); Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).onAppear {
            if let target {
                mirrorKey = target.key
                name = "\(target.name) HiDPI"
                if let mode = target.current { width = String(mode.width); height = String(mode.height) }
            }
        }
    }

    private func create() {
        guard let w = Int(width), let h = Int(height) else { errorText = "Enter a whole number for the width and height."; return }
        do {
            let previous = desk.virtual.ids
            try desk.newVirtual(width: w, height: h, hiDPI: hiDPI, name: name, reconnect: reconnect)
            let virtualID = desk.virtual.ids.subtracting(previous).first
            if let virtualID, !mirrorKey.isEmpty {
                let targetKey = mirrorKey
                Task { @MainActor in
                    for _ in 0..<12 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        guard desk.virtual.ids.contains(virtualID) else { return }
                        if let screens = try? DisplaySystem.list(),
                           let source = screens.first(where: { $0.id == virtualID && $0.current != nil }),
                           let target = screens.first(where: { $0.key == targetKey }) {
                            desk.mirror(target, source: source)
                            return
                        }
                    }
                    desk.notice = "The virtual screen was created. Open Mirror Display to pair it after macOS finishes connecting."
                    desk.showMessage?(desk.notice!)
                }
            }
            close()
        } catch { errorText = error.localizedDescription }
    }
}

struct InfoView: View {
    @ObservedObject var desk: DeskState
    let key: String
    @ViewState private var exported = false
    @ViewState private var rawEDID: Data?
    var body: some View {
        if let screen = desk.displays.first(where: { $0.key == key }) {
            let size = CGDisplayScreenSize(screen.id)
            let bounds = CGDisplayBounds(screen.id)
            VStack(alignment: .leading, spacing: 13) {
                Label(screen.name, systemImage: screen.symbol).font(.title2.bold())
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    row("Connection", desk.virtual.ids.contains(screen.id) ? "Virtual screen" : (screen.builtIn ? "Built-in display" : "External display"))
                    if let mode = screen.current {
                        row("Logical size", mode.sizeLabel); row("Backing pixels", "\(mode.pixelWidth) × \(mode.pixelHeight)"); row("Refresh rate", mode.rateLabel)
                    }
                    row("Physical size", "\(Int(size.width)) × \(Int(size.height)) mm")
                    row("Position", "\(Int(bounds.minX)), \(Int(bounds.minY))")
                    row("Rotation", "\(Int(CGDisplayRotation(screen.id)))°")
                    row("Vendor / product", String(format: "%04X / %04X", CGDisplayVendorNumber(screen.id), CGDisplayModelNumber(screen.id)))
                    row("Display ID", String(screen.id)); row("UUID", screen.key)
                    if let sample = desk.samples[screen.id] { row("Brightness control", sample.method) }
                }.textSelection(.enabled)
                Spacer()
                HStack {
                    Button("Export EDID…") { exportEDID(screen) }
                        .disabled(rawEDID == nil)
                    if exported { Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(20).task(id: screen.key) { rawEDID = DisplayDetails.edid(for: screen) }
        } else { Text("This display disconnected.").padding() }
    }
    private func row(_ key: String, _ value: String) -> some View {
        GridRow { Text(key).foregroundStyle(.secondary); Text(value).font(.system(size: 12)).lineLimit(2) }
    }
    private func exportEDID(_ screen: DeskDisplay) {
        guard let data = DisplayDetails.edid(for: screen) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = screen.name.replacingOccurrences(of: "/", with: "-") + ".edid"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url, options: .atomic); exported = true } catch { desk.report(error) }
        }
    }
}

struct OverrideForm: View {
    @ObservedObject var desk: DeskState
    let screen: DeskDisplay
    let close: () -> Void
    @ViewState private var original: Data?
    @ViewState private var replacement: Data?
    @ViewState private var modelName = ""
    @ViewState private var width = "1920"
    @ViewState private var height = "1080"
    @ViewState private var hidpi = true
    @ViewState private var modes = [DisplayOverride.Mode]()
    @ViewState private var message: String?
    @ViewState private var file: URL?
    private var vendor: UInt32 { CGDisplayVendorNumber(screen.id) }
    private var product: UInt32 { CGDisplayModelNumber(screen.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display Override").font(.title2.bold())
            Text("\(screen.name) · " + String(format: "Vendor %04X, product %04X", vendor, product)).foregroundStyle(.secondary)
            TextField("Optional model name", text: $modelName)
            HStack {
                TextField("Logical width", text: $width); Text("×"); TextField("Logical height", text: $height)
                Toggle("HiDPI", isOn: $hidpi)
                Button("Add") { addMode() }
            }
            HStack {
                Button("Generate Scaled Sizes") {
                    guard let w = Int(width), let h = Int(height), (320...16384).contains(w), (200...16384).contains(h) else {
                        message = "Enter the panel's native pixel dimensions before generating scaled sizes."; return
                    }
                    do {
                        let added = try DisplayOverride.smoothModes(panelWidth: w, panelHeight: h)
                        for mode in added where !modes.contains(mode) { modes.append(mode) }
                        message = nil
                    } catch { message = error.localizedDescription }
                }.help("Generate HiDPI sizes using the two fields above as the panel's native dimensions.")
                Spacer()
                Text("\(modes.count) custom modes").font(.caption).foregroundStyle(.secondary)
            }
            List(modes, id: \.self) { mode in
                HStack {
                    Text("\(mode.width) × \(mode.height) · \(mode.scale == 2 ? "HiDPI" : "1×")")
                    Spacer()
                    Button { modes.removeAll { $0 == mode } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove this mode")
                }
            }.frame(minHeight: 75)
            HStack {
                Button(original == nil ? "Import Original EDID…" : "Import Replacement EDID…") { chooseEDID() }
                if replacement != nil { Button("Clear Replacement") { replacement = nil } }
            }
            Text("Exports a model-specific macOS override to the folder you choose. Activation depends on the macOS version and display connection.").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            if let file { Button("Show Export in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
            HStack {
                Spacer(); Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button("Export…") { export() }.keyboardShortcut(.defaultAction)
                    .disabled(original == nil || (modes.isEmpty && replacement == nil && modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(20).onAppear {
            original = DisplayDetails.edid(for: screen)
            if let mode = screen.current { width = String(mode.pixelWidth); height = String(mode.pixelHeight) }
        }
    }

    private func addMode() {
        guard let w = Int(width), let h = Int(height), (320...16384).contains(w), (200...16384).contains(h) else {
            message = "Width must be 320–16384, and height must be 200–16384."; return
        }
        let mode = DisplayOverride.Mode(width: w, height: h, scale: hidpi ? 2 : 1)
        if !modes.contains(mode) { modes.append(mode) }
        message = nil
    }
    private func chooseEDID() {
        let picker = NSOpenPanel()
        picker.title = original == nil ? "Choose original display EDID" : "Choose replacement display EDID"
        picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let bytes = try DisplayOverride.readEDID(at: url, vendor: vendor, product: product)
            if original == nil { original = bytes } else { replacement = bytes }
            message = nil
        } catch { message = error.localizedDescription }
    }
    private func export() {
        guard let original, desk.current(screen) != nil else { message = "Reconnect this display to export its profile."; return }
        let directory = NSOpenPanel()
        directory.title = "Choose an export folder"; directory.prompt = "Export Here"
        directory.canChooseDirectories = true; directory.canCreateDirectories = true; directory.canChooseFiles = false
        guard directory.runModal() == .OK, let url = directory.url else { return }
        do {
            let profile = try DisplayOverride(vendor: vendor, product: product, originalEDID: original,
                                              replacementEDID: replacement, name: modelName, modes: modes)
            file = try profile.write(to: url)
            message = nil
        } catch { message = error.localizedDescription }
    }
}

struct ConfirmView: View {
    @ObservedObject var desk: DeskState
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Keep this display configuration?", systemImage: "display").font(.headline)
            if let seconds = desk.countdown, seconds > 0 {
                Text("Your previous configuration returns in \(seconds) seconds.").monospacedDigit()
            } else { Text("Restore the previous configuration or keep the current one.") }
            HStack {
                Spacer(); Button("Revert") { desk.finishPreview(keep: false) }.keyboardShortcut(.cancelAction)
                Button("Keep") { desk.finishPreview(keep: true) }.keyboardShortcut(.defaultAction)
            }
        }.padding(18)
    }
}
