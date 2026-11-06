// RinKeys — xem toàn bộ phím tắt của app đang dùng trên Mac.
// Đọc thanh menu của app đang dùng qua Accessibility, hiện thành bảng kính chia theo nhóm,
// bấm một dòng để chạy lệnh, tìm theo tên hoặc theo phím, lưu bảng thành ảnh.
// App không có tiếng Việt thì dịch tên lệnh bằng bộ dịch của macOS (macOS 15+), Final Cut Pro có bảng thuật ngữ riêng.
// Final Cut Pro, Photoshop và CapCut có thêm nhóm phím không nằm trên thanh menu.

import AppKit
import SwiftUI
import Combine
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers
import CryptoKit
import Security
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

// MARK: - Ngôn ngữ (theo ngôn ngữ của máy)

func L(_ vi: String, _ en: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("vi") ? vi : en
}

// MARK: - Nhật ký chẩn đoán (chỉ trong bộ nhớ)

@MainActor
enum Diag {
    static var lines: [String] = []
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func log(_ s: String) {
        lines.append(fmt.string(from: Date()) + " " + s)
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
    }
}

// MARK: - Phím tắt

struct KeyCombo: Hashable, Sendable {
    var control = false
    var option = false
    var shift = false
    var command = false
    var key: String

    var symbols: [String] {
        var a: [String] = []
        if control { a.append("⌃") }
        if option { a.append("⌥") }
        if shift { a.append("⇧") }
        if command { a.append("⌘") }
        a.append(key)
        return a
    }

    var text: String { symbols.joined() }
}

final class ShortcutItem: Identifiable, @unchecked Sendable {
    let id: Int
    let title: String
    let path: [String]
    let combo: KeyCombo
    let enabled: Bool
    /// Mục menu thật (bấm là chạy lệnh). nil với phím mặc định do RinKeys tự thêm.
    let element: AXUIElement?
    /// Mã phím để gửi phím mặc định (Final Cut Pro, Photoshop).
    let keyCode: Int?
    let isDefault: Bool

    init(id: Int, title: String, path: [String], combo: KeyCombo, enabled: Bool,
         element: AXUIElement?, keyCode: Int? = nil, isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.path = path
        self.combo = combo
        self.enabled = enabled
        self.element = element
        self.keyCode = keyCode
        self.isDefault = isDefault
    }
}

struct ShortcutGroup: Identifiable, Sendable {
    var id: String
    var title: String
    var items: [ShortcutItem]
    var continued = false
    /// Ghi chú dưới nhóm (nhóm phím mặc định).
    var note: String?
}

// MARK: - Đọc thanh menu qua Accessibility

enum MenuReader {
    struct Result: Sendable {
        var groups: [ShortcutGroup] = []
        var status: Status = .ok
        var visited = 0
        var seconds = 0.0
    }

    enum Status: Sendable { case ok, noPermission, notResponding, noMenuBar }

    private static let attrs: [String] = [
        kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute,
        "AXMenuItemCmdChar", "AXMenuItemCmdVirtualKey", "AXMenuItemCmdGlyph", "AXMenuItemCmdModifiers",
        kAXChildrenAttribute,
    ]

    private struct Values {
        var role: String?
        var title: String?
        var enabled: Bool
        var cmdChar: String?
        var virtualKey: Int?
        var glyph: Int?
        var modifiers: Int
        var children: [AXUIElement]
    }

    private static func clean(_ v: AnyObject) -> AnyObject? {
        if CFGetTypeID(v) == AXValueGetTypeID() {
            let ax = v as! AXValue
            if AXValueGetType(ax) == .axError { return nil }
        }
        return v
    }

    private static func elements(_ v: AnyObject?) -> [AXUIElement] {
        guard let v, let arr = v as? [AnyObject] else { return [] }
        return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    private static func values(_ el: AXUIElement) -> Values? {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, [], &out) == .success,
              let raw = out as? [AnyObject], raw.count == attrs.count else { return nil }
        let v = raw.map { clean($0) }
        return Values(
            role: v[0] as? String,
            title: v[1] as? String,
            enabled: (v[2] as? NSNumber)?.boolValue ?? true,
            cmdChar: v[3] as? String,
            virtualKey: (v[4] as? NSNumber)?.intValue,
            glyph: (v[5] as? NSNumber)?.intValue,
            modifiers: (v[6] as? NSNumber)?.intValue ?? 0,
            children: elements(v[7]))
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &out) == .success else { return [] }
        return elements(out)
    }

    static func read(pid: pid_t) -> Result {
        let start = Date()
        var result = Result()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)
        var barRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barRef)
        switch err {
        case .success: break
        case .apiDisabled: result.status = .noPermission; return result
        case .cannotComplete: result.status = .notResponding; return result
        default: result.status = .noMenuBar; return result
        }
        guard let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { result.status = .noMenuBar; return result }
        let bar = barRef as! AXUIElement
        var counter = 0
        for (index, top) in children(bar).enumerated() {
            if index == 0 { continue } // menu Apple
            guard let v = values(top) else { continue }
            let title = v.title ?? ""
            var items: [ShortcutItem] = []
            for menu in v.children {
                walk(menu, path: [], depth: 0, into: &items, counter: &counter)
            }
            if !items.isEmpty {
                result.groups.append(ShortcutGroup(id: "m\(index)-\(title)", title: title.isEmpty ? "?" : title, items: items))
            }
            if counter > 5000 { break }
        }
        result.visited = counter
        result.seconds = Date().timeIntervalSince(start)
        return result
    }

    private static func walk(_ menu: AXUIElement, path: [String], depth: Int,
                             into out: inout [ShortcutItem], counter: inout Int) {
        guard depth < 5 else { return }
        for item in children(menu) {
            counter += 1
            if counter > 5000 { return }
            guard let v = values(item), v.role == (kAXMenuItemRole as String) else { continue }
            let title = (v.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { continue }
            if let sub = v.children.first {
                walk(sub, path: path + [title], depth: depth + 1, into: &out, counter: &counter)
                continue
            }
            guard let key = KeyNames.key(char: v.cmdChar, glyph: v.glyph, virtualKey: v.virtualKey) else { continue }
            let m = v.modifiers
            let combo = KeyCombo(control: m & 4 != 0, option: m & 2 != 0, shift: m & 1 != 0, command: m & 8 == 0, key: key)
            out.append(ShortcutItem(id: counter, title: title, path: path, combo: combo, enabled: v.enabled, element: item))
        }
    }
}

enum KeyNames {
    /// Ký hiệu phím đặc biệt theo mã glyph của menu macOS (Menus.h).
    private static let glyphs: [Int: String] = [
        0x02: "⇥", 0x03: "⇤", 0x04: "⌤", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩", 0x0C: "↩", 0x0D: "↩",
        0x10: "↓", 0x17: "⌫", 0x18: "←", 0x19: "↑", 0x1A: "→", 0x1B: "⎋", 0x1C: "⌧",
        0x62: "⇞", 0x63: "⇪", 0x64: "←", 0x65: "→", 0x66: "↖", 0x67: "Help", 0x68: "↑", 0x69: "↘",
        0x6A: "↓", 0x6B: "⇟", 0x8C: "⏏",
        0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5", 0x74: "F6", 0x75: "F7", 0x76: "F8",
        0x77: "F9", 0x78: "F10", 0x79: "F11", 0x7A: "F12", 0x87: "F13", 0x88: "F14", 0x89: "F15",
        0x8F: "F16", 0x90: "F17", 0x91: "F18", 0x92: "F19",
    ]

    private static let virtualKeys: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func key(char: String?, glyph: Int?, virtualKey: Int?) -> String? {
        if let g = glyph, g > 0, let name = glyphs[g] { return name }
        if let c = char, let s = name(forChar: c) { return s }
        if let vk = virtualKey, let name = virtualKeys[vk] { return name }
        return nil
    }

    private static func name(forChar c: String) -> String? {
        guard let scalar = c.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x0D, 0x0A: return "↩"
        case 0x03: return "⌤"
        case 0x09: return "⇥"
        case 0x20: return "Space"
        case 0x1B: return "⎋"
        case 0x08, 0x7F: return "⌫"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF727: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0x00...0x1F: return nil
        default:
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t.uppercased()
        }
    }
}

// MARK: - Phím mặc định không nằm trên thanh menu

enum DefaultKeys {
    private static func item(_ id: Int, _ title: String, _ key: String, _ code: Int, shift: Bool = false) -> ShortcutItem {
        ShortcutItem(id: 900_000 + id, title: title, path: [],
                     combo: KeyCombo(shift: shift, command: false, key: key),
                     enabled: true, element: nil, keyCode: code, isDefault: true)
    }

    /// Một dòng phím CapCut. mods: chuỗi gồm các ký tự c (⌘), o (⌥), s (⇧), t (⌃). code nil = thao tác kèm chuột, chỉ để xem.
    private static func cc(_ id: Int, _ vi: String, _ en: String, _ mods: String, _ key: String, _ code: Int?) -> ShortcutItem {
        ShortcutItem(id: 910_000 + id, title: L(vi, en), path: [],
                     combo: KeyCombo(control: mods.contains("t"), option: mods.contains("o"), shift: mods.contains("s"),
                                     command: mods.contains("c"), key: key),
                     enabled: true, element: nil, keyCode: code, isDefault: true)
    }

