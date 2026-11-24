import CoreGraphics
import Darwin
import Foundation
import IOKit.graphics

/// Queries existing WindowServer modes. The current Quartz mode independently
/// checks the private descriptor layout before any supplemental mode is offered.
enum NativeHiDPIModes {
    struct Entry {
        let number: Int32
        let flags: UInt32
        let width: Int
        let height: Int
        let scale: Int
        let hz: Double

        var mode: DeskMode {
            // The high range is disjoint from every 32-bit Quartz I/O mode ID.
            DeskMode(id: Int(UInt32.max) + 1 + Int(number), width: width, height: height,
                     pixelWidth: width * scale, pixelHeight: height * scale, hz: hz, nativeNumber: number)
        }

        var selectable: Bool {
            let excluded = UInt32(kDisplayModeInterlacedFlag | kDisplayModeNeverShowFlag)
            let advertised = UInt32(kDisplayModeValidForMirroringFlag | kDisplayModeSafeFlag)
            return scale == 2 && flags & UInt32(kDisplayModeValidFlag) != 0 &&
                   flags & excluded == 0 && flags & advertised != 0
        }

        func agrees(with quartz: CGDisplayMode) -> Bool {
            width == quartz.width && height == quartz.height && width * scale == quartz.pixelWidth &&
            height * scale == quartz.pixelHeight && abs(hz - quartz.refreshRate) < 0.005
        }
    }

    private typealias GetCount = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Void
    private typealias GetRecord = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Void
    private typealias GetCurrent = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Int32
    private typealias Configure = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Int32) -> Int32
    private struct API {
        let count: GetCount
        let record: GetRecord
        let current: GetCurrent
        let configure: Configure

        init?() {
            guard let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else { return nil }
            guard let c = dlsym(framework, "CGSGetNumberOfDisplayModes"),
                  let r = dlsym(framework, "CGSGetDisplayModeDescriptionOfLength"),
                  let a = dlsym(framework, "CGSGetCurrentDisplayMode"),
                  let w = dlsym(framework, "CGSConfigureDisplayMode") else { dlclose(framework); return nil }
            count = unsafeBitCast(c, to: GetCount.self)
            record = unsafeBitCast(r, to: GetRecord.self)
            current = unsafeBitCast(a, to: GetCurrent.self)
            configure = unsafeBitCast(w, to: Configure.self)
        }

        func entry(_ display: CGDirectDisplayID, index: Int32) -> Entry? {
            // SkyLight ABI also used by jakehilborn/displayplacer and Hammerspoon.
            // Known 212-byte mode descriptor. The API has no status result, so
            // a cleared/unknown record must never become a selectable timing.
            var words = [UInt32](repeating: 0, count: 53)
            words.withUnsafeMutableBytes { record(display, index, $0.baseAddress!, Int32($0.count)) }
            let scale = Float(bitPattern: words[52])
            guard let number = Int32(exactly: words[0]), words[2] > 0, words[3] > 0,
                  scale == 1 || scale == 2 else { return nil }
            return Entry(number: number, flags: words[1], width: Int(words[2]), height: Int(words[3]),
                         scale: Int(scale), hz: Double(words[47]) / 65_536)
        }
    }
    private static let api = API()

    /// A descriptor's scale is read directly. Its flags alone say nothing about HiDPI.
    static func table(_ display: CGDirectDisplayID, quartz: CGDisplayMode?) -> (entries: [Entry], current: Entry)? {
        guard let api, let quartz, CGDisplayIsOnline(display) != 0 else { return nil }
        var count: Int32 = 0, active: Int32 = -1
        api.count(display, &count)
        guard (1...16384).contains(count), api.current(display, &active) == 0, active >= 0 else { return nil }
        var entries = [Entry]()
        var numbers = Set<Int32>()
        for index in 0..<count {
            guard let value = api.entry(display, index: index) else { continue }
            guard numbers.insert(value.number).inserted else { return nil }
            entries.append(value)
        }
        var finalCount: Int32 = 0, finalActive: Int32 = -1
        api.count(display, &finalCount)
        guard finalCount == count, api.current(display, &finalActive) == 0, finalActive == active,
              let current = entries.first(where: { $0.number == active }), current.agrees(with: quartz) else { return nil }
        return (entries, current)
    }

    static func active(_ display: CGDirectDisplayID, quartz: CGDisplayMode?) -> Entry? {
        guard let api, let quartz, quartz.pixelWidth == quartz.width * 2, quartz.pixelHeight == quartz.height * 2 else { return nil }
        var active: Int32 = -1, count: Int32 = 0
        api.count(display, &count)
        guard (1...16384).contains(count), api.current(display, &active) == 0, active >= 0 else { return nil }
        if active < count, let value = api.entry(display, index: active), value.number == active, value.agrees(with: quartz) {
            return value
        }
        return table(display, quartz: quartz)?.current
    }

    static func configure(_ config: CGDisplayConfigRef, display: CGDirectDisplayID, number: Int32) -> CGError {
        guard let api else { return .notImplemented }
        return CGError(rawValue: api.configure(config, display, number)) ?? .failure
    }
}
