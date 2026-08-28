import Foundation
import CoreGraphics

struct RGBA {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    init(hex: UInt32) {
        a = CGFloat((hex >> 24) & 0xff) / 255
        r = CGFloat((hex >> 16) & 0xff) / 255
        g = CGFloat((hex >> 8) & 0xff) / 255
        b = CGFloat(hex & 0xff) / 255
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var isInvisible: Bool { a == 0 }
}

enum GradientDirection: String {
    case topLeftToBottomRight = "tl_to_br"
    case topRightToBottomLeft = "tr_to_bl"
}

enum ColorStyle: Equatable {
    case solid(UInt32)
    case glow(UInt32)
    case gradient(UInt32, UInt32, GradientDirection)

    var isGlow: Bool { if case .glow = self { return true }; return false }

    var isInvisible: Bool {
        switch self {
        case .solid(let c), .glow(let c): return RGBA(hex: c).isInvisible
        case .gradient(let a, let b, _): return RGBA(hex: a).isInvisible && RGBA(hex: b).isInvisible
        }
    }

    static func == (l: ColorStyle, r: ColorStyle) -> Bool {
        switch (l, r) {
        case (.solid(let a), .solid(let b)): return a == b
        case (.glow(let a), .glow(let b)): return a == b
        case (.gradient(let a1, let a2, let a3), .gradient(let b1, let b2, let b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        default: return false
        }
    }
}

enum BorderStyle: String {
    case round          // follow the window's own corner radius
    case uniform        // fixed 9pt radius
    case square
}

enum BorderOrder: Int32 {
    case above = 1
    case below = -1
}

struct Settings {
    var active: ColorStyle = .solid(0xff2f9bff)
    var inactive: ColorStyle = .solid(0x00000000)
    var width: CGFloat = 4.0
    var padding: CGFloat = 4.0
    var style: BorderStyle = .round
    /// Stacked above the window, not below it. The stroke sits entirely outside
    /// the window's bounds, so drawing above covers none of its content - and
    /// it removes a failure that is very visible while resizing: a border below
    /// its window gets swept over by the window's own edge as it grows, because
    /// we necessarily learn about the new size a frame late. Below-stacking is
    /// still available and is what JankyBorders does, where it matters less
    /// because its stroke is centred on the edge rather than outside it.
    var order: BorderOrder = .above
    var hidpi: Bool = true
    var glowRadius: CGFloat = 10.0
    var blacklist: Set<String> = []
    var whitelist: Set<String> = []
    var enabled: Bool = true
    /// Diagnostic: fill the entire border window opaque instead of stroking a
    /// ring, to separate "nothing is drawn" from "the ring is in the wrong place".
    var debugFill: Bool = false
    /// Draw the border as four thin strips rather than one window-sized one.
    /// Strips cost ~15x less memory but need four drawing operations per
    /// redraw instead of one, and a drawing operation on a window backing store
    /// costs a flat ~200us however few pixels it touches. Turning this off
    /// trades a lot of memory for a slightly cheaper resize.
    var strips: Bool = true

    /// How far the border frame extends beyond the window. The stroke sits in
    /// the band from `outset - width` to `outset`, flush against the window
    /// edge; `padding` is the leftover margin a glow can bleed into.
    var outset: CGFloat { width + padding }

    func allows(app: String) -> Bool {
        if !whitelist.isEmpty && !whitelist.contains(app) { return false }
        if blacklist.contains(app) { return false }
        return true
    }
}

/// What a settings change requires of already-live borders.
struct UpdateMask: OptionSet {
    let rawValue: Int
    static let none      = UpdateMask([])
    static let active    = UpdateMask(rawValue: 1 << 0)
    static let inactive  = UpdateMask(rawValue: 1 << 1)
    static let geometry  = UpdateMask(rawValue: 1 << 2)   // width/padding/style
    static let recreate  = UpdateMask(rawValue: 1 << 3)   // hidpi/order/lists
    static var all: UpdateMask { [.active, .inactive, .geometry] }
}

enum SettingsParser {
    static func parseColorStyle(_ value: String) -> ColorStyle? {
        if value.hasPrefix("glow(") && value.hasSuffix(")") {
            let inner = String(value.dropFirst(5).dropLast())
            guard let c = parseHex(inner) else { return nil }
            return .glow(c)
        }
        if value.hasPrefix("gradient(") && value.hasSuffix(")") {
            let inner = String(value.dropFirst(9).dropLast())
            var direction = GradientDirection.topLeftToBottomRight
            var c1: UInt32?, c2: UInt32?
            for part in inner.split(separator: ",") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "top_left":     c1 = parseHex(kv[1]); direction = .topLeftToBottomRight
                case "bottom_right": c2 = parseHex(kv[1])
                case "top_right":    c1 = parseHex(kv[1]); direction = .topRightToBottomLeft
                case "bottom_left":  c2 = parseHex(kv[1])
                default: break
                }
            }
            guard let a = c1, let b = c2 else { return nil }
            return .gradient(a, b, direction)
        }
        guard let c = parseHex(value) else { return nil }
        return .solid(c)
    }