    /// Phím CapCut lấy từ bảng Phím tắt trong CapCut (bộ "Phím tắt 3", Phước quay video 06/11/2026).
    /// Thanh menu của CapCut chỉ hiện phím của bộ mặc định, nên với CapCut danh sách này được ưu tiên hơn menu.
    private static func capCut() -> [ShortcutGroup] {
        let scroll = L("Cuộn", "Scroll")
        let note = L("Lấy từ bảng Phím tắt của CapCut, bộ \"Phím tắt 3\". Bạn dùng bộ khác hoặc đã đổi phím thì có thể khác.",
                     "From CapCut's Keyboard Shortcuts panel, preset 3. Other presets or your own changes may differ.")
        let timeline = [
            cc(1, "Tách", "Split", "c", "K", kVK_ANSI_K),
            cc(2, "Tách tất cả", "Split all", "cs", "K", kVK_ANSI_K),
            cc(3, "Chọn chế độ", "Select mode", "", "V", kVK_ANSI_V),
            cc(4, "Chế độ tách", "Split mode", "", "C", kVK_ANSI_C),
            cc(5, "Chuyển sang khung hình bên trái", "Move to left frame", "s", "A", kVK_ANSI_A),
            cc(6, "Chuyển sang khung hình bên phải", "Move to right frame", "", "A", kVK_ANSI_A),
            cc(7, "Hút vào đoạn chính", "Snap to main track", "s", "⌫", kVK_Delete),
            cc(8, "Tự động gắn", "Auto snapping", "", "S", kVK_ANSI_S),
            cc(9, "Nút bật/tắt liên kết", "Toggle linkage", "c", "L", kVK_ANSI_L),
            cc(10, "Nút bật/tắt trục xem trước", "Toggle preview axis", "s", "P", kVK_ANSI_P),
            cc(11, "Phóng to", "Zoom in", "", "+", kVK_ANSI_Equal),
            cc(12, "Thu nhỏ", "Zoom out", "", "−", kVK_ANSI_Minus),
            cc(13, "Phóng to/Thu nhỏ", "Zoom in/out", "c", scroll, nil),
            cc(14, "Lên/Xuống", "Up/Down", "", scroll, nil),
            cc(15, "Trái/phải", "Left/Right", "o", scroll, nil),
            cc(16, "Kích hoạt/vô hiệu hoá clip", "Enable/disable clip", "s", "E", kVK_ANSI_E),
            cc(17, "Trích xuất/Khôi phục âm thanh", "Extract/restore audio", "os", "L", kVK_ANSI_L),
            cc(18, "Thêm điểm đánh dấu", "Add marker", "", "M", kVK_ANSI_M),
            cc(19, "Thêm điểm đánh dấu bằng màu mới", "Add marker with new color", "o", "M", kVK_ANSI_M),
            cc(20, "Chuyển đến điểm đánh dấu tiếp theo", "Next marker", "s", "M", kVK_ANSI_M),
            cc(21, "Chuyển về điểm đánh dấu trước", "Previous marker", "os", "M", kVK_ANSI_M),
            cc(22, "Khung trước", "Previous frame", "", "←", kVK_LeftArrow),
            cc(23, "Khung sau", "Next frame", "", "→", kVK_RightArrow),
            cc(24, "Chuyển đến khung hình đầu tiên", "Go to first frame", "", "Home", kVK_Home),
            cc(25, "Chuyển đến khung hình cuối cùng", "Go to last frame", "", "End", kVK_End),
            cc(26, "Điểm cắt cuối cùng", "Previous cut point", "", "↑", kVK_UpArrow),
            cc(27, "Điểm cắt tiếp theo", "Next cut point", "", "↓", kVK_DownArrow),
            cc(28, "Điểm vào", "Mark in", "", "I", kVK_ANSI_I),
            cc(29, "Điểm ra", "Mark out", "", "O", kVK_ANSI_O),
            cc(30, "Chọn theo clip", "Select by clip", "s", "X", kVK_ANSI_X),
            cc(31, "Bỏ chọn", "Deselect", "o", "X", kVK_ANSI_X),
            cc(32, "Nhóm", "Group", "c", "G", kVK_ANSI_G),
            cc(33, "Bỏ nhóm", "Ungroup", "cs", "G", kVK_ANSI_G),
            cc(34, "Hiển thị bảng tốc độ", "Show speed panel", "c", "R", kVK_ANSI_R),
            cc(35, "Tốc độ uốn cong", "Speed curve", "s", "B", kVK_ANSI_B),
            cc(36, "Tạo clip ghép (dự án con)", "Create compound clip", "o", "G", kVK_ANSI_G),
            cc(37, "Hoàn tác clip ghép (dự án con)", "Undo compound clip", "os", "G", kVK_ANSI_G),
            cc(38, "Âm lượng +0.1dB", "Volume +0.1dB", "c", ".", kVK_ANSI_Period),
            cc(39, "Âm lượng -0.1dB", "Volume -0.1dB", "c", ",", kVK_ANSI_Comma),
            cc(40, "Vào", "Enter", "s", "↩", kVK_Return),
            cc(41, "Tua lại nhanh", "Rewind", "", "J", kVK_ANSI_J),
            cc(42, "Dừng tua nhanh", "Stop", "", "K", kVK_ANSI_K),
            cc(43, "Tua đi nhanh", "Fast forward", "", "L", kVK_ANSI_L),
            cc(44, "Xóa bên trái", "Delete left", "", "Q", kVK_ANSI_Q),
            cc(45, "Xóa bên phải", "Delete right", "", "W", kVK_ANSI_W),
            cc(46, "Hiện/ẩn bảng điều khiển khung hình chính", "Show/hide keyframe panel", "o", "K", kVK_ANSI_K),
            cc(47, "Thêm khung hình chính", "Add keyframe", "so", "K", kVK_ANSI_K),
            cc(48, "Chuyển tiếp nhiều khung", "Forward multiple frames", "s", "←", kVK_LeftArrow),
            cc(49, "Quay lại nhiều khung", "Back multiple frames", "s", "→", kVK_RightArrow),
            cc(50, "Thu phóng để vừa với dòng thời gian", "Zoom to fit timeline", "s", "Z", kVK_ANSI_Z),
            cc(51, "Ghi màn hình", "Screen recording", "co", "P", kVK_ANSI_P),
        ]
        let player = [
            cc(60, "Phát/Tạm dừng", "Play/Pause", "", "Space", kVK_Space),
            cc(61, "Vào/Thoát chế độ toàn màn hình", "Enter/exit full screen", "", "~", kVK_ANSI_Grave),
            cc(62, "Phóng to trình phát", "Zoom in player", "os", "+", kVK_ANSI_Equal),
            cc(63, "Thu nhỏ trình phát", "Zoom out player", "os", "−", kVK_ANSI_Minus),
            cc(64, "Thu phóng để vừa với trình phát", "Zoom to fit player", "os", "Z", kVK_ANSI_Z),
            cc(65, "Hiện/ẩn thước kẻ", "Show/hide rulers", "co", "R", kVK_ANSI_R),
            cc(66, "Hiện/ẩn đường tham chiếu", "Show/hide guides", "c", ";", kVK_ANSI_Semicolon),
        ]
        let basic = [
            cc(70, "Bản sao", "Copy", "c", "C", kVK_ANSI_C),
            cc(71, "Cắt", "Cut", "c", "X", kVK_ANSI_X),
            cc(72, "Dán", "Paste", "c", "V", kVK_ANSI_V),
            cc(73, "Sao chép thuộc tính", "Copy attributes", "co", "C", kVK_ANSI_C),
            cc(74, "Dán thuộc tính", "Paste attributes", "co", "V", kVK_ANSI_V),
            cc(75, "Xóa", "Delete", "", "⌫", kVK_Delete),
            cc(76, "Làm lại", "Undo", "c", "Z", kVK_ANSI_Z),
            cc(77, "Đặt lại", "Redo", "cs", "Z", kVK_ANSI_Z),
            cc(78, "Nhập phương tiện", "Import media", "c", "I", kVK_ANSI_I),
            cc(79, "Xuất", "Export", "c", "M", kVK_ANSI_M),
            cc(80, "Dự án mới", "New project", "c", "N", kVK_ANSI_N),
            cc(81, "Chuyển đổi bảng điều khiển tài liệu", "Toggle media panel", "", "⇥", kVK_Tab),
            cc(82, "Nói để nhập", "Voice typing", "c", "D", kVK_ANSI_D),
            cc(83, "Quay lại phần chỉnh sửa", "Back to editing", "co", "Q", kVK_ANSI_Q),
            cc(84, "Thoát", "Quit", "c", "Q", kVK_ANSI_Q),
            cc(85, "Toàn màn hình", "Full screen", "c", "F", kVK_ANSI_F),
            cc(86, "Thoát chế độ toàn màn hình", "Exit full screen", "", "⎋", kVK_Escape),
        ]
        return [
            ShortcutGroup(id: "capcut-timeline", title: L("Dòng thời gian", "Timeline"), items: timeline, note: note),
            ShortcutGroup(id: "capcut-player", title: L("Trình phát", "Player"), items: player),
            ShortcutGroup(id: "capcut-basic", title: L("Cơ bản", "Basic"), items: basic),
        ]
    }

    /// Ghép menu thật với phím mặc định của app (nếu có).
    static func merge(bundleID: String, menu: [ShortcutGroup]) -> [ShortcutGroup] {
        if bundleID.hasPrefix("com.lemon.lv") {
            // CapCut: bảng phím tắt đúng hơn menu, bỏ dòng menu trùng tên lệnh; nhóm của CapCut đặt lên trước.
            let extra = capCut()
            let names = Set(extra.flatMap { $0.items.map { $0.title.lowercased() } })
            let rest = menu.compactMap { g -> ShortcutGroup? in
                var g2 = g
                g2.items = g.items.filter { !names.contains($0.title.lowercased()) }
                return g2.items.isEmpty ? nil : g2
            }
            return extra + rest
        }
        return menu + groups(for: bundleID, existing: menu)
    }

    static func groups(for bundleID: String, existing: [ShortcutGroup]) -> [ShortcutGroup] {
        let used = Set(existing.flatMap { $0.items.map { $0.combo.text } })
        var list: [ShortcutItem] = []
        var title = ""
        var note = ""
        if bundleID.hasPrefix("com.apple.FinalCut") {
            title = L("Phát lại và di chuyển (phím mặc định)", "Playback & navigation (default keys)")
            note = L("Không nằm trên thanh menu. Đây là phím mặc định của Final Cut Pro, nếu bạn đã đổi trong Command Editor thì có thể khác. Nhấn J hoặc L nhiều lần để tua nhanh hơn.",
                     "Not in the menu bar. These are Final Cut Pro's default keys; they may differ if you changed them in the Command Editor. Press J or L repeatedly to go faster.")
            list = [
                item(1, "Play Reverse", "J", kVK_ANSI_J),
                item(2, "Stop", "K", kVK_ANSI_K),
                item(3, "Play Forward", "L", kVK_ANSI_L),
                item(4, "Previous Frame", "←", kVK_LeftArrow),
                item(5, "Next Frame", "→", kVK_RightArrow),
                item(6, "Previous Edit", "↑", kVK_UpArrow),
                item(7, "Next Edit", "↓", kVK_DownArrow),
            ]
        } else if bundleID.hasPrefix("com.adobe.Photoshop") {
            title = L("Công cụ (phím mặc định)", "Tools (default keys)")
            note = L("Không nằm trên thanh menu. Đây là phím mặc định của Photoshop, nếu bạn đã đổi trong Edit → Keyboard Shortcuts thì có thể khác. Giữ ⇧ và nhấn chữ cái để đổi qua công cụ cùng nhóm.",
                     "Not in the menu bar. These are Photoshop's default keys; they may differ if you changed them in Edit → Keyboard Shortcuts. Hold ⇧ and press the letter to cycle tools in a group.")
            list = [
                item(10, "Move Tool", "V", kVK_ANSI_V),
                item(11, "Marquee Tools", "M", kVK_ANSI_M),
                item(12, "Lasso Tools", "L", kVK_ANSI_L),
                item(13, "Object / Quick Selection, Magic Wand", "W", kVK_ANSI_W),
                item(14, "Crop Tool", "C", kVK_ANSI_C),
                item(15, "Eyedropper Tool", "I", kVK_ANSI_I),
                item(16, "Healing Brush Tools", "J", kVK_ANSI_J),
                item(17, "Brush Tool", "B", kVK_ANSI_B),
                item(18, "Clone Stamp Tool", "S", kVK_ANSI_S),
                item(19, "History Brush Tool", "Y", kVK_ANSI_Y),
                item(20, "Eraser Tool", "E", kVK_ANSI_E),
                item(21, "Gradient / Paint Bucket", "G", kVK_ANSI_G),
                item(22, "Dodge / Burn Tool", "O", kVK_ANSI_O),
                item(23, "Pen Tool", "P", kVK_ANSI_P),
                item(24, "Type Tool", "T", kVK_ANSI_T),
                item(25, "Path / Direct Selection", "A", kVK_ANSI_A),
                item(26, "Shape Tools", "U", kVK_ANSI_U),
                item(27, "Hand Tool", "H", kVK_ANSI_H),
                item(28, "Rotate View Tool", "R", kVK_ANSI_R),
                item(29, "Zoom Tool", "Z", kVK_ANSI_Z),
                item(30, "Default Colors", "D", kVK_ANSI_D),
                item(31, "Swap Colors", "X", kVK_ANSI_X),
                item(32, "Quick Mask Mode", "Q", kVK_ANSI_Q),
                item(33, "Screen Mode", "F", kVK_ANSI_F),
                item(34, "Decrease Brush Size", "[", kVK_ANSI_LeftBracket),
                item(35, "Increase Brush Size", "]", kVK_ANSI_RightBracket),
                item(36, "Decrease Brush Hardness", "[", kVK_ANSI_LeftBracket, shift: true),
                item(37, "Increase Brush Hardness", "]", kVK_ANSI_RightBracket, shift: true),
            ]
        }
        list.removeAll { used.contains($0.combo.text) }
        guard !list.isEmpty else { return [] }
        return [ShortcutGroup(id: "default-\(bundleID)", title: title, items: list, note: note)]
    }
}

