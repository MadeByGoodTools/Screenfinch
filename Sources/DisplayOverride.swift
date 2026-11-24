import Darwin
import Foundation

/// An offline per-model macOS display override. Serial numbers do not participate
/// in the file path, so only include EDID bytes when the user explicitly imports them.
struct DisplayOverride {
    struct Mode: Hashable {
        let width: Int
        let height: Int
        let scale: Int

        fileprivate func record() throws -> Data {
            guard scale == 1 || scale == 2, let w = UInt32(exactly: width), let h = UInt32(exactly: height),
                  w > 0, h > 0 else { throw Failure("Enter positive dimensions and a scale of 1× or 2×.") }
            let (pixelsWide, overWidth) = w.multipliedReportingOverflow(by: UInt32(scale))
            let (pixelsHigh, overHeight) = h.multipliedReportingOverflow(by: UInt32(scale))
            guard !overWidth, !overHeight else { throw Failure("The requested backing size is too large.") }
            // Apple's scale-resolutions entries contain big-endian 32-bit words.
            // Use a plain size for 1x. For 2x, request the backing dimensions and
            // the install-always flag used in the shipped, 12-byte override form.
            var words = [pixelsWide, pixelsHigh]
            if scale == 2 { words.append(1) }
            return words.map(\.bigEndian).withUnsafeBytes { Data($0) }
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    let vendor: UInt32
    let product: UInt32
    private let contents: Data

    static func checkedEDID(_ data: Data, vendor: UInt32, product: UInt32) throws -> Data {
        guard vendor > 0, vendor <= UInt16.max, product <= UInt16.max else {
            throw Failure("This display does not report a usable EDID vendor and product ID.")
        }
        guard data.count >= 128, data.count <= 32768, data.count.isMultiple(of: 128) else {
            throw Failure("An EDID must contain complete 128-byte blocks.")
        }
        let bytes = [UInt8](data)
        guard bytes.starts(with: [0, 255, 255, 255, 255, 255, 255, 0]),
              bytes[18] == 1, bytes[19] <= 4 else {
            throw Failure("This file does not contain a recognized EDID 1.x header.")
        }
        guard bytes.count == (Int(bytes[126]) + 1) * 128 else {
            throw Failure("The EDID extension count does not match the file length.")
        }
        for block in 0..<(bytes.count / 128) {
            let start = block * 128
            guard bytes[start..<(start + 128)].reduce(UInt8(0), &+) == 0 else {
                throw Failure("EDID block \(block + 1) has an invalid checksum.")
            }
        }
        let manufacturer = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        let model = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        guard manufacturer == vendor, model == product else {
            throw Failure("The EDID vendor or product ID differs from the selected display.")
        }
        return Data(bytes)
    }

    static func readEDID(at url: URL, vendor: UInt32, product: UInt32) throws -> Data {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw Failure("Choose a binary EDID file.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var bytes = Data()
        while bytes.count <= 32768 {
            guard let part = try file.read(upToCount: 32769 - bytes.count), !part.isEmpty else { break }
            bytes.append(part)
        }
        return try checkedEDID(bytes, vendor: vendor, product: product)
    }

    /// Suggested 2x logical sizes from approximately half-native to below native,
    /// preserving the aspect ratio. macOS and the display decide which to expose.
    static func smoothModes(panelWidth: Int, panelHeight: Int) throws -> [Mode] {
        guard (2...Int(UInt32.max / 2)).contains(panelWidth),
              (2...Int(UInt32.max / 2)).contains(panelHeight) else {
            throw Failure("Enter the display's native pixel width and height.")
        }
        let half = panelWidth / 2
        let step = max(64, ((half + 4095) / 4096) * 64)
        let widths = Array(stride(from: panelWidth - step, to: half, by: -step)) + [half]
        return widths.filter { $0 > 0 }.map { width in
            let height = max(1, Int((Double(width) * Double(panelHeight) / Double(panelWidth)).rounded()))
            return Mode(width: width, height: height, scale: 2)
        }
    }

    init(vendor: UInt32, product: UInt32, originalEDID: Data, replacementEDID: Data? = nil,
         name: String? = nil, modes: [Mode]) throws {
        self.vendor = vendor
        self.product = product
        _ = try Self.checkedEDID(originalEDID, vendor: vendor, product: product)
        var plist: [String: Any] = ["DisplayVendorID": Int(vendor), "DisplayProductID": Int(product)]
        if let replacementEDID {
            plist["IODisplayEDID"] = try Self.checkedEDID(replacementEDID, vendor: vendor, product: product)
        }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            guard name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) &&
                $0.value != 0xfffe && $0.value != 0xffff }) else {
                throw Failure("Use printable characters for the model name.")
            }
            plist["DisplayProductName"] = name
        }
        if !modes.isEmpty {
            var seen = Set<Mode>()
            plist["scale-resolutions"] = try modes.filter { seen.insert($0).inserted }.map { try $0.record() }
        }
        guard plist.count > 2 else { throw Failure("Add a size, a model name, or a replacement EDID.") }
        contents = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Stage a complete file in the chosen directory and publish it atomically.
    /// A vendor-folder symlink cannot redirect an export. Existing files survive
    /// a collision unless the caller has explicitly authorized replacement.
    func write(to folder: URL, replacingExisting: Bool = false) throws -> URL {
        guard folder.isFileURL else { throw Failure("Choose a local export folder.") }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        for systemPath in ["/Library/Displays/Contents/Resources/Overrides",
                           "/System/Library/Displays/Contents/Resources/Overrides"] {
            let resolved = root.path.lowercased()
            let candidates = [systemPath.lowercased(), "/system/volumes/data" + systemPath.lowercased()]
            if candidates.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
                throw Failure("Choose an export folder outside the system display overrides.")
            }
        }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw posixError() }
        defer { close(rootFD) }

        let vendorFolder = "DisplayVendorID-" + String(vendor, radix: 16)
        let productFile = "DisplayProductID-" + String(product, radix: 16)
        if mkdirat(rootFD, vendorFolder, 0o755) != 0 && errno != EEXIST { throw posixError() }
        let vendorFD = openat(rootFD, vendorFolder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard vendorFD >= 0 else { throw posixError() }
        defer { close(vendorFD) }

        let staging = ".displaydesk-" + UUID().uuidString
        let fd = openat(vendorFD, staging, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); unlinkat(vendorFD, staging, 0) }
        try file.write(contentsOf: contents)
        try file.close()
        let flags = replacingExisting ? 0 : UInt32(RENAME_EXCL)
        guard renameatx_np(vendorFD, staging, vendorFD, productFile, flags) == 0 else {
            if errno == EEXIST { throw Failure("An override already exists here. Choose another folder or confirm replacement.") }
            throw posixError()
        }
        return root.appendingPathComponent(vendorFolder, isDirectory: true).appendingPathComponent(productFile)
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