    static func parseHex(_ s: String) -> UInt32? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") || t.hasPrefix("0X") { t = String(t.dropFirst(2)) }
        return UInt32(t, radix: 16)
    }

    static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "on", "true", "yes", "1": return true
        case "off", "false", "no", "0": return false
        default: return nil
        }
    }

    static func parseList(_ s: String) -> Set<String> {
        let stripped = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return Set(stripped.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Applies `args` to `settings`, returning what live borders must redo.
    @discardableResult
    static func apply(_ args: [String], to settings: inout Settings) -> UpdateMask {
        var mask = UpdateMask.none
        for arg in args {
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0], value = parts[1]
            switch key {
            case "active_color":
                if let c = parseColorStyle(value), c != settings.active { settings.active = c; mask.insert(.active) }
            case "inactive_color":
                if let c = parseColorStyle(value), c != settings.inactive { settings.inactive = c; mask.insert(.inactive) }
            case "color":
                if let c = parseColorStyle(value) {
                    settings.active = c; settings.inactive = c; mask.formUnion(.all)
                }
            case "width":
                if let w = Double(value), CGFloat(w) != settings.width { settings.width = CGFloat(w); mask.insert(.geometry) }
            case "padding":
                if let p = Double(value), CGFloat(p) != settings.padding { settings.padding = CGFloat(p); mask.insert(.geometry) }
            case "glow_radius":
                if let r = Double(value) { settings.glowRadius = CGFloat(r); mask.formUnion(.all) }
            case "style":
                let s: BorderStyle? = value == "round" ? .round
                    : value == "square" ? .square
                    : (value == "uniform" || value == "u") ? .uniform : nil
                if let s, s != settings.style { settings.style = s; mask.insert(.geometry) }
            case "order":
                let o: BorderOrder? = value == "above" ? .above : value == "below" ? .below : nil
                if let o, o != settings.order { settings.order = o; mask.insert(.recreate) }
            case "hidpi":
                if let b = parseBool(value), b != settings.hidpi { settings.hidpi = b; mask.insert(.recreate) }
            case "strips":
                if let b = parseBool(value), b != settings.strips { settings.strips = b; mask.insert(.recreate) }
            case "debug_fill":
                if let b = parseBool(value), b != settings.debugFill { settings.debugFill = b; mask.formUnion(.all) }
            case "enabled":
                if let b = parseBool(value), b != settings.enabled { settings.enabled = b; mask.insert(.recreate) }
            case "blacklist":
                let l = parseList(value)
                if l != settings.blacklist { settings.blacklist = l; mask.insert(.recreate) }
            case "whitelist":
                let l = parseList(value)
                if l != settings.whitelist { settings.whitelist = l; mask.insert(.recreate) }
            default:
                FileHandle.standardError.write("snappyborders: unknown option '\(key)'\n".data(using: .utf8)!)
            }
        }
        return mask
    }
}