enum KeySender {
    static func send(code: Int, combo: KeyCombo) {
        let src = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []
        if combo.shift { flags.insert(.maskShift) }
        if combo.option { flags.insert(.maskAlternate) }
        if combo.control { flags.insert(.maskControl) }
        if combo.command { flags.insert(.maskCommand) }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Cài đặt

enum UpdateFrequency: String, CaseIterable {
    case daily, weekly, off
    var title: String {
        switch self {
        case .daily: return L("Mỗi ngày", "Daily")
        case .weekly: return L("Mỗi tuần", "Weekly")
        case .off: return L("Tắt", "Off")
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .daily: return 20 * 3600
        case .weekly: return 6.5 * 24 * 3600
        case .off: return nil
        }
    }
}

enum UpdateMode: String, CaseIterable {
    case auto, ask, notify
    var shortTitle: String {
        switch self {
        case .auto: return L("Tự cập nhật", "Auto")
        case .ask: return L("Hỏi trước", "Ask")
        case .notify: return L("Chỉ báo", "Notify")
        }
    }
}

enum Prefs {
    private static let d = UserDefaults.standard
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }

    static var doubleCommand: Bool { bool("doubleCommand", true) }
    static var showInDock: Bool { bool("showInDock", false) }
    static var autoTranslate: Bool { bool("autoTranslate", true) }

    static var updateFrequency: UpdateFrequency {
        UpdateFrequency(rawValue: d.string(forKey: "updateFrequency") ?? "") ?? .daily
    }
    static var updateMode: UpdateMode {
        UpdateMode(rawValue: d.string(forKey: "updateMode") ?? "") ?? .ask
    }
    static var lastUpdateCheck: Date? {
        get { d.object(forKey: "lastUpdateCheck") as? Date }
        set { d.set(newValue, forKey: "lastUpdateCheck") }
    }
    static var justUpdatedFrom: String? {
        get { d.string(forKey: "justUpdatedFrom") }
        set { d.set(newValue, forKey: "justUpdatedFrom") }
    }
}

// MARK: - Thông tin app

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    static let repoURL = URL(string: "https://github.com/PhuocRin/RinKeys")!
    static let apiLatestRelease = URL(string: "https://api.github.com/repos/PhuocRin/RinKeys/releases/latest")!
    static let webURL = URL(string: "https://phuocrin.com/rinkeys/")!
    static let youtubeURL = URL(string: "https://youtube.com/@phuocrin")!
    static let tiktokURL = URL(string: "https://www.tiktok.com/@phuocrinrin")!
    static let facebookURL = URL(string: "https://www.facebook.com/phuocrinrin")!
    static let email = "phuocrinrin@gmail.com"

    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Thông tin gửi kèm khi báo lỗi. Không có gì cá nhân.
    @MainActor
    static var diagnostics: String {
        "RinKeys \(version) (\(build)) · \(macOS) · \(chip)\n"
            + L("Quyền Trợ năng", "Accessibility") + ": " + (AXIsProcessTrusted() ? L("có", "yes") : L("chưa có", "no"))
            + " · " + L("Ký bằng chứng chỉ", "Certificate signed") + ": " + (UpdateSecurity.currentIsAdHoc ? L("không", "no") : L("có", "yes"))
    }
}

enum Permission {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static func request() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(settingsURL)
    }
}

// MARK: - Dịch tên lệnh (bộ dịch có sẵn của macOS, chạy trên máy)

struct TranslateRequest: Equatable {
    let id = UUID()
    let source: String
    let target: String
}

enum Translations {
    /// Dịch sang ngôn ngữ của máy (máy để tiếng Việt thì dịch sang tiếng Việt).
    static var targetCode: String {
        Locale(identifier: Locale.preferredLanguages.first ?? "en").language.languageCode?.identifier ?? "en"
    }

    static var available: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RinKeys", isDirectory: true)
            .appendingPathComponent("translations-\(targetCode).json")
    }

    static func load() -> [String: String] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let d = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return d
    }

    static func save(_ d: [String: String]) {
        guard let url = fileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: url, options: .atomic) }
    }
}

/// Thuật ngữ giữ nguyên tiếng Anh khi dịch (cách người dựng Việt vẫn gọi), theo từng app.
enum Glossary {
    struct Terms {
        let id: String
        let keep: [String]
    }

    static func forApp(_ bundleID: String) -> Terms? {
        if bundleID.hasPrefix("com.apple.FinalCut") {
            return Terms(id: "fcp1", keep: [
                "Compound Clips", "Compound Clip", "Adjustment Clip", "Keyword Collection", "Lower Third",
                "Freeze Frame", "Color Board", "Auditions", "Audition", "Storylines", "Storyline", "Multicam",
                "Generators", "Generator", "Inspector", "Timeline", "Skimmer", "Skimming", "Playhead",
                "Keyframes", "Keyframe", "Retime", "Snapping", "Blade", "Ripple", "Roll", "Slip", "Slide",
                "Proxy", "B-roll",
            ])
        }
        return nil
    }

    /// Thay thuật ngữ bằng mã tạm (RK0, RK1…) trước khi dịch để bộ dịch không đụng vào.
    /// Trả nil khi cả chuỗi chỉ là một thuật ngữ (khỏi dịch).
    static func protect(_ text: String, _ set: Terms) -> (String, [String])? {
        var out = text
        var terms: [String] = []
        for term in set.keep {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            while let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
                  let r = Range(m.range, in: out) {
                let token = "RK\(terms.count)"
                terms.append(String(out[r]))
                out.replaceSubrange(r, with: token)
            }
        }
        if !terms.isEmpty, out.replacingOccurrences(of: "RK\\d+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty {
            return nil
        }
        return (out, terms)
    }

    /// Trả thuật ngữ về chỗ cũ. nil nếu bộ dịch làm mất mã tạm.
    static func restore(_ translated: String, _ terms: [String]) -> String? {
        var out = translated
        for (i, term) in terms.enumerated().reversed() {
            guard let re = try? NSRegularExpression(pattern: "R\\s?K\\s?\(i)(?!\\d)", options: [.caseInsensitive]),
                  let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
                  let r = Range(m.range, in: out) else { return nil }
            out.replaceSubrange(r, with: term)
        }
        return out
    }
}

// MARK: - Dữ liệu bảng phím tắt

@MainActor
final class KeysModel: ObservableObject {
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var bundleID = ""
    @Published var groups: [ShortcutGroup] = []
    @Published var loading = false
    @Published var status: MenuReader.Status = .ok
    @Published var query = ""
    @Published var pinned = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var size = CGSize(width: 1000, height: 640)
    @Published var hasTarget = false

    // Dịch tên lệnh
    @Published var needsTranslation = false
    @Published var translateOn = false
    @Published var translating = false
    @Published var translateNote: String?
    @Published var translateRequest: TranslateRequest?
    @Published private(set) var translations: [String: String] = Translations.load()
    private var sourceLanguage = "en"
    private struct Pending {
        let key: String
        let text: String
        let source: String
        let terms: [String]
    }
    private var pending: [Pending] = []
    /// Khoá đang chờ dịch, để mở lại bảng giữa chừng không gửi trùng.
    private var inFlight = Swift.Set<String>()

    /// Khoá lưu bản dịch: app có bảng thuật ngữ riêng thì bản dịch cũng tách riêng.
    private func key(_ s: String) -> String {
        if let g = Glossary.forApp(bundleID) { return g.id + "\u{1F}" + s }
        return s
    }

    private(set) var target: NSRunningApplication?
    private var cache: [pid_t: [ShortcutGroup]] = [:]
    private var token = UUID()

    func setTarget(_ app: NSRunningApplication?) {
        target = app
        hasTarget = app != nil
    }

    func load() {
        guard let app = target, !app.isTerminated else {
            appName = ""
            appIcon = nil
            groups = []
            hasTarget = false
            return
        }
        let pid = app.processIdentifier
        let bid = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? bid
        if bundleID != bid {
            query = ""
            needsTranslation = false
            translateOn = false
            translateNote = nil
        }
        appName = name
        appIcon = app.icon
        bundleID = bid
        groups = cache[pid] ?? []
        status = .ok
        if !groups.isEmpty { checkLanguage() }
        guard trusted else { return }
        loading = true
        let t = UUID()
        token = t
        DispatchQueue.global(qos: .userInitiated).async {
            let r = MenuReader.read(pid: pid)
            let all = DefaultKeys.merge(bundleID: bid, menu: r.groups)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.token == t else { return }
                    self.loading = false
                    self.status = r.status
                    self.groups = all
                    if r.status == .ok { self.cache[pid] = all }
                    self.checkLanguage()
                    let n = all.reduce(0) { $0 + $1.items.count }
                    Diag.log("\(name): \(n) " + "shortcuts, \(r.visited) items, " + String(format: "%.2fs", r.seconds) + " (\(r.status))")
                }
            }
        }
    }

    func forget(pid: pid_t) { cache[pid] = nil }

    /// Đoán ngôn ngữ của menu: khác ngôn ngữ của máy (vd Final Cut Pro, Photoshop chỉ có tiếng Anh) thì cho dịch.
    private func checkLanguage() {
        let sample = groups.filter { $0.items.first?.isDefault != true }
            .flatMap { $0.items.prefix(25).map(\.title) }
            .prefix(300).joined(separator: ". ")
        guard Translations.available, !sample.isEmpty else { needsTranslation = false; translateOn = false; return }
        let r = NLLanguageRecognizer()
        r.processString(sample)
        let lang = r.dominantLanguage?.rawValue ?? "en"
        sourceLanguage = lang
        let target = Translations.targetCode
        needsTranslation = !lang.hasPrefix(target)
        let manual = UserDefaults.standard.object(forKey: "translate." + bundleID) as? Bool
        translateOn = needsTranslation && (manual ?? Prefs.autoTranslate)
        if translateOn { requestTranslation() }
    }

    func toggleTranslate() {
        translateOn.toggle()
        UserDefaults.standard.set(translateOn, forKey: "translate." + bundleID)
        translateNote = nil
        if translateOn { requestTranslation() }
    }

    func requestTranslation() {
        var texts = Set<String>()
        for g in groups {
            let isDefault = g.items.first?.isDefault == true
            if !isDefault { texts.insert(g.title) }
            for i in g.items {
                texts.insert(i.title)
                for p in i.path { texts.insert(p) }
            }
        }
        let missing = texts.filter { !$0.isEmpty && translations[key($0)] == nil && !inFlight.contains(key($0)) }
        guard !missing.isEmpty else { return }
        let glossary = Glossary.forApp(bundleID)
        var list: [Pending] = []
        var direct: [String: String] = [:]
        for text in missing.sorted() {
            if let glossary {
                if let r = Glossary.protect(text, glossary) {
                    list.append(Pending(key: key(text), text: text, source: r.0, terms: r.1))
                } else {
                    direct[key(text)] = text // cả chuỗi là thuật ngữ: giữ nguyên
                }
            } else {
                list.append(Pending(key: key(text), text: text, source: text, terms: []))
            }
        }
        if !direct.isEmpty { translations.merge(direct) { $1 } }
        guard !list.isEmpty else { Translations.save(translations); return }
        pending += list
        inFlight.formUnion(list.map(\.key))
        translating = true
        translateRequest = TranslateRequest(source: sourceLanguage, target: Translations.targetCode)
    }

    #if canImport(Translation)
    @available(macOS 15.0, *)
    func runTranslation(_ session: TranslationSession) async {
        let texts = pending
        pending = []
        guard !texts.isEmpty else { translating = false; return }
        do {
            var i = 0
            while i < texts.count {
                let chunk = Array(texts[i..<min(i + 150, texts.count)])
                let reqs = chunk.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element.source, clientIdentifier: String($0.offset))
                }
                let res = try await session.translations(from: reqs)
                var t = translations
                for r in res {
                    guard let id = r.clientIdentifier, let k = Int(id), k < chunk.count else { continue }
                    let p = chunk[k]
                    if p.terms.isEmpty {
                        t[p.key] = r.targetText
                    } else {
                        // Bộ dịch làm mất mã tạm thì giữ tên gốc tiếng Anh, khỏi dịch lại mỗi lần mở.
                        t[p.key] = Glossary.restore(r.targetText, p.terms) ?? p.text
                    }
                }
                translations = t
                i += 150
            }
            Translations.save(translations)
            Diag.log("translated \(texts.count) (\(sourceLanguage)→\(Translations.targetCode))")
        } catch is CancellationError {
            // Có yêu cầu dịch mới chen vào: trả phần chưa dịch về hàng chờ cho lượt sau.
            pending = texts.filter { translations[$0.key] == nil } + pending
            Translations.save(translations)
            return
        } catch {
            translateNote = L("Chưa dịch được. Vào Cài đặt hệ thống → Cài đặt chung → Ngôn ngữ & Vùng → Ngôn ngữ dịch thuật… → tải Tiếng Việt, rồi bấm lại nút Dịch.",
                              "Couldn't translate. Open System Settings → General → Language & Region → Translation Languages…, download your language, then press Translate again.")
            Diag.log("translate error: \(error.localizedDescription)")
        }
        inFlight.subtract(texts.map(\.key))
        translating = !pending.isEmpty
    }
    #endif

    /// Bản dịch của một chữ trên menu (chỉ khi đang bật dịch).
    func tr(_ s: String) -> String? { translateOn ? translations[key(s)] : nil }

    /// Bản dịch của mọi chữ trong các nhóm (dùng khi xuất ảnh).
    func resolvedTranslations(_ groups: [ShortcutGroup]) -> [String: String] {
        var d: [String: String] = [:]
        for g in groups {
            if let t = tr(g.title) { d[g.title] = t }
            for i in g.items {
                if let t = tr(i.title) { d[i.title] = t }
                for p in i.path { if let t = tr(p) { d[p] = t } }
            }
        }
        return d
    }

    func visibleGroups(showDisabled: Bool) -> [ShortcutGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return groups.compactMap { g in
            var g2 = g
            g2.items = g.items.filter { item in
                guard showDisabled || item.enabled else { return false }
                if q.isEmpty { return true }
                if item.title.range(of: q, options: opts) != nil { return true }
                if let t = tr(item.title), t.range(of: q, options: opts) != nil { return true }
                if g.title.range(of: q, options: opts) != nil { return true }
                if let t = tr(g.title), t.range(of: q, options: opts) != nil { return true }
                if item.path.joined(separator: " ").range(of: q, options: opts) != nil { return true }
                if item.path.contains(where: { tr($0)?.range(of: q, options: opts) != nil }) { return true }
                return item.combo.text.range(of: q, options: .caseInsensitive) != nil
            }
            return g2.items.isEmpty ? nil : g2
        }
    }

    /// Chia nhóm vào các cột theo thứ tự đọc (trên xuống, trái qua), cắt nhóm dài sang cột sau.
    nonisolated static func columns(_ groups: [ShortcutGroup], count: Int, rowWeight: Double = 1) -> [[ShortcutGroup]] {
        let n = max(1, count)
        var cols = Array(repeating: [ShortcutGroup](), count: n)
        let header = 2.6
        let total = groups.reduce(0.0) { $0 + Double($1.items.count) * rowWeight + header }
        let target = max(6, total / Double(n))
        var queue = groups
        var c = 0
        var load = 0.0
        var i = 0
        while i < queue.count {
            let g = queue[i]
            let w = Double(g.items.count) * rowWeight + header
            // Cột cuối, còn chỗ, hoặc cột đang trống mà nhóm quá ngắn để cắt: đặt cả nhóm vào cột này
            // (không bỏ trống cột giữa khi app có ít phím).
            let room = Int((target - load - header) / rowWeight)
            let canSplit = room >= 4 && g.items.count - room >= 3
            if c == n - 1 || load + w <= target + 1.5 || (load == 0 && !canSplit) {
                cols[c].append(g)
                load += w
                i += 1
                continue
            }
            if canSplit {
                var first = g
                first.items = Array(g.items.prefix(room))
                first.id = g.id + "#\(c)"
                var rest = g
                rest.items = Array(g.items.dropFirst(room))
                rest.continued = true
                rest.note = g.note
                first.note = nil
                rest.id = g.id + "#\(c + 1)"
                cols[c].append(first)
                queue[i] = rest
            }
            c += 1
            load = 0
        }
        return cols
    }

    func run(_ item: ShortcutItem) {
        guard item.enabled, let app = target, !app.isTerminated else { return }
        AppDelegate.shared?.panel.hide(restoreFocus: false)
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                if let el = item.element {
                    let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
                    Diag.log("run \(item.title): \(err.rawValue)")
                } else if let code = item.keyCode {
                    KeySender.send(code: code, combo: item.combo)
                    Diag.log("key \(item.combo.text)")
                }
            }
        }
    }

    /// Enter trong ô tìm: chạy kết quả đầu tiên còn dùng được.
    func runFirst() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let first = visibleGroups(showDisabled: false).first?.items.first { run(first) }
    }
}

// MARK: - Bảng kính

final class KeysPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PanelController {
    let model: KeysModel
    private var panel: KeysPanel?
    private var resignObserver: NSObjectProtocol?
    private(set) var isPeek = false
    private(set) var lastHide = Date.distantPast
    private var peekMouse = NSPoint.zero

    init(model: KeysModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func makePanel() -> KeysPanel {
        let p = KeysPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                          styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                          backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.animationBehavior = .utilityWindow
        p.onCancel = { [weak self] in self?.hide(restoreFocus: true) }
        let host = FirstMouseHostingView(rootView: KeysView(model: model))
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPeek, !self.model.pinned else { return }
                self.hide(restoreFocus: false)
            }
        }
        return p
    }

    func show(peek: Bool) {
        let p = panel ?? makePanel()
        panel = p
        if p.isVisible && !isPeek && peek { return }
        isPeek = peek
        let mouse = NSEvent.mouseLocation
        peekMouse = mouse
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(max(vf.width * 0.84, 560), 1240)
        let h = min(max(vf.height * 0.80, 420), 800)
        model.size = CGSize(width: w, height: h)
        let frame = NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2 + vf.height * 0.03, width: w, height: h)
        p.setFrame(frame, display: true)
        p.level = peek ? .statusBar : .floating
        model.load()
        if peek {
            p.orderFrontRegardless()
        } else {
            p.makeKeyAndOrderFront(nil)
            p.orderFrontRegardless()
        }
        p.invalidateShadow()
    }

    /// Thả ⌘ khi đang xem nhanh thì ẩn. Chỉ giữ bảng lại khi đang ghim, hoặc người dùng đã di chuột vào bảng
    /// (bảng to, hiện ngay dưới con trỏ, nên chuột nằm sẵn trên bảng mà không di thì vẫn ẩn).
    func endPeek() {
        guard isPeek, let p = panel, p.isVisible else { isPeek = false; return }
        let now = NSEvent.mouseLocation
        let moved = hypot(now.x - peekMouse.x, now.y - peekMouse.y) > 40
        if model.pinned || (moved && NSMouseInRect(now, p.frame, false)) {
            isPeek = false
            p.level = .floating
            p.makeKeyAndOrderFront(nil)
        } else {
            hide(restoreFocus: false)
        }
    }

    func hide(restoreFocus: Bool) {
        guard let p = panel, p.isVisible else { isPeek = false; return }
        isPeek = false
        lastHide = Date()
        p.orderOut(nil)
        // Mở từ icon Dock thì RinKeys đang là app chính: trả lại app đang xem.
        if restoreFocus, NSApp.isActive, let t = model.target, !t.isTerminated { t.activate(options: []) }
    }

    func toggle() {
        if isVisible && !isPeek { hide(restoreFocus: true); return }
        // Bấm icon thanh menu khi bảng vừa tự ẩn vì mất focus (do chính cú bấm đó) thì không mở lại.
        if Date().timeIntervalSince(lastHide) < 0.3 { return }
        show(peek: false)
    }

    func targetChanged() {
        if isVisible { model.load() }
    }
}

// MARK: - Giao diện dùng chung

extension View {
    func panelStyle(width: CGFloat = 340) -> some View {
        self.padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 26).frame(width: width)
    }

    func softCard(cornerRadius: CGFloat = 18) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.primary.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    func glassButton(prominent: Bool = false) -> some View { modifier(GlassButton(prominent: prominent)) }

    func noteText() -> some View {
        self.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    func bigGlass(cornerRadius: CGFloat) -> some View { modifier(BigGlass(cornerRadius: cornerRadius)) }
}

struct GlassButton: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Nền kính cho bảng phím tắt: Liquid Glass trên macOS 26, kính mờ trên bản cũ hơn.
struct BigGlass: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            fallback(content, shape)
        }
        #else
        fallback(content, shape)
        #endif
    }

    private func fallback(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .background(VisualEffect().clipShape(shape))
            .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
    }
}

struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct AppIconView: View {
    var size: CGFloat = 88
    @ViewBuilder
    var body: some View {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
                .shadow(color: Color.black.opacity(0.25), radius: 14, y: 6)
        }
    }
}

struct KeyCapsView: View {
    let combo: KeyCombo
    var size: CGFloat = 11.5
    var light = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(combo.symbols.enumerated()), id: \.offset) { _, s in
                Text(verbatim: s)
                    .font(.system(size: s.count > 1 ? size - 1.5 : size, weight: .semibold, design: .rounded))
                    .foregroundStyle(light ? Color.white : Color.primary.opacity(0.85))
                    .padding(.horizontal, s.count > 1 ? 6 : 0)
                    .frame(minWidth: size + 9, minHeight: size + 9)
                    .background {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(light ? Color.white.opacity(0.22) : Color.primary.opacity(0.08))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .strokeBorder(light ? Color.white.opacity(0.35) : Color.primary.opacity(0.10), lineWidth: 0.8)
                    }
            }
        }
        .fixedSize()
    }
}

func itemLabel(_ item: ShortcutItem, secondary: Color) -> AttributedString {
    var out = AttributedString()
    if !item.path.isEmpty {
        var p = AttributedString(item.path.joined(separator: " › ") + " › ")
        p.swiftUI.foregroundColor = secondary
        out += p
    }
    out += AttributedString(item.title)
    return out
}

/// Tên lệnh đã dịch (cả đường dẫn menu con), nil khi chưa có bản dịch.
@MainActor
func translatedLabel(_ item: ShortcutItem, model: KeysModel) -> String? {
    guard let t = model.tr(item.title) else { return nil }
    let full = (item.path.map { model.tr($0) ?? $0 } + [t]).joined(separator: " › ")
    // Giống hệt tên gốc (vd cả dòng là thuật ngữ giữ nguyên) thì khỏi hiện hai dòng.
    return full == (item.path + [item.title]).joined(separator: " › ") ? nil : full
}

struct ShortcutRow: View {
    let item: ShortcutItem
    @ObservedObject var model: KeysModel
    @State private var hover = false

    var body: some View {
        Button {
            model.run(item)
        } label: {
            HStack(spacing: 8) {
                if let vi = translatedLabel(item, model: model) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: vi).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                        Text(itemLabel(item, secondary: .secondary)).font(.system(size: 10.5))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    Text(itemLabel(item, secondary: .secondary))
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                KeyCapsView(combo: item.combo)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hover && item.enabled ? 0.09 : 0))
            }
        }
        .buttonStyle(.plain)
        .opacity(item.enabled ? 1 : 0.42)
        .onHover { hover = $0 }
        .help(item.enabled ? (item.path + [item.title]).joined(separator: " › ")
              : L("Lệnh này đang mờ trong menu nên chưa dùng được lúc này", "This command is greyed out in the menu right now"))
    }
}

@MainActor
func groupTitle(_ g: ShortcutGroup, model: KeysModel) -> String {
    var t = g.title
    if let vi = model.tr(g.title), vi.lowercased() != g.title.lowercased() { t = vi + " (" + g.title + ")" }
    return t + (g.continued ? L(" (tiếp)", " (cont.)") : "")
}

struct GroupView: View {
    let group: ShortcutGroup
    @ObservedObject var model: KeysModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(groupTitle(group, model: model))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .textCase(.uppercase)
                    .lineLimit(1)
                if group.items.first?.isDefault == true {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .bold)).foregroundStyle(.purple)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.08))
            VStack(alignment: .leading, spacing: 1) {
                ForEach(group.items) { item in ShortcutRow(item: item, model: model) }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            if let note = group.note {
                Text(note).noteText().padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .background(shape.fill(Color.primary.opacity(0.035)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.13 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct KeysView: View {
    @ObservedObject var model: KeysModel
    @AppStorage("showDisabled") private var showDisabled = true
    @AppStorage("doubleCommand") private var doubleCommand = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        let groups = model.visibleGroups(showDisabled: showDisabled)
        let count = groups.reduce(0) { $0 + $1.items.count }
        VStack(spacing: 0) {
            header(count: count, groups: groups)
            Divider().opacity(0.5).padding(.horizontal, 20)
            content(groups)
            footer
        }
        .frame(width: model.size.width, height: model.size.height)
        .bigGlass(cornerRadius: 28)
        .modifier(TranslateHost(model: model))
        .onAppear { searchFocused = true }
    }

    private func header(count: Int, groups: [ShortcutGroup]) -> some View {
        HStack(spacing: 12) {
            if let icon = model.appIcon {
                Image(nsImage: icon).resizable().frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.appName.isEmpty ? "RinKeys" : model.appName)
                    .font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(L("\(count) phím tắt", "\(count) shortcuts")).font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.loading { ProgressView().controlSize(.mini) }
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField(L("Tìm lệnh hoặc phím…", "Search commands or keys…"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { model.runFirst() }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: 250)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))

            IconButton(symbol: "square.and.arrow.down", help: L("Lưu bảng này thành ảnh", "Save this sheet as an image")) {
                Exporter.export(model: model, groups: groups)
            }
            .disabled(groups.isEmpty)
            if model.needsTranslation {
                ZStack {
                    IconButton(symbol: "translate",
                               help: model.translateOn ? L("Đang dịch tên lệnh. Bấm để xem tên gốc", "Showing translated names. Click for the originals")
                                                       : L("Dịch tên lệnh sang tiếng Việt", "Translate command names"),
                               tint: model.translateOn ? .accentColor : .primary) {
                        model.toggleTranslate()
                    }
                    if model.translating { ProgressView().controlSize(.mini).offset(x: 12, y: 12) }
                }
            }
            IconButton(symbol: model.pinned ? "pin.fill" : "pin",
                       help: L("Ghim: giữ bảng luôn mở, tự đổi theo app bạn chuyển sang", "Pin: keep the sheet open and follow the app you switch to"),
                       tint: model.pinned ? .accentColor : .primary) {
                model.pinned.toggle()
            }
            IconButton(symbol: "heart.fill", help: L("Ủng hộ tác giả", "Support the author"), tint: .pink) {
                AppDelegate.shared?.showSupport()
            }
            Menu {
                Button(L("Cài đặt…", "Settings…")) { AppDelegate.shared?.showSettings() }
                Button(L("Mẹo dùng", "Tips")) { AppDelegate.shared?.showWelcome() }
                Button(L("Kiểm tra cập nhật…", "Check for Updates…")) { AppDelegate.shared?.showUpdate() }
                Divider()
                Button(L("Giới thiệu RinKeys", "About RinKeys")) { AppDelegate.shared?.showAbout() }
                Button(L("Báo lỗi…", "Report a Bug…")) { AppDelegate.shared?.showBug() }
                Divider()
                Button(L("Thoát RinKeys", "Quit RinKeys")) { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.primary.opacity(0.07)))
            .fixedSize()
            IconButton(symbol: "xmark", help: L("Đóng (Esc)", "Close (Esc)")) {
                AppDelegate.shared?.panel.hide(restoreFocus: true)
            }
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
    }

    @ViewBuilder
    private func content(_ groups: [ShortcutGroup]) -> some View {
        if !model.trusted {
            message(symbol: "lock.shield", title: L("RinKeys cần quyền Trợ năng", "RinKeys needs Accessibility access"),
                    text: L("Quyền này để RinKeys đọc thanh menu của app đang dùng và chạy lệnh khi bạn bấm.",
                            "It lets RinKeys read the current app's menu bar and run commands when you click them."),
                    button: L("Cấp quyền", "Grant access")) { AppDelegate.shared?.showWelcome() }
        } else if !model.hasTarget {
            message(symbol: "macwindow", title: L("Chưa có app nào đang mở", "No app in front"),
                    text: L("Mở một app rồi bấm lại icon RinKeys trên thanh menu.", "Open an app, then click the RinKeys icon again."))
        } else if groups.isEmpty && model.loading {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
        } else if groups.isEmpty {
            if !model.query.isEmpty {
                message(symbol: "magnifyingglass", title: L("Không có phím tắt nào khớp", "No matching shortcuts"),
                        text: L("Thử gõ tên lệnh khác, hoặc gõ phím như ⌘K.", "Try another command name, or type keys like ⌘K."))
            } else if model.status == .notResponding {
                message(symbol: "hourglass", title: L("\(model.appName) chưa trả lời", "\(model.appName) isn't responding"),
                        text: L("App này đang bận. Đợi vài giây rồi mở lại bảng.", "The app is busy. Wait a few seconds and open the sheet again."))
            } else {
                message(symbol: "keyboard", title: L("App này không có phím tắt trên thanh menu", "This app has no shortcuts in its menu bar"),
                        text: L("Một số app vẽ menu riêng nên macOS không cho đọc.", "Some apps draw their own menus, which macOS can't read."))
            }
        } else {
            let colCount = max(1, min(5, Int((model.size.width - 44 + 20) / 300)))
            let colWidth = (model.size.width - 44 - CGFloat(colCount - 1) * 20) / CGFloat(colCount)
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(Array(KeysModel.columns(groups, count: colCount, rowWeight: model.translateOn ? 1.5 : 1).enumerated()), id: \.offset) { _, col in
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(col) { g in GroupView(group: g, model: model) }
                        }
                        .frame(width: colWidth, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func message(symbol: String, title: String, text: String, button: String? = nil,
                         action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 17, weight: .bold, design: .rounded))
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let button, let action {
                Button(button, action: action).glassButton(prominent: true).controlSize(.large).padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let note = model.translateNote {
                Label(note, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
            } else {
                Text(L("Bấm một dòng để chạy lệnh · Enter chạy kết quả đầu tiên · Esc để đóng",
                       "Click a row to run it · Enter runs the first result · Esc to close"))
            }
            Spacer()
            if doubleCommand {
                Text(L("Nhấn ⌘ hai lần rồi giữ để xem nhanh", "Double-press and hold ⌘ to peek"))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 12)
    }
}

// MARK: - Chạy bộ dịch (cần macOS 15)

struct TranslateHost: ViewModifier {
    @ObservedObject var model: KeysModel

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            content.modifier(TranslateTask(model: model))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
struct TranslateTask: ViewModifier {
    @ObservedObject var model: KeysModel
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(config) { session in
                await model.runTranslation(session)
            }
            .onChange(of: model.translateRequest) { _, req in
                guard let req else { return }
                let source = Locale.Language(identifier: req.source)
                let target = Locale.Language(identifier: req.target)
                if config?.source == source && config?.target == target {
                    config?.invalidate()
                } else {
                    config = TranslationSession.Configuration(source: source, target: target)
                }
            }
    }
}
#endif

// MARK: - Xuất ảnh

struct ExportSheet: View {
    let appName: String
    let icon: NSImage?
    let groups: [ShortcutGroup]
    let total: Int
    /// Bản dịch tên lệnh (nil = không dịch).
    var translations: [String: String]? = nil

    private func tr(_ s: String) -> String? { translations?[s] }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 18) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 76, height: 76) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Phím tắt \(appName)", "\(appName) shortcuts"))
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                    Text(L("\(total) phím tắt", "\(total) shortcuts"))
                        .font(.system(size: 20, weight: .medium, design: .rounded)).opacity(0.8)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                ForEach(Array(KeysModel.columns(groups, count: 3, rowWeight: translations == nil ? 1 : 1.5).enumerated()), id: \.offset) { _, col in
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(col) { g in card(g) }
                    }
                    .frame(width: 368, alignment: .topLeading)
                }
            }
            HStack {
                Spacer()
                Text(L("Tạo bằng RinKeys · phuocrin.com", "Made with RinKeys · phuocrin.com"))
                    .font(.system(size: 16, weight: .semibold, design: .rounded)).opacity(0.75)
            }
        }
        .foregroundStyle(Color.white)
        .padding(48)
        .frame(width: 1240, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 1.0), Color(red: 0.48, green: 0.36, blue: 1.0),
                                        Color(red: 0.69, green: 0.36, blue: 1.0)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color.white.opacity(0.32), .clear], center: .init(x: 0.15, y: 0.05),
                               startRadius: 0, endRadius: 700)
                RadialGradient(colors: [Color(red: 0.23, green: 0.12, blue: 0.66).opacity(0.35), .clear],
                               center: .init(x: 0.9, y: 0.95), startRadius: 0, endRadius: 800)
            }
        }
    }

    private func cardTitle(_ g: ShortcutGroup) -> String {
        var t = g.title
        if let vi = tr(g.title), vi.lowercased() != g.title.lowercased() { t = vi + " (" + g.title + ")" }
        return t + (g.continued ? L(" (tiếp)", " (cont.)") : "")
    }

    private func card(_ g: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(cardTitle(g))
                .font(.system(size: 15, weight: .heavy, design: .rounded)).textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(Color.white.opacity(0.16))
                .padding(.horizontal, -18).padding(.top, -18).padding(.bottom, 4)
            ForEach(g.items) { item in
                HStack(spacing: 8) {
                    if let vi = tr(item.title),
                       (item.path.map { tr($0) ?? $0 } + [vi]) != item.path + [item.title] {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: (item.path.map { tr($0) ?? $0 } + [vi]).joined(separator: " › "))
                                .font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text(itemLabel(item, secondary: Color.white.opacity(0.65)))
                                .font(.system(size: 11.5, weight: .medium)).opacity(0.7).lineLimit(1).truncationMode(.middle)
                        }
                    } else {
                        Text(itemLabel(item, secondary: Color.white.opacity(0.65)))
                            .font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    KeyCapsView(combo: item.combo, size: 13, light: true)
                }
            }
            if g.items.first?.isDefault == true {
                Text(L("Phím mặc định, không nằm trên thanh menu", "Default keys, not in the menu bar"))
                    .font(.system(size: 12, weight: .medium)).opacity(0.7).padding(.top, 2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.16))
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.45), lineWidth: 1.2)
        }
    }
}

@MainActor
enum Exporter {
    static func export(model: KeysModel, groups: [ShortcutGroup]) {
        let total = groups.reduce(0) { $0 + $1.items.count }
        let sheet = ExportSheet(appName: model.appName, icon: model.appIcon, groups: groups, total: total,
                                translations: model.translateOn ? model.resolvedTranslations(groups) : nil)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { Diag.log("export: render failed"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        if !model.pinned { AppDelegate.shared?.panel.hide(restoreFocus: false) }
        let save = NSSavePanel()
        save.allowedContentTypes = [.png]
        save.nameFieldStringValue = L("Phím tắt \(model.appName).png", "\(model.appName) shortcuts.png")
        save.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        save.level = .modalPanel
        NSApp.activate()
        save.begin { resp in
            MainActor.assumeIsolated {
                guard resp == .OK, let url = save.url else { return }
                do {
                    try png.write(to: url)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    Diag.log("export: \(cg.width)x\(cg.height)")
                } catch {
                    Diag.log("export failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Nhấn ⌘ hai lần rồi giữ

@MainActor
final class CommandTap {
    var onPeekStart: (() -> Void)?
    var onPeekEnd: (() -> Void)?
    private var monitors: [Any] = []
    private var down = false
    private var downAt = Date.distantPast
    private var lastTapUp = Date.distantPast
    private var armed = false
    private var peeking = false
    private var holdWork: DispatchWorkItem?

    func start() {
        stop()
        guard Prefs.doubleCommand, AXIsProcessTrusted() else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            let flags = e.modifierFlags
            MainActor.assumeIsolated { self?.handle(flags) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            let flags = e.modifierFlags
            MainActor.assumeIsolated { self?.handle(flags) }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.keyPressed() }
        }) { monitors.append(m) }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        holdWork?.cancel()
        down = false
        armed = false
        if peeking { peeking = false; onPeekEnd?() }
    }

    private func reset() {
        holdWork?.cancel()
        armed = false
        lastTapUp = .distantPast
    }

    private func keyPressed() {
        // Đang giữ ⌘ mà bấm phím khác (vd ⌘C) thì không phải cử chỉ xem nhanh.
        if peeking {
            peeking = false
            onPeekEnd?()
        }
        reset()
    }

    private func handle(_ raw: NSEvent.ModifierFlags) {
        let f = raw.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        let now = Date()
        if f == .command && !down {
            down = true
            downAt = now
            if now.timeIntervalSince(lastTapUp) < 0.4 {
                armed = true
                holdWork?.cancel()
                let w = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.down, self.armed else { return }
                        self.peeking = true
                        self.onPeekStart?()
                    }
                }
                holdWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
            } else {
                armed = false
            }
        } else if !f.contains(.command) && down {
            down = false
            holdWork?.cancel()
            if peeking {
                peeking = false
                onPeekEnd?()
                reset()
            } else if !armed && now.timeIntervalSince(downAt) < 0.3 {
                lastTapUp = now
            } else {
                reset()
            }
        } else if down && f != .command && !peeking {
            reset()
        }
    }
}

// MARK: - Cửa sổ phụ

@MainActor
final class Panel {
    private var window: NSWindow?
    private var resignObserver: NSObjectProtocol?
    private let content: () -> AnyView

    init(_ content: @escaping () -> AnyView) { self.content = content }

    /// attention = app tự mở (lần đầu, có bản mới, vừa cập nhật): app trên thanh menu không được tự giành
    /// quyền lên trước, nên cho cửa sổ nổi trên cùng tới khi người dùng bấm vào rồi chuyển đi nơi khác.
    func show(attention: Bool = false) {
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = .preferredContentSize
        if let w = window {
            w.contentViewController = controller
        } else {
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.collectionBehavior.insert(.moveToActiveSpace)
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak w] _ in
                MainActor.assumeIsolated { w?.level = .normal }
            }
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible { w.center() }
        w.level = attention ? .floating : .normal
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    func close() { window?.orderOut(nil) }
}

// MARK: - Chào mừng, cấp quyền, mẹo dùng

struct WelcomeView: View {
    @ObservedObject var model: KeysModel

    var body: some View {
        VStack(spacing: 14) {
            AppIconView(size: 80)
            Text(L("Chào mừng đến với RinKeys", "Welcome to RinKeys"))
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(L("Xem toàn bộ phím tắt của app bạn đang dùng, tìm nhanh và bấm để chạy lệnh.",
                   "See every shortcut of the app you're using, search them and click to run."))
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if model.trusted {
                Label(L("Đã có quyền Trợ năng", "Accessibility access granted"), systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 10) {
                    tip("menubar.rectangle", L("Bấm icon ⌘ trên thanh menu để xem phím tắt của app đang dùng. Chuột phải vào icon để mở cài đặt.",
                                               "Click the ⌘ icon in the menu bar to see the current app's shortcuts. Right-click it for settings."))
                    tip("command", L("Nhấn ⌘ hai lần rồi giữ để xem nhanh, thả ra là ẩn. Muốn giữ bảng lại thì di chuột vào bảng trước khi thả, hoặc bấm ghim. Nút ✕ hoặc Esc để đóng.",
                                     "Double-press and hold ⌘ to peek; release to hide. To keep it, move the mouse onto the sheet before releasing, or pin it. ✕ or Esc closes it."))
                    tip("translate", L("App không có tiếng Việt (Final Cut Pro, Photoshop…) thì tên lệnh được tự dịch, tên gốc nằm dòng dưới. Nút Dịch trên bảng để bật tắt.",
                                       "Apps not in your language (Final Cut Pro, Photoshop…) get translated command names, with the original below. Use the Translate button to switch."))
                    tip("magnifyingglass", L("Gõ để tìm theo tên lệnh hoặc theo phím. Enter chạy kết quả đầu tiên, bấm vào một dòng để chạy lệnh đó.",
                                             "Type to search by command or key. Enter runs the first result; click a row to run it."))
                    tip("pin", L("Ghim để bảng luôn mở, bảng tự đổi theo app bạn chuyển sang.",
                                 "Pin to keep the sheet open; it follows the app you switch to."))
                    tip("square.and.arrow.down", L("Lưu bảng thành ảnh để chia sẻ. Đang tìm thì ảnh chỉ có kết quả tìm.",
                                                   "Save the sheet as an image to share. While searching, the image only has the results."))
                    tip("sparkles", L("Final Cut Pro, Photoshop và CapCut có thêm nhóm phím không nằm trên thanh menu.",
                                      "Final Cut Pro, Photoshop and CapCut get an extra group of keys that aren't in the menu bar."))
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).softCard()
                Button {
                    AppDelegate.shared?.welcomePanel.close()
                    AppDelegate.shared?.tryNow()
                } label: {
                    Text(L("Thử ngay", "Try it")).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .glassButton(prominent: true).controlSize(.large)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L("Cấp quyền Trợ năng (Accessibility)", "Allow Accessibility access"), systemImage: "lock.shield.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(L("RinKeys cần quyền này để đọc thanh menu của app đang dùng và chạy lệnh khi bạn bấm. RinKeys chỉ để ý phím ⌘ để mở bảng xem nhanh, không ghi lại phím bạn gõ và không gửi gì ra ngoài.",
                           "RinKeys needs this to read the current app's menu bar and run commands you click. It only watches the ⌘ key to open the peek sheet; it doesn't record what you type or send anything anywhere."))
                        .noteText()
                    Text(L("Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Trợ năng → bật RinKeys. Trên macOS 27 mục này tên là Điều khiển thiết bị và truy cập dữ liệu.",
                           "System Settings → Privacy & Security → Accessibility → turn on RinKeys. On macOS 27 this section has a new name; look for RinKeys under Privacy & Security."))
                        .font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Button {
                        Permission.request()
                    } label: {
                        Label(L("Mở cài đặt Trợ năng", "Open Accessibility settings"), systemImage: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .glassButton(prominent: true).controlSize(.large)
                    Text(L("Đã bật mà vẫn báo chưa có quyền? Tắt RinKeys trong danh sách, bật lại, hoặc bấm dấu − để xoá rồi thêm lại.",
                           "Turned on but still not working? Toggle RinKeys off and on again, or remove it with − and add it back."))
                        .noteText()
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).softCard()
            }
        }
        .panelStyle(width: 420)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.purple).frame(width: 20)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Cài đặt (cửa sổ)

struct SettingsView: View {
    @AppStorage("doubleCommand") private var doubleCommand = true
    @AppStorage("showDisabled") private var showDisabled = true
    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("autoTranslate") private var autoTranslate = true
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 14) {
            AppIconView(size: 64)
            Text(L("Cài đặt RinKeys", "RinKeys Settings"))
                .font(.system(size: 22, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Cách mở bảng phím tắt", "How to open the sheet")).font(.system(size: 12, weight: .semibold))
                Toggle(L("Nhấn ⌘ hai lần rồi giữ để xem nhanh", "Double-press and hold ⌘ to peek"), isOn: $doubleCommand)
                    .onChange(of: doubleCommand) { _ in AppDelegate.shared?.applyPrefs() }
                Toggle(L("Hiện icon trên Dock (bấm icon để xem)", "Show in the Dock (click to open)"), isOn: $showInDock)
                    .onChange(of: showInDock) { _ in AppDelegate.shared?.applyPrefs() }
                Text(L("Bấm icon ⌘ trên thanh menu luôn mở được bảng.", "Clicking the ⌘ menu bar icon always opens the sheet."))
                    .noteText()
            }
            .toggleStyle(.switch)
            .font(.system(size: 13))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softCard(cornerRadius: 16)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(L("Hiện cả lệnh đang mờ trong menu", "Show greyed-out commands"), isOn: $showDisabled)
                Toggle(L("Tự dịch tên lệnh của app không có tiếng Việt", "Auto-translate apps not in your language"), isOn: $autoTranslate)
                    .disabled(!Translations.available)
                Text(Translations.available
                     ? L("Dùng bộ dịch có sẵn của macOS, dịch ngay trên máy. Mỗi app vẫn bật tắt riêng được bằng nút Dịch trên bảng.",
                         "Uses macOS's built-in on-device translator. You can still switch each app with the Translate button on the sheet.")
                     : L("Cần macOS 15 trở lên.", "Requires macOS 15 or later."))
                    .noteText()
                Toggle(L("Mở cùng máy", "Open at login"), isOn: $login)
                    .onChange(of: login) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            login = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            .toggleStyle(.switch)
            .font(.system(size: 13))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softCard(cornerRadius: 16)
        }
        .panelStyle(width: 380)
    }
}

// MARK: - Ủng hộ tác giả

enum Support {
    static let paypalURL = URL(string: "https://paypal.me/phuocrin")!
    static var qrImage: NSImage? { Bundle.main.image(forResource: "donate-qr") }
}

struct SupportView: View {
    private let qr = Support.qrImage

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "heart.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(.pink)
            Text(L("Ủng hộ tác giả", "Support the author")).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(qr != nil
                 ? L("RinKeys miễn phí. Nếu app giúp ích cho bạn, bạn có thể ủng hộ Phước Rin bằng 1 trong 2 cách bên dưới.",
                     "RinKeys is free. If it helps you, you can support Phước Rin in one of the two ways below.")
                 : L("RinKeys miễn phí. Nếu app giúp ích cho bạn, bạn có thể ủng hộ Phước Rin qua PayPal.",
                     "RinKeys is free. If it helps you, you can support Phước Rin via PayPal."))
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let qr {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L("Cách 1 · Chuyển khoản ngân hàng", "Option 1 · Bank transfer (Vietnam)"), systemImage: "building.columns.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(L("Dành cho bạn ở Việt Nam. Mở app ngân hàng bất kỳ, quét mã này.",
                           "For users in Vietnam. Open any banking app and scan this code.")).noteText()
                    Image(nsImage: qr).resizable().interpolation(.high).scaledToFit()
                        .frame(width: 176, height: 176).padding(10)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
                        .frame(maxWidth: .infinity).padding(.vertical, 2)
                    Text(L("App ngân hàng sẽ hiện tên chủ tài khoản, bạn kiểm tra đúng tên trước khi chuyển nha.",
                           "Your banking app will show the account holder's name. Please check it before sending.")).noteText()
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).softCard()
            }

            VStack(alignment: .leading, spacing: 10) {
                Label(qr != nil ? L("Cách 2 · PayPal", "Option 2 · PayPal") : "PayPal", systemImage: "globe")
                    .font(.system(size: 13, weight: .semibold))
                Text(L("Dành cho bạn ở nước ngoài hoặc có tài khoản PayPal.",
                       "For users outside Vietnam, or anyone with a PayPal account.")).noteText()
                Button {
                    NSWorkspace.shared.open(Support.paypalURL)
                } label: {
                    Label(L("Ủng hộ qua PayPal", "Support via PayPal"), systemImage: "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .glassButton(prominent: true).controlSize(.large)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).softCard()

            Text(L("Cảm ơn bạn đã dùng RinKeys 💙", "Thanks for using RinKeys 💙")).noteText()
        }
        .panelStyle(width: 360)
    }
}

// MARK: - Giới thiệu

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            AppIconView(size: 96)
            Text("RinKeys").font(.system(size: 26, weight: .bold, design: .rounded))
            Text(L("Phiên bản", "Version") + " \(AppInfo.version)")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(L("Xem toàn bộ phím tắt của app đang dùng trên Mac, tìm nhanh, bấm để chạy lệnh và lưu thành ảnh.",
                   "See every shortcut of the app you're using on your Mac, search them, click to run and save them as an image."))
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Text(L("Làm bởi Phước Rin", "Made by Phước Rin")).font(.system(size: 13, weight: .semibold))
                GlassGroup(spacing: 10) {
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow {
                            link("YouTube", "play.rectangle.fill", AppInfo.youtubeURL)
                            link("Facebook", "f.square.fill", AppInfo.facebookURL)
                        }
                        GridRow {
                            link("TikTok", "music.note", AppInfo.tiktokURL)
                            link("GitHub", "chevron.left.forwardslash.chevron.right", AppInfo.repoURL)
                        }
                        GridRow {
                            link("phuocrin.com", "globe", AppInfo.webURL).gridCellColumns(2)
                        }
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity).softCard().padding(.top, 6)

            Text(L("Miễn phí · Mã nguồn mở (MIT)", "Free · Open source (MIT)")).noteText().padding(.top, 2)
        }
        .panelStyle()
    }

    private func link(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
        }
        .glassButton().controlSize(.large)
    }
}

// MARK: - Báo lỗi

enum BugReport {
    @MainActor
    static var log: String { Diag.lines.isEmpty ? L("(chưa có nhật ký)", "(no log yet)") : Diag.lines.joined(separator: "\n") }

    @MainActor
    static var template: String {
        L("Mô tả lỗi:", "What happened:") + "\n\n\n"
            + L("App đang xem phím tắt:", "App you were viewing:") + "\n\n"
            + L("Các bước để gặp lỗi:", "Steps to reproduce:") + "\n1. \n2. \n\n"
            + "---\n" + AppInfo.diagnostics + "\n\n" + L("Nhật ký:", "Log:") + "\n" + log
    }

    @MainActor
    static var emailURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = AppInfo.email
        c.queryItems = [
            URLQueryItem(name: "subject", value: "[RinKeys \(AppInfo.version)] " + L("Báo lỗi", "Bug report")),
            URLQueryItem(name: "body", value: template),
        ]
        return c.url
    }

    @MainActor
    static var githubURL: URL? {
        var c = URLComponents(string: "https://github.com/PhuocRin/RinKeys/issues/new")
        c?.queryItems = [
            URLQueryItem(name: "title", value: L("Báo lỗi: ", "Bug: ")),
            URLQueryItem(name: "body", value: template),
        ]
        return c?.url
    }
}

struct BugReportView: View {
    private let info = AppInfo.diagnostics
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "ladybug.fill").font(.system(size: 32, weight: .semibold)).foregroundStyle(.orange)
            Text(L("Báo lỗi", "Report a bug")).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(L("Gặp lỗi hay có app nào đọc phím tắt chưa đúng? Bạn mô tả giúp mình nha, mình sẽ sửa ở bản sau.",
                   "Found a bug, or an app whose shortcuts look wrong? Tell me what happened and I'll fix it in the next version."))
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Thông tin gửi kèm", "Info included")).font(.system(size: 11, weight: .semibold))
                Text(info).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(L("Gồm phiên bản app, macOS, loại chip, quyền Trợ năng và nhật ký chẩn đoán gần nhất (tên app đã xem phím tắt, số phím đọc được, tên lệnh đã bấm). Không có thông tin cá nhân nào khác.",
                       "App version, macOS, chip, Accessibility permission and the recent diagnostic log (names of apps you viewed, shortcut counts, commands you ran). No other personal information."))
                    .noteText().padding(.top, 2)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).softCard(cornerRadius: 16)

            GlassGroup(spacing: 10) {
                VStack(spacing: 10) {
                    Button {
                        if let url = BugReport.emailURL { NSWorkspace.shared.open(url) }
                    } label: {
                        Label(L("Gửi qua email", "Send by email"), systemImage: "envelope.fill")
                            .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .glassButton(prominent: true).controlSize(.large)

                    HStack(spacing: 10) {
                        Button {
                            if let url = BugReport.githubURL { NSWorkspace.shared.open(url) }
                        } label: {
                            Text(L("Báo trên GitHub", "Report on GitHub")).frame(maxWidth: .infinity)
                        }
                        .glassButton()

                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(info + "\n\n" + BugReport.log, forType: .string)
                            copied = true
                        } label: {
                            Text(copied ? L("Đã sao chép", "Copied") : L("Sao chép kèm nhật ký", "Copy with log")).frame(maxWidth: .infinity)
                        }
                        .glassButton()
                    }
                    .font(.system(size: 12)).controlSize(.large)
                }
            }
        }
        .panelStyle()
    }
}

// MARK: - Cập nhật

/// Kiểm tra gói cập nhật có đúng do Phước Rin phát hành không. Khoá bí mật tương ứng nằm trong secret RINKEYS_SIGNING.
enum UpdateSecurity {
    static let publicKeyBase64 = "2f8eEqeyb0Re5AELC4dV+kx1TcN2BimvZ9pKJsaqSQ4="

    static func verify(_ data: Data, signature: Data) -> Bool {
        guard let raw = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    static func currentRequirement() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess else { return nil }
        return req
    }

    static var currentIsAdHoc: Bool {
        guard let req = currentRequirement() else { return true }
        var text: CFString?
        SecRequirementCopyString(req, [], &text)
        return (text as String?)?.contains("cdhash") ?? true
    }

    static let developerIDRequirement: SecRequirement? = {
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess else { return nil }
        return req
    }()

    static func newAppIsTrusted(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        if currentIsAdHoc { return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess }
        if let same = currentRequirement(), SecStaticCodeCheckValidity(code, flags, same) == errSecSuccess { return true }
        if let devID = developerIDRequirement, SecStaticCodeCheckValidity(code, flags, devID) == errSecSuccess { return true }
        return false
    }
}

enum UpdateError: Error {
    case missingPackage, badSignature, badApp, notWritable, failed(String)

    var message: String {
        switch self {
        case .missingPackage:
            return L("Bản này chưa có gói tự cập nhật. Bạn tải thủ công giúp mình nha.",
                     "This version has no auto-update package. Please download it manually.")
        case .badSignature:
            return L("Gói tải về không đúng chữ ký của Phước Rin nên RinKeys không cài.",
                     "The downloaded package isn't signed by Phước Rin, so RinKeys won't install it.")
        case .badApp:
            return L("App trong gói cập nhật không hợp lệ nên RinKeys không cài.",
                     "The app inside the update package isn't valid, so RinKeys won't install it.")
        case .notWritable:
            return L("RinKeys chỉ tự cập nhật được khi nằm trong thư mục Applications. Bạn kéo RinKeys vào Applications rồi thử lại nha.",
                     "RinKeys can only update itself from the Applications folder. Move it there and try again.")
        case .failed(let detail):
            return L("Có lỗi khi cập nhật: ", "Update failed: ") + detail
        }
    }
}

@MainActor
final class Updater: ObservableObject {
    struct Asset: Decodable, Equatable {
        let name: String
        let browser_download_url: URL
    }

    struct Release: Decodable, Equatable {
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]

        var version: String { tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")) }
        var notes: String { body ?? "" }
        var zipURL: URL? { assets.first { $0.name.hasSuffix(".zip") }?.browser_download_url }
        var sigURL: URL? { assets.first { $0.name.hasSuffix(".zip.sig") }?.browser_download_url }
        var canAutoInstall: Bool { zipURL != nil && sigURL != nil }
    }

    enum State: Equatable {
        case idle, checking, upToDate, failed
        case available(Release)
        case downloading(Release)
        case installing(Release)
        case installFailed(Release, String)
        case updated(from: String)
    }

    @Published private(set) var state: State = .idle
    var onChange: (@MainActor () -> Void)?
    var onFoundInBackground: (@MainActor (Release) -> Void)?
    var onInstallFailed: (@MainActor () -> Void)?

    var available: Release? {
        switch state {
        case let .available(r), let .installFailed(r, _): return r
        default: return nil
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func noteJustUpdated() -> Bool {
        guard let from = Prefs.justUpdatedFrom else { return false }
        Prefs.justUpdatedFrom = nil
        guard from != AppInfo.version else { return false }
        state = .updated(from: from)
        return true
    }

    func checkIfDue() {
        guard let interval = Prefs.updateFrequency.interval else { return }
        if let last = Prefs.lastUpdateCheck, Date().timeIntervalSince(last) < interval { return }
        check(background: true)
    }

    private var retryWork: DispatchWorkItem?
    private var retryCount = 0
    private var retryVersion = ""
    /// Bản mới tìm thấy gần nhất: lần hỏi lại bị lỗi mạng thì vẫn giữ để người dùng cài được.
    private var lastFound: Release?

    /// Hỏi lại sau 3 phút khi bản mới chưa có đủ gói cài (tối đa 6 lần cho mỗi bản).
    @discardableResult
    private func scheduleRetry(for version: String) -> Bool {
        if version != retryVersion { retryVersion = version; retryCount = 0 }
        guard retryCount < 6 else { return false }
        retryCount += 1
        retryWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check(background: true) }
        }
        retryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: w)
        return true
    }

    func check(background: Bool = false) {
        if isBusy { return }
        if !background { state = .checking }
        Task { await run(background: background) }
    }

    private func run(background: Bool) async {
        var req = URLRequest(url: AppInfo.apiLatestRelease, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("RinKeys/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let rel = try JSONDecoder().decode(Release.self, from: data)
            if Updater.isNewer(rel.version, than: AppInfo.version) {
                // Vừa phát hành thì GitHub đã coi là bản mới nhất nhưng gói cài ~5 phút sau mới gắn vào: chờ rồi hỏi lại.
                if !rel.canAutoInstall {
                    if scheduleRetry(for: rel.version), background { return }
                } else {
                    Prefs.lastUpdateCheck = Date()
                }
                lastFound = rel
                if background, let a = available, a.version == rel.version, a.canAutoInstall == rel.canAutoInstall { return }
                state = .available(rel)
                onChange?()
                if background { onFoundInBackground?(rel) }
                return
            }
            Prefs.lastUpdateCheck = Date()
            lastFound = nil
            if !background { state = .upToDate }
        } catch {
            if !background {
                if let r = lastFound { state = .available(r) } else { state = .failed }
            }
        }
        onChange?()
    }

    func install(_ rel: Release) {
        switch state {
        case .downloading, .installing: return
        default: break
        }
        Task { await performInstall(rel) }
    }

    private func performInstall(_ rel: Release) async {
        do {
            guard let zipURL = rel.zipURL, let sigURL = rel.sigURL else { throw UpdateError.missingPackage }
            state = .downloading(rel)
            onChange?()
            let (zipData, zipResp) = try await URLSession.shared.data(from: zipURL)
            let (sigData, sigResp) = try await URLSession.shared.data(from: sigURL)
            guard (zipResp as? HTTPURLResponse)?.statusCode == 200,
                  (sigResp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let sigText = String(decoding: sigData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let signature = Data(base64Encoded: sigText),
                  UpdateSecurity.verify(zipData, signature: signature) else { throw UpdateError.badSignature }
            state = .installing(rel)
            let newApp = try await Task.detached { () throws -> URL in try Installer.unpack(zipData) }.value
            guard Installer.bundleID(of: newApp) == Bundle.main.bundleIdentifier,
                  UpdateSecurity.newAppIsTrusted(newApp) else { throw UpdateError.badApp }
            try Installer.replaceAndRelaunch(with: newApp)
        } catch let e as UpdateError {
            state = .installFailed(rel, e.message)
        } catch {
            state = .installFailed(rel, UpdateError.failed(error.localizedDescription).message)
        }
        onChange?()
        onInstallFailed?()
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

enum Installer {
    static func unpack(_ zipData: Data) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("RinKeysUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("update.zip")
        try zipData.write(to: zip)
        let out = dir.appendingPathComponent("unpacked")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.failed("ditto \(p.terminationStatus)") }
        let app = out.appendingPathComponent("RinKeys.app")
        guard fm.fileExists(atPath: app.path) else { throw UpdateError.badApp }
        return app
    }

    static func bundleID(of app: URL) -> String? { Bundle(url: app)?.bundleIdentifier }

    @MainActor
    static func replaceAndRelaunch(with newApp: URL) throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard !current.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: parent.path),
              fm.isWritableFile(atPath: current.path) else { throw UpdateError.notWritable }
        Prefs.justUpdatedFrom = AppInfo.version
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$1.old"
        if /bin/mv "$1" "$1.old"; then
          if /bin/mv "$2" "$1"; then /bin/rm -rf "$1.old"; else /bin/mv "$1.old" "$1"; fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$1" 2>/dev/null
        /usr/bin/open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "rinkeys-update", current.path, newApp.path]
        do {
            try p.run()
        } catch {
            Prefs.justUpdatedFrom = nil
            throw UpdateError.failed(error.localizedDescription)
        }
        NSApp.terminate(nil)
    }
}

struct UpdateView: View {
    @ObservedObject var updater: Updater
    @AppStorage("updateFrequency") private var frequency: UpdateFrequency = .daily
    @AppStorage("updateMode") private var mode: UpdateMode = .ask

    var body: some View {
        VStack(spacing: 14) {
            AppIconView(size: 76)
            switch updater.state {
            case .idle:
                title(L("Kiểm tra cập nhật", "Check for updates"))
                Text("RinKeys \(AppInfo.version)").font(.system(size: 12)).foregroundStyle(.secondary)
                Button(L("Kiểm tra ngay", "Check now")) { updater.check() }.glassButton(prominent: true)
            case .checking:
                ProgressView().controlSize(.small)
                Text(L("Đang kiểm tra bản mới…", "Checking for updates…")).font(.system(size: 13)).foregroundStyle(.secondary)
            case .upToDate:
                title(L("Bạn đang dùng bản mới nhất", "You're on the latest version"))
                Text("RinKeys \(AppInfo.version)").font(.system(size: 12)).foregroundStyle(.secondary)
            case .failed:
                title(L("Chưa kiểm tra được", "Couldn't check"))
                Text(L("Bạn kiểm tra kết nối mạng rồi thử lại nha.", "Check your internet connection and try again."))
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L("Thử lại", "Try again")) { updater.check() }.glassButton().controlSize(.large)
            case let .available(rel):
                title(L("Có bản mới RinKeys \(rel.version)", "RinKeys \(rel.version) is available"))
                Text(L("Bạn đang dùng bản \(AppInfo.version)", "You're on version \(AppInfo.version)"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                notesBox(rel.notes)
                actions(for: rel)
            case let .downloading(rel):
                ProgressView().controlSize(.small)
                title(L("Đang tải RinKeys \(rel.version)…", "Downloading RinKeys \(rel.version)…"))
            case let .installing(rel):
                ProgressView().controlSize(.small)
                title(L("Đang cài RinKeys \(rel.version)…", "Installing RinKeys \(rel.version)…"))
                Text(L("RinKeys sẽ tự đóng và mở lại trong vài giây.", "RinKeys will quit and reopen in a few seconds."))
                    .noteText().multilineTextAlignment(.center)
            case let .installFailed(rel, reason):
                title(L("Chưa cập nhật được", "Couldn't update"))
                Text(reason).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                actions(for: rel)
            case let .updated(from):
                Image(systemName: "checkmark.seal.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.green)
                title(L("Đã cập nhật lên RinKeys \(AppInfo.version)", "Updated to RinKeys \(AppInfo.version)"))
                Text(L("Từ bản \(from)", "From version \(from)")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            settings
        }
        .panelStyle(width: 360)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 19, weight: .bold, design: .rounded))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func notesBox(_ notes: String) -> some View {
        if !notes.isEmpty {
            ScrollView {
                Text(notes).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 140).padding(14).softCard(cornerRadius: 16)
        }
    }

    @ViewBuilder
    private func actions(for rel: Updater.Release) -> some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 10) {
                if rel.canAutoInstall {
                    Button {
                        updater.install(rel)
                    } label: {
                        Label(L("Cập nhật ngay", "Update now"), systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .glassButton(prominent: true).controlSize(.large)
                    Button {
                        NSWorkspace.shared.open(rel.html_url)
                    } label: {
                        Text(L("Tải thủ công", "Download manually")).font(.system(size: 12)).frame(maxWidth: .infinity)
                    }
                    .glassButton().controlSize(.large)
                } else {
                    Button {
                        NSWorkspace.shared.open(rel.html_url)
                    } label: {
                        Label(L("Tải bản mới", "Download update"), systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .glassButton(prominent: true).controlSize(.large)
                }
            }
        }
        if UpdateSecurity.currentIsAdHoc && rel.canAutoInstall {
            Text(L("Sau lần cập nhật này macOS có thể hỏi lại quyền Trợ năng một lần. Từ bản sau thì không cần nữa.",
                   "After this update macOS may ask for Accessibility access once more. Future updates won't."))
                .noteText().multilineTextAlignment(.center)
        }
    }

    private var settings: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                Text(L("Tự kiểm tra cập nhật", "Check for updates")).font(.system(size: 12, weight: .semibold))
                Picker("", selection: $frequency) {
                    ForEach(UpdateFrequency.allCases, id: \.self) { f in Text(f.title).tag(f) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: frequency) { _ in updater.checkIfDue() }
            }
            VStack(spacing: 6) {
                Text(L("Khi có bản mới", "When an update is available")).font(.system(size: 12, weight: .semibold))
                Picker("", selection: $mode) {
                    ForEach(UpdateMode.allCases, id: \.self) { m in Text(m.shortTitle).tag(m) }
                }
                .pickerStyle(.segmented).labelsHidden().disabled(frequency == .off)
            }
            Text(L("Chỉ hỏi GitHub có bản mới không, không gửi thông tin gì của bạn.",
                   "It only asks GitHub for new versions; nothing about you is sent."))
                .noteText().multilineTextAlignment(.center)
        }
        .padding(14).frame(maxWidth: .infinity).softCard(cornerRadius: 16).padding(.top, 4)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    let model = KeysModel()
    let updater = Updater()
    let tap = CommandTap()
    lazy var panel = PanelController(model: model)
    var statusItem: NSStatusItem!
    private var updateTimer: Timer?
    private var trustTimer: Timer?
    private var activateObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    lazy var welcomePanel = Panel { [unowned self] in AnyView(WelcomeView(model: self.model)) }
    lazy var settingsPanel = Panel { AnyView(SettingsView()) }
    lazy var aboutPanel = Panel { AnyView(AboutView()) }
    lazy var supportPanel = Panel { AnyView(SupportView()) }
    lazy var bugPanel = Panel { AnyView(BugReportView()) }
    lazy var updatePanel = Panel { [unowned self] in AnyView(UpdateView(updater: self.updater)) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupMainMenu()
        setupStatusItem()
        watchApps()
        tap.onPeekStart = { [weak self] in self?.panel.show(peek: true) }
        tap.onPeekEnd = { [weak self] in self?.panel.endPeek() }
        applyPrefs()
        Diag.log("start \(AppInfo.version), trusted=\(model.trusted)")
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
        setupUpdater()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Bấm icon RinKeys trên Dock: mở bảng của app vừa dùng trước đó.
        if Prefs.showInDock { panel.show(peek: false) }
        return false
    }

    func applyPrefs() {
        _ = NSApp.setActivationPolicy(Prefs.showInDock ? .regular : .accessory)
        tap.start()
    }

    private func checkTrust() {
        let now = AXIsProcessTrusted()
        guard now != model.trusted else { return }
        model.trusted = now
        Diag.log("trusted=\(now)")
        tap.start()
        if now && panel.isVisible { model.load() }
    }

    func tryNow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.panel.show(peek: false) }
        }
    }

    // MARK: App đang dùng

    private func watchApps() {
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me {
            model.setTarget(front)
        }
        let nc = NSWorkspace.shared.notificationCenter
        activateObserver = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != me else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let changed = self.model.target?.processIdentifier != app.processIdentifier
                self.model.setTarget(app)
                if changed { self.panel.targetChanged() }
            }
        }
        terminateObserver = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.model.forget(pid: pid) }
        }
    }

    // MARK: Cập nhật

    private func setupUpdater() {
        updater.onChange = { [weak self] in self?.updateIcon() }
        updater.onFoundInBackground = { [weak self] rel in
            guard let self else { return }
            switch Prefs.updateMode {
            case .auto: self.updater.install(rel)
            case .ask: self.updatePanel.show(attention: true)
            case .notify: self.updateIcon()
            }
        }
        updater.onInstallFailed = { [weak self] in self?.updatePanel.show(attention: true) }
        let justUpdated = updater.noteJustUpdated()
        // Lần đầu mở (hoặc chưa có quyền): cửa sổ chào mừng, có hướng dẫn cấp quyền và mẹo dùng.
        if !UserDefaults.standard.bool(forKey: "welcomeShown") || !model.trusted {
            UserDefaults.standard.set(true, forKey: "welcomeShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated { self?.welcomePanel.show(attention: true) }
            }
        } else if justUpdated {
            updatePanel.show(attention: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated { self?.updater.checkIfDue() }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updater.checkIfDue() }
        }
    }

    // MARK: Menu

    private func setupMainMenu() {
        // Menu chính chỉ hiện khi bật icon Dock và RinKeys đang là app chính.
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item(L("Giới thiệu RinKeys", "About RinKeys"), #selector(showAbout)))
        appMenu.addItem(.separator())
        appMenu.addItem(item(L("Cài đặt…", "Settings…"), #selector(showSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("Thoát RinKeys", "Quit RinKeys"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.toolTip = L("RinKeys: bấm để xem phím tắt, chuột phải để mở menu",
                                       "RinKeys: click to see shortcuts, right-click for the menu")
        updateIcon()
    }

    func updateIcon() {
        let name = updater.available != nil ? "MenuBarIconUpdate" : "MenuBarIcon"
        let img = NSImage(named: name) ?? NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "command.square", accessibilityDescription: "RinKeys")
        img?.isTemplate = true
        img?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = img
    }

    @objc func statusClicked(_ sender: Any?) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            panel.toggle()
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if let rel = updater.available {
            menu.addItem(item(L("⬆︎ Có bản mới RinKeys \(rel.version)…", "⬆︎ RinKeys \(rel.version) available…"), #selector(showUpdate)))
            menu.addItem(.separator())
        }
        let name = model.target?.localizedName ?? L("app đang dùng", "current app")
        menu.addItem(item(L("Xem phím tắt của \(name)", "Show \(name) shortcuts"), #selector(showPanelAction)))
        menu.addItem(.separator())
        menu.addItem(item(L("Cài đặt…", "Settings…"), #selector(showSettings), key: ","))
        menu.addItem(item(L("Kiểm tra cập nhật…", "Check for Updates…"), #selector(showUpdate)))
        menu.addItem(.separator())
        menu.addItem(item(L("Mẹo dùng", "Tips"), #selector(showWelcome)))
        menu.addItem(item(L("Giới thiệu RinKeys", "About RinKeys"), #selector(showAbout)))
        menu.addItem(item(L("Báo lỗi…", "Report a Bug…"), #selector(showBug)))
        menu.addItem(item(L("Sao chép nhật ký chẩn đoán", "Copy Diagnostic Log"), #selector(copyDiag)))
        menu.addItem(item(L("♥ Ủng hộ tác giả…", "♥ Support the Author…"), #selector(showSupport)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Thoát RinKeys", "Quit RinKeys"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc func showPanelAction() { panel.show(peek: false) }
    @objc func showSettings() { panel.hide(restoreFocus: false); settingsPanel.show() }
    @objc func showAbout() { panel.hide(restoreFocus: false); aboutPanel.show() }
    @objc func showSupport() { panel.hide(restoreFocus: false); supportPanel.show() }
    @objc func showWelcome() { panel.hide(restoreFocus: false); welcomePanel.show() }
    @objc func showBug() { panel.hide(restoreFocus: false); bugPanel.show() }
    @objc func showUpdate() {
        panel.hide(restoreFocus: false)
        // Luôn hỏi lại GitHub: bản tìm thấy lần trước có thể đã cũ.
        if !updater.isBusy { updater.check() }
        updatePanel.show()
    }

    @objc func copyDiag() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(AppInfo.diagnostics + "\n\n" + BugReport.log, forType: .string)
    }
}

@main
struct RinKeysApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
