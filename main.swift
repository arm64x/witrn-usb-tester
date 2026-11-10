// Witrn USB Tester — nạp firmware cho WITRN K2 / CC1 và Monitor (đồ thị, REC, gói USB PD) cho K2 trên macOS.
// Một file: giao thức DFU (USB HID qua IOKit) + Monitor chỉ đọc + giao diện SwiftUI.
// Giao thức dựa trên tài liệu của dự án WITRN-K2-REVERSE (giấy phép MIT);
// thông số từng model (PID, địa chỉ, sector) lấy từ bảng thiết bị của công cụ WITRN UP V3.0.
import Cocoa
import SwiftUI
import IOKit.hid
import Compression
import UniformTypeIdentifiers

// MARK: - Ngôn ngữ (mặc định tiếng Anh, đổi được sang tiếng Việt)

final class Lang: ObservableObject {
    static let shared = Lang()
    static let all = [("en", "English"), ("vi", "Tiếng Việt")]
    static var vi = UserDefaults.standard.string(forKey: "lang") == "vi"     // đọc được từ mọi luồng
    @Published private(set) var code = Lang.vi ? "vi" : "en"
    var onChange: (() -> Void)?      // dựng lại menu, đặt lại tiêu đề cửa sổ

    func set(_ c: String) {
        guard c != code else { return }
        Lang.vi = c == "vi"
        UserDefaults.standard.set(c, forKey: "lang")
        code = c
        onChange?()
    }
}

/// Chuỗi giao diện theo ngôn ngữ đang chọn.
func L(_ en: String, _ vi: String) -> String { Lang.vi ? vi : en }

/// Bọc gốc mỗi cửa sổ: đổi ngôn ngữ thì dựng lại toàn bộ cây giao diện.
struct Localized<Content: View>: View {
    @ObservedObject private var lang = Lang.shared
    private let content: () -> Content
    init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }
    var body: some View { content().id(lang.code) }
}

// MARK: - Hằng số chung và bảng model

enum W {
    static let vid = 0x0716
    static let flashBase: UInt32 = 0x0800_0000
    static let headerSize = 48
    static let versionOffset = 0x800, markerOffset = 0xC00
    static let commit: [UInt8] = [0xFE, 0xFF, 0xFF, 0xFF]
    // Bảng thay thế byte để giải mã file firmware (dùng chung cho mọi model WITRN)
    static let decode: [UInt8] = hex(
        "1ab6b7f17b8cd53c7c90d2f435f21be9db12775b3d7f3fbd2d472a50dcc3ff57" +
        "828360fc9b4e88d0005f2e592bf9c638f0c88e8044fd737e0b2919afd89671b3" +
        "62e6e511919c4615c4c2a552b966acb22253ee54aab474cfb06c72a7925a56e7" +
        "85ecc19fce6eae3b788f5d4be2640c4c1363c0414fbae41004a63e31e1b84867" +
        "05d39869bf3665be06515cc78b0937c5a9a870d4871dda0df37630ad1794e0b1" +
        "14ed0e08429a33b555d94539e37d4d01cb27ef256a3a7a796d164061a402ab86" +
        "0f346feb6bf728dea3cc752cca5e810afa68f8070324cd1fa22f32439df5d7bc" +
        "9ebb494ad68a84a121df97fe20d11e931c8dfb261895f6c9ddea9923e8a05889")

    static func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }
    static func version(_ b: UInt8) -> String { "\(b >> 4).\(b & 15)" }
}

struct Model: Equatable {
    let id: String
    let pid: Int
    let guid: [UInt8]               // GUID trong header firmware, bố cục little-endian
    let appStart: UInt32
    let sectorSize: Int
    let sectorCount: Int
    let nameStart: UInt32?          // vùng tên trong bootloader; nil = chưa biết, nhận diện bằng PID
    let names: [String]
    let cortexM: Bool               // true: firmware mở đầu bằng bảng vector ARM; false: RISC-V
    let pageURL: String
    let zipPattern: String

    var region: Int { sectorSize * sectorCount }
    var markerAddr: UInt32 { appStart + UInt32(W.markerOffset) }
    static func == (a: Model, b: Model) -> Bool { a.id == b.id }

    // 5a3f8522-366b-46cc-aacc-dbfbe2fee02a
    static let k2 = Model(
        id: "K2", pid: 0x5060,
        guid: [0x22, 0x85, 0x3F, 0x5A, 0x6B, 0x36, 0xCC, 0x46, 0xAA, 0xCC, 0xDB, 0xFB, 0xE2, 0xFE, 0xE0, 0x2A],
        appStart: 0x0800_3800, sectorSize: 2048, sectorCount: 447,
        nameStart: 0x0800_1400, names: ["K2", "WITRN K2", "K2(C)WITRN"], cortexM: true,
        pageURL: "https://www.witrn.com/?p=2105",
        zipPattern: #"https://www\.witrn\.com/witrn/K2/K2_V(\d+)\.(\d+)\.zip"#)

    // af895554-2c74-4a63-b609-e5bc54011092
    static let cc1 = Model(
        id: "CC1", pid: 0x5100,
        guid: [0x54, 0x55, 0x89, 0xAF, 0x74, 0x2C, 0x63, 0x4A, 0xB6, 0x09, 0xE5, 0xBC, 0x54, 0x01, 0x10, 0x92],
        appStart: 0x0800_2400, sectorSize: 1024, sectorCount: 52,
        nameStart: nil, names: [], cortexM: false,
        pageURL: "https://www.witrn.com/?p=90",
        zipPattern: #"https://www\.witrn\.com/witrn/CC/CC1_V(\d+)\.(\d+)\.zip"#)

    static let all = [k2, cc1]
    static func with(pid: Int) -> Model? { all.first { $0.pid == pid } }
    static func named(_ id: String) -> Model { all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame } ?? k2 }
}

struct WError: LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}

func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}
func bytes32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255), UInt8(v >> 16 & 255), UInt8(v >> 24)] }

// MARK: - Firmware

struct Firmware {
    let model: Model
    let app: [UInt8]
    let version: String
    let date: String
    let fileSize: Int
    let eraseCount: Int

    init(raw: [UInt8]) throws {
        guard raw.count >= W.headerSize + W.markerOffset + 4, raw.count <= 2 << 20 else { throw WError(L("Invalid firmware file size", "Kích thước file firmware không hợp lệ")) }
        let dec = raw.map { W.decode[Int($0)] }
        guard Array(dec[0..<7]) == Array("gzutapp".utf8) else { throw WError(L("Not a WITRN firmware file", "Không phải file firmware WITRN")) }
        let year = Int(dec[7]) | Int(dec[8]) << 8, month = Int(dec[9]), day = Int(dec[10])
        guard (2020..<2050).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            throw WError(L("Invalid release date in the firmware", "Ngày phát hành trong firmware không hợp lệ"))
        }
        guard let model = Model.all.first(where: { $0.guid == Array(dec[20..<36]) }) else {
            throw WError(L("Firmware is for a WITRN model this app does not support (only K2 and CC1 are supported)", "Firmware của model WITRN mà app chưa hỗ trợ (chỉ hỗ trợ K2 và CC1)"))
        }
        let size = Int(le32(dec, 36)), xor = le32(dec, 40), total = le32(dec, 44)
        let app = Array(dec[W.headerSize...])
        guard size == app.count else { throw WError(L("Firmware length does not match the header (corrupt file?)", "Độ dài firmware không khớp header (file hỏng?)")) }
        guard size <= model.region else { throw WError(L("Firmware is larger than the \(model.id) application area", "Firmware lớn hơn vùng nhớ ứng dụng của \(model.id)")) }
        var x: UInt32 = 0, s: UInt32 = 0
        app.withUnsafeBufferPointer { p in
            var i = 0
            var xb: UInt8 = 0
            while i < p.count { xb ^= p[i]; s &+= UInt32(p[i]); i += 1 }
            x = UInt32(xb)
        }
        guard x == xor, s == total else { throw WError(L("Firmware checksum mismatch (corrupt file, please download it again)", "Sai checksum firmware (file hỏng, hãy tải lại)")) }
        guard Array(app[W.markerOffset..<W.markerOffset + 4]) == [0xFF, 0xFF, 0xFF, 0xFF] else {
            throw WError(L("Firmware has an unexpected commit marker", "Firmware có dấu commit bất thường"))
        }
        if model.cortexM {
            let sp = le32(app, 0), reset = le32(app, 4)
            guard sp > 0x2000_0000, sp <= 0x2002_0000, sp % 4 == 0 else { throw WError(L("Firmware stack pointer is outside \(model.id) RAM", "Stack pointer của firmware nằm ngoài RAM \(model.id)")) }
            let entry = reset & ~1
            guard reset & 1 == 1, entry >= model.appStart, entry < model.appStart + UInt32(size) else {
                throw WError(L("Invalid reset vector in the firmware", "Reset vector của firmware không hợp lệ"))
            }
        } else {
            // Firmware RISC-V của WITRN ghi địa chỉ nạp (tính từ đầu flash) ở từ thứ hai.
            guard le32(app, 4) == model.appStart - W.flashBase else { throw WError(L("Firmware load address does not match \(model.id)", "Địa chỉ nạp trong firmware không khớp \(model.id)")) }
        }
        self.model = model
        self.app = app
        version = W.version(app[W.versionOffset])
        date = String(format: "%04d-%02d-%02d", year, month, day)
        fileSize = raw.count
        // Công cụ gốc tính số sector cần xoá theo độ dài cả file (gồm header), tối đa bằng bảng sector của model.
        eraseCount = min((raw.count + model.sectorSize - 1) / model.sectorSize, model.sectorCount)
    }

    /// Mô tả biến thể (CC1 có ba bản chạy song song, mỗi bản lại có kiểu xoay 2 hoặc 4 hướng).
    func variant(fileName: String) -> String {
        guard model == .cc1 else { return "" }
        let kind: String
        switch version.first {
        case "3": kind = L("standard (ripple + cable resistance)", "tiêu chuẩn (gợn sóng + đo trở kháng dây)")
        case "6": kind = L("spectrum (no cable resistance)", "phổ tần (không đo trở kháng dây)")
        case "8": kind = L("fast PDO/RDO (no spectrum, no cable resistance)", "PDO/RDO nhanh (không phổ tần, không trở kháng dây)")
        default: kind = ""
        }
        let turn = fileName.contains("四向") ? L("4-way rotation", "xoay 4 hướng") : fileName.contains("双向") ? L("2-way rotation", "xoay 2 hướng") : ""
        return [kind, turn].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Mọi firmware hợp lệ trong một file: file đơn (.k2, .cc1) hoặc .zip chính hãng (có thể chứa nhiều bản).
    static func candidates(_ url: URL) throws -> [(name: String, fw: Firmware)] {
        guard let data = try? Data(contentsOf: url) else { throw WError(L("Cannot read the file", "Không đọc được file")) }
        guard data.count <= 16 << 20 else { throw WError(L("File is too large to be WITRN firmware", "File quá lớn, không phải firmware WITRN")) }
        guard data.starts(with: [0x50, 0x4B]) else { return [(url.lastPathComponent, try Firmware(raw: [UInt8](data)))] }

        var found = [(name: String, fw: Firmware)]()
        for entry in Zip.entries(data) {
            if let fw = try? Firmware(raw: entry.bytes) { found.append((entry.name, fw)) }
        }
        guard !found.isEmpty else { throw WError(L("The zip contains no valid K2 or CC1 firmware", "File zip không chứa firmware K2 hoặc CC1 hợp lệ")) }
        return found.sorted { ($0.fw.version, $0.name) > ($1.fw.version, $1.name) }
    }
}

// MARK: - Đọc file zip

/// Trình đọc zip tối thiểu. Tự đọc để giải đúng tên file tiếng Trung (zip cũ của WITRN ghi tên bằng GBK,
/// lệnh unzip của macOS không giải nén được).
enum Zip {
    static func entries(_ data: Data, maxSize: Int = 2 << 20) -> [(name: String, bytes: [UInt8])] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 22 else { return [] }
        var eocd = b.count - 22
        while eocd >= 0, u32(eocd) != 0x0605_4B50 { eocd -= 1 }
        guard eocd >= 0 else { return [] }
        var pos = u32(eocd + 16)
        var out = [(name: String, bytes: [UInt8])]()
        for _ in 0..<u16(eocd + 10) {
            guard pos + 46 <= b.count, u32(pos) == 0x0201_4B50 else { break }
            let flags = u16(pos + 8), method = u16(pos + 10), csize = u32(pos + 20), usize = u32(pos + 24)
            let nameLen = u16(pos + 28), local = u32(pos + 42)
            guard pos + 46 + nameLen <= b.count else { break }
            let rawName = Data(b[pos + 46..<pos + 46 + nameLen])
            pos += 46 + nameLen + u16(pos + 30) + u16(pos + 32)
            guard usize > 0, usize <= maxSize, local + 30 <= b.count, u32(local) == 0x0403_4B50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + csize <= b.count else { continue }
            var bytes = [UInt8]()
            if method == 0 {
                bytes = Array(b[start..<start + csize])
            } else if method == 8 {
                bytes = [UInt8](repeating: 0, count: usize)
                let n = b.withUnsafeBufferPointer { src in
                    compression_decode_buffer(&bytes, usize, src.baseAddress! + start, csize, nil, COMPRESSION_ZLIB)
                }
                guard n == usize else { continue }
            } else { continue }
            let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            let name = (flags & 0x800 != 0 ? String(data: rawName, encoding: .utf8) : nil)
                ?? String(data: rawName, encoding: .utf8) ?? String(data: rawName, encoding: gbk) ?? "firmware"
            out.append(((name as NSString).lastPathComponent, bytes))
        }
        return out
    }
}

// MARK: - Khung HID 64 byte

protocol Transport: AnyObject {
    func write(_ frame: [UInt8]) throws
    /// Trả nil nếu hết thời gian chờ mà không có gói nào.
    func read(timeoutMs: Int) throws -> [UInt8]?
    func clear()
    /// true: bỏ hết gói nhận được (dùng khi thiết bị ở chế độ thường, tự gửi số đo liên tục).
    func setDiscard(_ on: Bool)
}

enum Frame {
    static let size = 64, payloadMax = 52, dataMax = 40

    static func build(_ command: UInt8, _ payload: [UInt8] = [], reply: Bool = true) -> [UInt8] {
        precondition(payload.count <= payloadMax)
        let t = UInt32(truncatingIfNeeded: Int(ProcessInfo.processInfo.systemUptime * 1000))
        var f: [UInt8] = [0xFF, 0x55,
                          UInt8(truncatingIfNeeded: t / 1000), UInt8(truncatingIfNeeded: t % 1000),
                          reply ? UInt8(truncatingIfNeeded: t / 30) | 0x80 : UInt8(truncatingIfNeeded: t / 30) & 0x7F,
                          UInt8(truncatingIfNeeded: t / 100), UInt8(truncatingIfNeeded: t % 100),
                          UInt8(truncatingIfNeeded: t / 80),
                          command, UInt8(payload.count)]
        f += payload
        f += [UInt8](repeating: 0, count: payloadMax - payload.count)
        f.append(UInt8(truncatingIfNeeded: f[8..<62].reduce(0) { $0 + Int($1) }))
        f.append(UInt8(truncatingIfNeeded: f[0..<62].reduce(0) { $0 + Int($1) }))
        return f
    }

    static func parse(_ input: [UInt8]) throws -> (cmd: UInt8, payload: [UInt8]) {
        var raw = input
        if raw.count == size + 1, raw[0] == 0 { raw.removeFirst() }
        guard raw.count == size, raw[0] == 0xFF, raw[1] == 0x55, Int(raw[9]) <= payloadMax else {
            throw WError(L("Malformed reply packet from the device", "Gói trả về từ thiết bị sai định dạng"))
        }
        guard raw[62] == UInt8(truncatingIfNeeded: raw[8..<62].reduce(0) { $0 + Int($1) }),
              raw[63] == UInt8(truncatingIfNeeded: raw[0..<62].reduce(0) { $0 + Int($1) }) else {
            throw WError(L("Reply packet from the device has a bad checksum", "Gói trả về từ thiết bị sai checksum"))
        }
        return (raw[8], Array(raw[10..<10 + Int(raw[9])]))
    }
}

// MARK: - Giao thức DFU

final class Dfu {
    static let ack: UInt8 = 2, nak: UInt8 = 1, log: UInt8 = 21
    let io: Transport
    let timeout: Double

    init(_ io: Transport, timeout: Double = 3) { self.io = io; self.timeout = timeout }

    /// Bỏ các gói log còn tồn; gặp gói khác thì dừng để không nhận nhầm ACK.
    private func drain() throws {
        for _ in 0..<256 {
            guard let raw = try io.read(timeoutMs: 0) else { return }
            let cmd = try Frame.parse(raw).cmd
            if cmd == Dfu.nak { throw WError(L("The device reported an error", "Thiết bị báo lỗi")) }
            if cmd != Dfu.log { throw WError(String(format: L("Received unexpected packet 0x%02X", "Nhận gói không mong đợi 0x%02X"), cmd)) }
        }
        throw WError(L("The device keeps streaming data; not in DFU mode?", "Thiết bị gửi dữ liệu liên tục; chưa ở chế độ DFU?"))
    }

    private func recv(_ expected: UInt8) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, let raw = try io.read(timeoutMs: max(1, Int(left * 1000))) else {
                throw WError(L("The device did not respond (timed out)", "Thiết bị không trả lời (hết thời gian chờ)"))
            }
            let (cmd, payload) = try Frame.parse(raw)
            if cmd == Dfu.log { continue }
            if cmd == Dfu.nak { throw WError(L("The device rejected the command", "Thiết bị từ chối lệnh")) }
            if cmd != expected { throw WError(String(format: L("Received packet 0x%02X, expected 0x%02X", "Nhận gói 0x%02X, mong đợi 0x%02X"), cmd, expected)) }
            return payload
        }
    }

    func command(_ cmd: UInt8) throws {
        try drain()
        try io.write(Frame.build(cmd))
        _ = try recv(Dfu.ack)
    }

    func erase(_ address: UInt32) throws {
        try drain()
        try io.write(Frame.build(8, bytes32(address), reply: false))
    }

    func write(_ address: UInt32, _ data: ArraySlice<UInt8>) throws {
        var off = data.startIndex
        while off < data.endIndex {
            let end = min(off + Frame.dataMax, data.endIndex)
            try drain()
            let addr = address + UInt32(off - data.startIndex)
            try io.write(Frame.build(9, bytes32(addr) + [UInt8(end - off)] + data[off..<end], reply: false))
            off = end
        }
    }

    func read(_ address: UInt32, _ size: Int) throws -> [UInt8] {
        try drain()
        try io.write(Frame.build(11, bytes32(address) + [UInt8(size & 255), UInt8(size >> 8)]))
        var out = [UInt8](); out.reserveCapacity(size)
        while out.count < size {
            let chunk = try recv(11)
            guard chunk.count == min(Frame.dataMax, size - out.count) else { throw WError(L("Read packet has the wrong length", "Độ dài gói đọc về không đúng")) }
            out += chunk
        }
        return out
    }

    func readShort(_ address: UInt32, _ size: Int) throws -> [UInt8] {
        try drain()
        try io.write(Frame.build(10, bytes32(address) + [UInt8(size)]))
        let data = try recv(10)
        guard data.count == size else { throw WError(L("Read packet has the wrong length", "Độ dài gói đọc về không đúng")) }
        return data
    }
}

struct Identity {
    let names: [String]
    let version: String
    let committed: Bool
}

enum Updater {
    /// Bắt tay và xác nhận đúng model. Chỉ đọc, không ghi gì.
    static func identify(_ dfu: Dfu, _ model: Model) throws -> Identity {
        try dfu.command(3)
        var names = [String]()
        if let nameStart = model.nameStart {
            let raw = try dfu.read(nameStart, 256)
            names = raw.split(separator: 0, maxSplits: 3, omittingEmptySubsequences: false).prefix(3)
                .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespaces) }
            guard names.contains(where: { model.names.contains($0.uppercased()) }) else {
                throw WError(L("The device does not identify itself as \(model.id) (name: \(names)); stopping to be safe.", "Thiết bị không tự nhận là \(model.id) (tên: \(names)); dừng để an toàn."))
            }
        }
        let v = try dfu.read(model.appStart + UInt32(W.versionOffset), 1)[0]
        let committed = try dfu.readShort(model.markerAddr, 4) == W.commit
        return Identity(names: names, version: W.version(v), committed: committed)
    }

    enum Phase {
        case erase, write, verify, commit
        var label: String {
            switch self {
            case .erase: return L("Erasing", "Xoá")
            case .write: return L("Writing", "Ghi")
            case .verify: return L("Verifying", "Kiểm tra")
            case .commit: return L("Finishing", "Hoàn tất")
            }
        }
    }

    static func flash(_ dfu: Dfu, _ fw: Firmware, progress: (Phase, Int, Int) -> Void) throws {
        let app = fw.app, m = fw.model
        try dfu.command(22)

        try dfu.command(5)
        for i in 0..<fw.eraseCount {
            try dfu.erase(m.appStart + UInt32(i * m.sectorSize))
            progress(.erase, i + 1, fw.eraseCount)
        }
        try dfu.command(4)

        try dfu.command(5)
        var off = 0
        while off < app.count {
            let end = min(off + 1024, app.count)
            try dfu.write(m.appStart + UInt32(off), app[off..<end])
            progress(.write, end, app.count)
            off = end
        }
        try dfu.command(4)

        off = 0
        while off < app.count {
            let end = min(off + 1024, app.count)
            let back = try dfu.read(m.appStart + UInt32(off), end - off)
            guard back.elementsEqual(app[off..<end]) else {
                throw WError(String(format: L("Read-back data differs from the firmware at 0x%08X", "Dữ liệu đọc lại khác firmware tại 0x%08X"), m.appStart + UInt32(off)))
            }
            progress(.verify, end, app.count)
            off = end
        }

        // Chỉ đánh dấu firmware hợp lệ sau khi toàn bộ dữ liệu đọc lại khớp.
        progress(.commit, 0, 1)
        try dfu.command(5)
        try dfu.write(m.markerAddr, W.commit[...])
        guard try dfu.readShort(m.markerAddr, 4) == W.commit else { throw WError(L("Could not write the commit marker", "Không ghi được dấu commit")) }
        try dfu.command(4)
        try dfu.command(23)
        progress(.commit, 1, 1)
    }
}

// MARK: - USB HID qua IOKit

final class HIDTransport: Transport {
    let device: IOHIDDevice
    let pid: Int
    let product: String
    let bufferSize: Int
    let buffer: UnsafeMutablePointer<UInt8>
    private let cond = NSCondition()
    private var queue = [[UInt8]]()
    private var discard = false
    private var closed = false

    init(_ device: IOHIDDevice) {
        self.device = device
        pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        let n = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
        bufferSize = max(64, n)
        buffer = .allocate(capacity: bufferSize)
    }
    deinit { buffer.deallocate() }

    func push(_ frame: [UInt8]) {
        cond.lock()
        if !discard {
            if queue.count >= 4096 { queue.removeFirst(1024) }
            queue.append(frame)
            cond.signal()
        }
        cond.unlock()
    }

    func close() { cond.lock(); closed = true; cond.broadcast(); cond.unlock() }

    func write(_ frame: [UInt8]) throws {
        cond.lock(); let dead = closed; cond.unlock()
        if dead { throw WError(L("Lost the USB connection to the device", "Mất kết nối USB với thiết bị")) }
        let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, frame, frame.count)
        if r != kIOReturnSuccess { throw WError(String(format: L("USB write failed (0x%08X)", "Ghi USB thất bại (0x%08X)"), UInt32(bitPattern: r))) }
    }

    func read(timeoutMs: Int) throws -> [UInt8]? {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while queue.isEmpty {
            if closed { throw WError(L("Lost the USB connection to the device", "Mất kết nối USB với thiết bị")) }
            if timeoutMs <= 0 || !cond.wait(until: deadline) { break }
        }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    func clear() { cond.lock(); queue.removeAll(); cond.unlock() }
    func setDiscard(_ on: Bool) { cond.lock(); discard = on; if on { queue.removeAll() }; cond.unlock() }
}

/// Theo dõi cắm/rút thiết bị trên một luồng riêng để nhận gói không phụ thuộc luồng giao diện.
final class HIDBus {
    var onAttach: ((HIDTransport) -> Void)?
    var onDetach: (() -> Void)?
    private var manager: IOHIDManager?
    private var current: HIDTransport?

    func start() {
        let thread = Thread { [self] in
            let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = m
            let matches = Model.all.map { [kIOHIDVendorIDKey: W.vid, kIOHIDProductIDKey: $0.pid] }
            IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
                Unmanaged<HIDBus>.fromOpaque(ctx!).takeUnretainedValue().matched(dev)
            }, ctx)
            IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
                Unmanaged<HIDBus>.fromOpaque(ctx!).takeUnretainedValue().removed(dev)
            }, ctx)
            IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
            CFRunLoopRun()
        }
        thread.name = "witrn.hid"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func matched(_ dev: IOHIDDevice) {
        guard current == nil else { return }
        let t = HIDTransport(dev)
        current = t
        IOHIDDeviceRegisterInputReportCallback(dev, t.buffer, t.bufferSize, { ctx, _, _, _, _, report, length in
            let t = Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue()
            t.push(Array(UnsafeBufferPointer(start: report, count: length)))
        }, Unmanaged.passUnretained(t).toOpaque())
        DispatchQueue.main.async { self.onAttach?(t) }
    }

    private func removed(_ dev: IOHIDDevice) {
        guard let t = current, CFEqual(t.device, dev) else { return }
        t.close()
        current = nil
        DispatchQueue.main.async { self.onDetach?() }
    }
}

// MARK: - Thiết bị giả lập (tự kiểm tra và xem thử giao diện)

final class FakeDevice: Transport {
    let model: Model
    let appOff: Int
    var mem: [UInt8]
    var sent = [UInt8]()
    private var queue = [[UInt8]]()
    private var batch = false
    private let delayMicros: UInt32
    private let corruptAt: Int?

    init(_ model: Model, delayMicros: UInt32 = 0, corruptAt: Int? = nil) {
        self.model = model; self.delayMicros = delayMicros; self.corruptAt = corruptAt
        appOff = Int(model.appStart - W.flashBase)
        mem = [UInt8](repeating: 0x11, count: max(appOff + model.region, model.id == "K2" ? 0x10_0000 : 0))   // K2: đủ 1 MiB để có vùng tuỳ biến
        if let ns = model.nameStart {
            let names = Array("\(model.id)\0WITRN\0boot\0".utf8), o = Int(ns - W.flashBase)
            for i in 0..<256 { mem[o + i] = i < names.count ? names[i] : 0xFF }
        }
        mem[appOff + W.versionOffset] = 0x34
        mem.replaceSubrange(appOff + W.markerOffset..<appOff + W.markerOffset + 4, with: W.commit)
    }

    func write(_ frame: [UInt8]) throws {
        if delayMicros > 0 { usleep(delayMicros) }
        let (cmd, p) = try Frame.parse(frame)
        sent.append(cmd)
        switch cmd {
        case 3, 22, 23: queue.append(Frame.build(2))
        case 5: batch = true; queue.append(Frame.build(2))
        case 4:
            guard batch else { throw WError("fake: đóng lô khi chưa mở") }
            batch = false; queue.append(Frame.build(2))
        case 8:
            let a = Int(le32(p, 0) - W.flashBase)
            guard batch, frame[4] & 0x80 == 0, a >= appOff, (a - appOff) % model.sectorSize == 0,
                  a + model.sectorSize <= mem.count else { throw WError("fake: xoá sai") }
            for i in a..<a + model.sectorSize { mem[i] = 0xFF }
        case 9:
            let a = Int(le32(p, 0) - W.flashBase), n = Int(p[4])
            guard batch, n <= 40, p.count == 5 + n, a >= appOff, a + n <= mem.count else { throw WError("fake: ghi sai") }
            for i in 0..<n {
                var b = p[5 + i]
                if a + i == corruptAt { b ^= 0x40 }
                mem[a + i] &= b          // flash NOR: chỉ xoá được bit
            }
        case 10:
            let a = Int(le32(p, 0) - W.flashBase), n = Int(p[4])
            queue.append(Frame.build(10, Array(mem[a..<a + n])))
        case 11:
            let a = Int(le32(p, 0) - W.flashBase), n = Int(p[4]) | Int(p[5]) << 8
            var o = 0
            while o < n { queue.append(Frame.build(11, Array(mem[a + o..<a + min(o + 40, n)]))); o += 40 }
        default: throw WError("fake: lệnh lạ \(cmd)")
        }
    }

    func read(timeoutMs: Int) throws -> [UInt8]? { queue.isEmpty ? nil : queue.removeFirst() }
    func clear() { queue.removeAll() }
    func setDiscard(_ on: Bool) {}
}

func selfTest(_ path: String) -> Int32 {
    do {
        let all = try Firmware.candidates(URL(fileURLWithPath: path))
        for (name, fw) in all {
            let m = fw.model
            print("\(name): \(m.id) v\(fw.version) \(fw.date), \(fw.app.count) byte, xoá \(fw.eraseCount) sector \(m.sectorSize) byte")
            let dev = FakeDevice(m), dfu = Dfu(dev, timeout: 0.05)
            let before = try Updater.identify(dfu, m)
            try Updater.flash(dfu, fw) { _, _, _ in }
            var expect = fw.app
            expect.replaceSubrange(W.markerOffset..<W.markerOffset + 4, with: W.commit)
            guard Array(dev.mem[dev.appOff..<dev.appOff + expect.count]) == expect else { print("  FAIL: nội dung flash sai"); return 1 }
            let boot = m.nameStart.map { Int($0 - W.flashBase) } ?? dev.appOff
            guard dev.mem[0..<boot].allSatisfy({ $0 == 0x11 }), dev.sent.last == 23 else { print("  FAIL: đụng bootloader / thiếu lệnh kết thúc"); return 1 }
            let after = try Updater.identify(Dfu(dev, timeout: 0.05), m)
            print("  OK nạp: v\(before.version) → v\(after.version), \(dev.sent.filter { $0 == 8 }.count) sector, \(dev.sent.filter { $0 == 9 }.count) gói ghi")

            let bad = FakeDevice(m, corruptAt: dev.appOff + fw.app.count / 2), dfu2 = Dfu(bad, timeout: 0.05)
            _ = try Updater.identify(dfu2, m)
            do { try Updater.flash(dfu2, fw) { _, _, _ in }; print("  FAIL: không phát hiện lỗi ghi"); return 1 } catch {
                guard !bad.sent.contains(23),
                      Array(bad.mem[bad.appOff + W.markerOffset..<bad.appOff + W.markerOffset + 4]) == [0xFF, 0xFF, 0xFF, 0xFF] else {
                    print("  FAIL: commit dù dữ liệu sai"); return 1
                }
                print("  OK phát hiện lỗi ghi: \(error.localizedDescription)")
            }
            if let ns = m.nameStart {
                let other = FakeDevice(m), o = Int(ns - W.flashBase)
                other.mem.replaceSubrange(o..<o + 9, with: Array("C5\0OTHER\0".utf8))
                do { _ = try Updater.identify(Dfu(other, timeout: 0.05), m); print("  FAIL: nhận nhầm thiết bị"); return 1 } catch {
                    print("  OK từ chối thiết bị lạ: \(error.localizedDescription)")
                }
            }
        }
        return 0
    } catch { print("FAIL: \(error.localizedDescription)"); return 1 }
}

/// Hiện hộp thoại gắn vào giữa cửa sổ app (thay vì nổi riêng trên màn hình) và chờ người dùng chọn.
func showCentered(_ alert: NSAlert) -> NSApplication.ModalResponse {
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return alert.runModal() }
    alert.beginSheetModal(for: window) { NSApp.stopModal(withCode: $0) }
    return NSApp.runModal(for: alert.window)
}

/// Chạy trên vòng lặp chính nhưng ngoài hàng đợi GCD, để hộp thoại modal bên trong không chặn các việc khác.
func onMainLoop(_ block: @escaping () -> Void) { RunLoop.main.perform(inModes: [.common], block: block) }

// MARK: - Điều khiển

struct LogLine: Identifiable {
    let id: Int
    let time: String
    let text: String
    let isError: Bool
}

struct Banner {
    let ok: Bool
    let title: String
    let detail: String
}

final class Controller: ObservableObject {
    enum Mode { case none, probing, normal, noResponse, dfu }

    @Published var mode: Mode = .none
    @Published var model: Model?                    // model của thiết bị đang cắm
    @Published var guideModel = Model.k2.id         // model đang xem hướng dẫn
    @Published var currentVersion = ""
    @Published var committed = true
    @Published var firmware: Firmware?
    @Published var firmwareName = ""
    @Published var firmwareError: String?
    @Published var downloading = false
    @Published var flashing = false
    @Published var sessionDone = false
    @Published var phase = ""
    @Published var progress = 0.0
    @Published var banner: Banner?
    @Published var log = [LogLine]()

    private var transport: Transport?
    private var generation = 0
    private let worker = DispatchQueue(label: "witrn.worker", qos: .userInitiated)
    private let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    func say(_ text: String, error: Bool = false) {
        log.append(LogLine(id: log.count, time: clock.string(from: Date()), text: text, isError: error))
        fputs(text + "\n", stderr)      // để xem được nhật ký khi chạy từ Terminal
    }
    private func main(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }

    // --- thiết bị

    func attach(_ t: Transport, _ m: Model, product: String = "") {
        generation += 1
        transport = t
        model = m; guideModel = m.id
        sessionDone = false
        mode = .probing
        say(L("Found WITRN \(m.id)", "Phát hiện WITRN \(m.id)") + (product.isEmpty ? "" : " (\(product))") + L(", checking its mode…", ", đang kiểm tra chế độ…"))
        if let fw = firmware, fw.model != m {
            firmware = nil; firmwareName = ""
            say(L("Dropped the selected \(fw.model.id) firmware file because the connected device is a \(m.id).", "Bỏ file firmware \(fw.model.id) đã chọn vì thiết bị đang cắm là \(m.id)."))
        }
        probe(generation, t, m, quiet: false)
    }

    func detach() {
        generation += 1
        transport = nil
        model = nil
        mode = .none
        say(L("Device disconnected.", "Thiết bị đã ngắt kết nối."))
    }

    private func probe(_ gen: Int, _ t: Transport, _ m: Model, quiet: Bool) {
        worker.async { [self] in
            // Chế độ thường: thiết bị tự gửi số đo liên tục. Bootloader thì im lặng.
            t.setDiscard(false); t.clear()
            Thread.sleep(forTimeInterval: 0.4)
            var streaming = false
            while let raw = try? t.read(timeoutMs: 0) {
                if let f = try? Frame.parse(raw), f.cmd != Dfu.log { streaming = true }
            }
            if streaming {
                t.setDiscard(true)
                main { [self] in
                    guard gen == generation else { return }
                    mode = .normal
                    say(L("\(m.id) is running in normal mode, not in DFU yet.", "\(m.id) đang chạy chế độ thường, chưa vào DFU."))
                }
                return
            }
            do {
                let id = try Updater.identify(Dfu(t), m)
                main { [self] in
                    guard gen == generation else { return }
                    currentVersion = id.version; committed = id.committed
                    mode = .dfu
                    say(L("\(m.id) is in DFU. ", "\(m.id) đã vào DFU. ") + (id.committed ? L("Current firmware: v\(id.version).", "Firmware hiện tại: v\(id.version).") : L("No complete firmware on the device.", "Chưa có firmware hoàn chỉnh trong máy.")))
                }
            } catch {
                main { [self] in
                    guard gen == generation else { return }
                    if !quiet { say(L("Device not ready: \(error.localizedDescription)", "Thiết bị chưa sẵn sàng: \(error.localizedDescription)"), error: true) }
                    mode = .noResponse
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                        if gen == generation, !flashing { probe(gen, t, m, quiet: true) }
                    }
                }
            }
        }
    }

    // --- firmware

    func loadFirmware(_ url: URL) {
        do {
            var list = try Firmware.candidates(url)
            if let m = model, list.contains(where: { $0.fw.model == m }) { list = list.filter { $0.fw.model == m } }
            guard let pick = list.count == 1 ? list[0] : chooseVariant(list) else { return }
            if let m = model, pick.fw.model != m {
                throw WError(L("this file is for \(pick.fw.model.id), but the connected device is a \(m.id)", "file này dành cho \(pick.fw.model.id), còn thiết bị đang cắm là \(m.id)"))
            }
            firmware = pick.fw; firmwareName = pick.name; firmwareError = nil
            let note = pick.fw.variant(fileName: pick.name)
            say(L("Selected \(pick.name): \(pick.fw.model.id) v\(pick.fw.version)", "Đã chọn \(pick.name): \(pick.fw.model.id) v\(pick.fw.version)") + (note.isEmpty ? "" : " (\(note))")
                + L(", dated \(pick.fw.date), \(pick.fw.app.count) bytes, checksum OK.", ", ngày \(pick.fw.date), \(pick.fw.app.count) byte, checksum đúng."))
        } catch {
            firmwareError = "\(url.lastPathComponent): \(error.localizedDescription)"
            say(L("Cannot use \(url.lastPathComponent): \(error.localizedDescription)", "Không dùng được \(url.lastPathComponent): \(error.localizedDescription)"), error: true)
        }
    }

    /// File zip CC1 chứa nhiều bản chạy song song; hỏi người dùng muốn nạp bản nào.
    private func chooseVariant(_ list: [(name: String, fw: Firmware)]) -> (name: String, fw: Firmware)? {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 560, height: 26), pullsDown: false)
        for item in list {
            let note = item.fw.variant(fileName: item.name)
            popup.addItem(withTitle: "\(item.fw.model.id) v\(item.fw.version)" + (note.isEmpty ? " · \(item.name)" : " · \(note)"))
        }
        let alert = NSAlert()
        alert.messageText = L("This file contains \(list.count) firmware builds", "File này có \(list.count) bản firmware")
        alert.informativeText = L("The builds are maintained in parallel and differ in features; you can switch between them freely. Choose the one to flash:", "Các bản chạy song song, khác nhau về tính năng; có thể nạp đổi qua lại tuỳ ý. Chọn bản muốn nạp:")
        alert.accessoryView = popup
        alert.addButton(withTitle: L("Choose", "Chọn"))
        alert.addButton(withTitle: L("Cancel", "Huỷ"))
        guard showCentered(alert) == .alertFirstButtonReturn else { return nil }
        return list[popup.indexOfSelectedItem]
    }

    func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["k2", "cc1", "zip"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.message = L("Choose a firmware file (.k2, .cc1, or a .zip downloaded from witrn.com)", "Chọn file firmware (.k2, .cc1 hoặc .zip tải từ witrn.com)")
        if panel.runModal() == .OK, let url = panel.url { loadFirmware(url) }
    }

    func downloadLatest() {
        guard !downloading, let m = model else { return }
        downloading = true; firmwareError = nil
        say(L("Looking for the latest \(m.id) firmware on witrn.com…", "Đang tìm firmware \(m.id) mới nhất trên witrn.com…"))
        func fail(_ error: Error) {
            onMainLoop {
                self.firmwareError = L("Download failed: \(error.localizedDescription)", "Tải thất bại: \(error.localizedDescription)")
                self.say(L("Firmware download failed: \(error.localizedDescription)", "Tải firmware thất bại: \(error.localizedDescription)"), error: true)
                self.downloading = false
            }
        }
        fetch(m.pageURL) { [self] pageResult in
            do {
                let page = String(decoding: try pageResult.get(), as: UTF8.self)
                let re = try NSRegularExpression(pattern: m.zipPattern)
                let ns = page as NSString
                let best = re.matches(in: page, range: NSRange(location: 0, length: ns.length))
                    .map { (Int(ns.substring(with: $0.range(at: 1))) ?? 0, Int(ns.substring(with: $0.range(at: 2))) ?? 0, ns.substring(with: $0.range)) }
                    .max { ($0.0, $0.1) < ($1.0, $1.1) }
                guard let link = best?.2 else { throw WError(L("No firmware link found on the WITRN page", "Không tìm thấy link firmware trên trang WITRN")) }
                fetch(link) { zipResult in
                    do {
                        let zip = try zipResult.get()
                        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Witrn Update")
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let file = dir.appendingPathComponent(URL(string: link)!.lastPathComponent)
                        try zip.write(to: file)
                        onMainLoop { self.say(L("Downloaded \(link)", "Đã tải \(link)")); self.downloading = false; self.loadFirmware(file) }
                    } catch { fail(error) }
                }
            } catch { fail(error) }
        }
    }

    private func fetch(_ url: String, _ done: @escaping (Result<Data, Error>) -> Void) {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 60)
        req.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error = error { done(.failure(error)); return }
            guard let data = data, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                done(.failure(WError(L("The WITRN server returned an error", "Máy chủ WITRN trả lỗi")))); return
            }
            done(.success(data))
        }.resume()
    }

    // --- nạp

    var canUpgrade: Bool { mode == .dfu && firmware != nil && firmware?.model == model && !flashing && !sessionDone }

    func confirmAndFlash() {
        guard canUpgrade, let fw = firmware else { return }
        let alert = NSAlert()
        alert.messageText = L("Flash firmware v\(fw.version) to the \(fw.model.id)?", "Nạp firmware v\(fw.version) vào \(fw.model.id)?")
        alert.informativeText = L("Do not unplug the cable or quit the app while flashing.", "Không rút cáp và không tắt app trong lúc nạp.")
        alert.addButton(withTitle: L("Flash", "Nạp"))
        alert.addButton(withTitle: L("Cancel", "Huỷ"))
        if showCentered(alert) == .alertFirstButtonReturn { flash() }
    }

    func flash() {
        guard canUpgrade, let t = transport, let fw = firmware else { return }
        let gen = generation, m = fw.model
        flashing = true; banner = nil; progress = 0; phase = L("Preparing", "Chuẩn bị")
        say(L("Flashing \(m.id) v\(fw.version) (\(fw.app.count) bytes)…", "Bắt đầu nạp \(m.id) v\(fw.version) (\(fw.app.count) byte)…"))
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: L("Flashing WITRN firmware", "Nạp firmware WITRN"))
        let started = Date()
        worker.async { [self] in
            var result: Error?
            do {
                let dfu = Dfu(t)
                _ = try Updater.identify(dfu, m)
                var lastPhase: Updater.Phase?, lastPct = -1
                try Updater.flash(dfu, fw) { ph, done, total in
                    // thanh tiến trình chung: xoá 5%, ghi 50%, kiểm tra 44%, hoàn tất 1%
                    let part = Double(done) / Double(max(total, 1))
                    let overall: Double
                    switch ph {
                    case .erase: overall = 0.05 * part
                    case .write: overall = 0.05 + 0.50 * part
                    case .verify: overall = 0.55 + 0.44 * part
                    case .commit: overall = 0.99 + 0.01 * part
                    }
                    let pct = Int(overall * 200)
                    if ph == lastPhase, pct == lastPct { return }
                    let newPhase = ph != lastPhase
                    lastPhase = ph; lastPct = pct
                    main { [self] in
                        progress = overall
                        phase = ph == .commit ? L("Marking complete", "Đánh dấu hoàn tất") : "\(ph.label) \(Int(part * 100))%"
                        if newPhase {
                            switch ph {
                            case .erase: say(L("Erasing \(total) sectors…", "Xoá \(total) sector…"))
                            case .write: say(L("Writing \(total) bytes…", "Ghi \(total) byte…"))
                            case .verify: say(L("Reading back and comparing every byte…", "Đọc lại và so sánh từng byte…"))
                            case .commit: say(L("Data matches. Marking the firmware valid…", "Dữ liệu khớp. Đánh dấu firmware hợp lệ…"))
                            }
                        }
                    }
                }
            } catch { result = error }
            main { [self] in
                ProcessInfo.processInfo.endActivity(activity)
                flashing = false
                if let result {
                    say(L("ERROR: \(result.localizedDescription)", "LỖI: \(result.localizedDescription)"), error: true)
                    say(L("Flashing did not finish. The bootloader was not overwritten; enter DFU again and flash again.", "Nạp chưa xong. Bootloader không bị ghi đè; hãy vào lại DFU rồi nạp lại."), error: true)
                    banner = Banner(ok: false, title: L("Flashing did not finish", "Nạp chưa xong"),
                                    detail: L("\(result.localizedDescription). Unplug the cable, enter DFU again following the guide, then click Upgrade again.", "\(result.localizedDescription). Rút cáp, vào lại DFU theo hướng dẫn rồi bấm Nâng cấp lần nữa."))
                    progress = 0; phase = ""
                    if gen == generation { mode = .probing; probe(gen, t, m, quiet: false) }
                } else {
                    let secs = Int(Date().timeIntervalSince(started))
                    say(L("Done in \(secs) s. The \(m.id) now has firmware v\(fw.version).", "Hoàn tất sau \(secs) giây. \(m.id) đã có firmware v\(fw.version)."))
                    banner = Banner(ok: true, title: L("\(m.id) v\(fw.version) flashed", "Đã nạp xong \(m.id) v\(fw.version)"),
                                    detail: L("Unplug and replug the cable so the \(m.id) boots the new firmware.", "Rút cáp rồi cắm lại để \(m.id) khởi động với firmware mới."))
                    progress = 1; phase = L("Done", "Xong")
                    sessionDone = true
                }
            }
        }
    }
}

// MARK: - Giao diện

// Vài hiệu chỉnh chỉ có từ macOS 12; trên Big Sur (macOS 11) thì bỏ qua.
extension View {
    @ViewBuilder func selectable() -> some View {
        if #available(macOS 12, *) { textSelection(.enabled) } else { self }
    }
    @ViewBuilder func prominent() -> some View {
        if #available(macOS 12, *) { buttonStyle(.borderedProminent) } else { self }
    }
}

/// Chữ có đoạn **đậm** (tự tách, vì Text chỉ hiểu Markdown từ macOS 12).
func rich(_ s: String) -> Text {
    s.components(separatedBy: "**").enumerated().reduce(Text("")) { acc, part in
        acc + (part.offset % 2 == 1 ? Text(part.element).bold() : Text(part.element))
    }
}

/// Vòng nhấp nháy đánh dấu chỗ cần thao tác trên sơ đồ.
struct Halo: View {
    let color: Color
    @State private var pulse = false
    var body: some View {
        Circle().stroke(color, lineWidth: 2).frame(width: 26, height: 26)
            .scaleEffect(pulse ? 2.1 : 0.9).opacity(pulse ? 0 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

private let ink = Color.primary.opacity(0.85)
private func callout(_ s: String, _ color: Color) -> some View {
    Text(s).font(.system(size: 12, weight: .semibold)).foregroundColor(color).fixedSize()
}

struct K2Diagram: View {
    var body: some View {
        ZStack {
            // đầu cắm USB-C đực
            RoundedRectangle(cornerRadius: 3).stroke(ink, lineWidth: 1.5)
                .frame(width: 50, height: 54).position(x: 37, y: 165)
            // thân máy (mặt sau, mặt in chữ)
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(ink, lineWidth: 1.5))
                .frame(width: 250, height: 200).position(x: 185, y: 165)

            // cổng USB HID trên cạnh
            Halo(color: .blue).position(x: 112, y: 65)
            Capsule().fill(Color.blue).frame(width: 44, height: 10).position(x: 112, y: 65)
            VStack(spacing: 1) {
                Image(systemName: "desktopcomputer").font(.system(size: 17, weight: .semibold))
                Text("USB HID").font(.system(size: 9, weight: .heavy))
            }.foregroundColor(ink).position(x: 112, y: 96)

            Text("K2").font(.system(size: 44, weight: .black, design: .rounded)).foregroundColor(ink).position(x: 185, y: 155)
            Text(L("back side", "mặt sau")).font(.system(size: 10)).foregroundColor(.secondary).position(x: 185, y: 186)

            // hàng nút
            keyTag("BACK").position(x: 102, y: 238)
            keyTag("OK").position(x: 208, y: 238)
            Text("DFU").font(.system(size: 7, weight: .heavy)).padding(.horizontal, 3).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(ink, lineWidth: 1)).foregroundColor(ink)
                .position(x: 155, y: 216)
            Halo(color: .orange).position(x: 155, y: 238)
            Image(systemName: "minus.circle.fill").font(.system(size: 22)).foregroundColor(.orange).position(x: 155, y: 238)
            Image(systemName: "bolt").font(.system(size: 10, weight: .bold)).foregroundColor(ink).position(x: 258, y: 216)
            Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundColor(ink).position(x: 258, y: 238)

            // chú thích
            callout(L("Plug the Mac cable into USB HID", "Cắm cáp nối Mac vào cổng USB HID"), .blue).position(x: 132, y: 16)
            Image(systemName: "arrow.down").font(.system(size: 15, weight: .bold)).foregroundColor(.blue).position(x: 112, y: 42)
            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundColor(.orange).position(x: 155, y: 284)
            callout(L("Hold − (DFU) while plugging in", "Giữ nút − (DFU) trong lúc cắm"), .orange).position(x: 165, y: 308)
        }
        .frame(width: 330, height: 324)
        .accessibilityLabel(L("K2 back side diagram: USB HID port on the top edge at the left, the minus DFU button in the button row below", "Sơ đồ mặt sau K2: cổng USB HID ở cạnh trên bên trái, nút trừ DFU ở hàng nút phía dưới"))
    }

    private func keyTag(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(ink, lineWidth: 1.2)).foregroundColor(ink)
    }
}

struct CC1Diagram: View {
    var body: some View {
        ZStack {
            // đầu cắm USB-C đực (bên trái)
            Halo(color: .blue).position(x: 40, y: 170)
            RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.blue, lineWidth: 1.5))
                .frame(width: 56, height: 46).position(x: 44, y: 170)
            // thân máy
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink, lineWidth: 1.5))
                .frame(width: 232, height: 96).position(x: 188, y: 170)
            // màn hình
            RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.22))
                .frame(width: 172, height: 72).position(x: 168, y: 170)
            Text("CC1").font(.system(size: 30, weight: .black, design: .rounded)).foregroundColor(ink).position(x: 168, y: 170)
            // cổng USB-C cái (bên phải)
            Capsule().fill(ink).frame(width: 6, height: 34).position(x: 303, y: 170)

            // hai nút trên cạnh: K− gần đầu cắm, K+ kế bên
            Halo(color: .orange).position(x: 122, y: 118)
            RoundedRectangle(cornerRadius: 2).fill(Color.orange).frame(width: 26, height: 8).position(x: 122, y: 118)
            RoundedRectangle(cornerRadius: 2).fill(ink).frame(width: 26, height: 8).position(x: 162, y: 118)
            Text("K−").font(.system(size: 11, weight: .heavy)).foregroundColor(.orange).position(x: 122, y: 92)
            Text("K+").font(.system(size: 11, weight: .heavy)).foregroundColor(ink).position(x: 162, y: 92)

            // chú thích
            callout(L("Hold K− (button near the plug)", "Giữ nút K− (nút gần đầu cắm)"), .orange).position(x: 150, y: 38)
            Image(systemName: "arrow.down").font(.system(size: 15, weight: .bold)).foregroundColor(.orange).position(x: 122, y: 64)
            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundColor(.blue).position(x: 44, y: 218)
            callout(L("Plug this USB-C end into the Mac", "Cắm đầu USB-C này vào Mac"), .blue).position(x: 112, y: 242)
            Text(L("(or a data cable into the right USB-C port)", "(hoặc nối cáp dữ liệu vào cổng USB-C bên phải)")).font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize().position(x: 165, y: 262)
        }
        .frame(width: 330, height: 324)
        .accessibilityLabel(L("CC1 diagram: USB-C plug on the left, two buttons on the edge, the K minus button is near the plug", "Sơ đồ CC1: đầu cắm USB-C bên trái, hai nút trên cạnh, nút K trừ nằm gần đầu cắm"))
    }
}

/// Hình thu nhỏ của thiết bị cho thanh tiêu đề: K2 thân gần vuông, CC1 thân dài; đầu cắm USB-C ở bên trái.
struct DeviceIcon: View {
    let model: Model
    var body: some View {
        let cc1 = model == .cc1
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5).stroke(ink, lineWidth: 1.3).frame(width: 6, height: cc1 ? 9 : 11)
            ZStack {
                RoundedRectangle(cornerRadius: cc1 ? 4 : 6).fill(Color(NSColor.controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: cc1 ? 4 : 6).stroke(ink, lineWidth: 1.3))
                RoundedRectangle(cornerRadius: 2.5).fill(Color.accentColor.opacity(0.3)).padding(cc1 ? 3.5 : 4.5)
                Text(model.id).font(.system(size: cc1 ? 9 : 10, weight: .black, design: .rounded)).foregroundColor(ink)
            }
            .frame(width: cc1 ? 48 : 34, height: cc1 ? 20 : 28)
        }
        .accessibilityHidden(true)
    }
}

struct GuideView: View {
    @ObservedObject var c: Controller

    private var steps: [String] {
        c.guideModel == Model.cc1.id ? [
            L("Unplug the CC1 from all cables and chargers.", "Rút CC1 khỏi mọi cáp và bộ sạc."),
            L("Press and hold the **K−** button (the one near the USB-C plug).", "Nhấn giữ nút **K−** (nút nằm gần đầu cắm USB-C)."),
            L("While holding it, plug the CC1's USB-C plug straight into the Mac (or connect a data cable from the Mac to the USB-C port on the other end).", "Vẫn giữ nút, cắm đầu USB-C của CC1 thẳng vào Mac (hoặc nối cáp dữ liệu từ Mac vào cổng USB-C bên kia)."),
            L("Release the button when the CC1 screen shows DFU.", "Khi màn hình CC1 hiện DFU thì thả nút."),
        ] : [
            L("Unplug the K2 from all cables and chargers.", "Rút K2 khỏi mọi cáp và bộ sạc."),
            L("Press and hold the **−** button (labeled DFU above it).", "Nhấn giữ nút **−** (có chữ DFU phía trên)."),
            L("While holding it, plug the cable from the Mac into the K2's **USB HID** port (the one with a computer icon).", "Vẫn giữ nút, cắm cáp từ Mac vào cổng **USB HID** của K2 (cổng có hình máy tính)."),
            L("Release the button when the K2 screen shows DFU.", "Khi màn hình K2 hiện DFU thì thả nút."),
        ]
    }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            if c.guideModel == Model.cc1.id { CC1Diagram() } else { K2Diagram() }
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(L("Put the device into DFU mode", "Đưa thiết bị vào chế độ DFU")).font(.title2.bold())
                    Spacer()
                    Picker(L("Device", "Thiết bị"), selection: $c.guideModel) {
                        ForEach(Model.all, id: \.id) { Text($0.id).tag($0.id) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .disabled(c.model != nil)
                }
                if c.mode == .normal, let m = c.model {
                    hint(m.id == "K2" ? L("The K2 is connected in normal mode: click Open Monitor at the top to see the charts. To flash firmware, unplug it and follow the steps below.", "K2 đang cắm ở chế độ thường: bấm Mở Monitor ở góc trên để xem đồ thị. Muốn nạp firmware thì rút cáp ra và làm theo các bước dưới.")
                                      : L("The \(m.id) is connected but in normal mode. Unplug it and follow the steps below.", "\(m.id) đang cắm nhưng ở chế độ thường. Rút cáp ra và làm lại theo các bước dưới."))
                } else if c.mode == .noResponse, let m = c.model {
                    hint(L("The \(m.id) is not responding to DFU commands. Unplug it and follow the steps below.", "\(m.id) không phản hồi lệnh DFU. Rút cáp ra và làm lại theo các bước dưới."))
                }
                ForEach(Array(steps.enumerated()), id: \.offset) { i, text in step(i + 1, text) }
                Text(L("The cable must carry data; plug it straight into the Mac, not through a hub.", "Cáp phải có dây dữ liệu; nên cắm thẳng vào Mac, không qua hub."))
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(c.mode == .probing ? L("Checking the device…", "Đang kiểm tra thiết bị…") : L("Waiting for a device in DFU mode…", "Đang chờ thiết bị ở chế độ DFU…")).foregroundColor(.secondary)
                }.padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor))
            rich(text).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func hint(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.14)))
    }
}

struct UpgradeView: View {
    @ObservedObject var c: Controller
    @State private var dropping = false
    private var name: String { c.model?.id ?? L("Device", "Thiết bị") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("\(name) connected in DFU mode", "\(name) đã kết nối ở chế độ DFU")).font(.headline)
                    Text(c.committed ? L("Current firmware: v\(c.currentVersion)", "Firmware hiện tại: v\(c.currentVersion)") : L("No complete firmware on the device", "Trong máy chưa có firmware hoàn chỉnh"))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            dropZone

            HStack(spacing: 14) {
                Button(action: c.confirmAndFlash) {
                    Label(c.flashing ? L("Flashing…", "Đang nạp…") : L("Upgrade", "Nâng cấp"), systemImage: "arrow.up.circle.fill")
                        .font(.headline).padding(.horizontal, 10).padding(.vertical, 3)
                }
                .prominent().controlSize(.large).disabled(!c.canUpgrade)
                .keyboardShortcut(.defaultAction)

                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: c.progress)
                    Text(statusText).font(.callout.monospacedDigit()).foregroundColor(.secondary)
                }
            }
        }
    }

    private var statusText: String {
        if c.flashing || c.sessionDone { return L("\(c.phase) · overall \(Int(c.progress * 100))%", "\(c.phase) · tổng \(Int(c.progress * 100))%") }
        guard let fw = c.firmware else { return L("Choose a firmware file to begin", "Chọn file firmware để bắt đầu") }
        return L("Ready to flash v\(fw.version)", "Sẵn sàng nạp v\(fw.version)")
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            if let fw = c.firmware {
                Image(systemName: "doc.badge.gearshape.fill").font(.system(size: 26)).foregroundColor(.accentColor)
                Text(c.firmwareName).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(L("\(fw.model.id) v\(fw.version) · released \(fw.date) · \(fw.fileSize / 1024) KB · checksum OK", "\(fw.model.id) v\(fw.version) · phát hành \(fw.date) · \(fw.fileSize / 1024) KB · checksum đúng"))
                    .font(.callout).foregroundColor(.secondary)
                let note = fw.variant(fileName: c.firmwareName)
                if !note.isEmpty { Text(L("Build: \(note)", "Bản \(note)")).font(.callout).foregroundColor(.secondary) }
            } else {
                Image(systemName: "arrow.down.doc").font(.system(size: 26)).foregroundColor(.secondary)
                Text(L("Drop a firmware file here", "Kéo thả file firmware vào đây")).font(.headline)
                Text(L("A .k2 or .cc1 file, or a .zip downloaded from witrn.com", "File .k2, .cc1, hoặc file .zip tải từ witrn.com")).font(.callout).foregroundColor(.secondary)
            }
            if let e = c.firmwareError {
                Text(e).font(.callout).foregroundColor(.red).multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Button(c.firmware == nil ? L("Choose file…", "Chọn file…") : L("Choose another file…", "Chọn file khác…"), action: c.chooseFirmware)
                Button(action: c.downloadLatest) {
                    if c.downloading { Text(L("Downloading…", "Đang tải…")) } else { Text(L("Download latest", "Tải bản mới nhất")) }
                }.disabled(c.downloading)
            }.disabled(c.flashing).padding(.top, 2)
        }
        .padding(16).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(dropping ? Color.accentColor.opacity(0.14) : Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(dropping ? Color.accentColor : Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard !c.flashing, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { onMainLoop { c.loadFirmware(url) } }
            }
            return true
        }
    }
}

struct LogView: View {
    @ObservedObject var c: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Log", "Nhật ký")).font(.subheadline.bold()).foregroundColor(.secondary)
                Spacer()
                Button(L("Copy", "Sao chép")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c.log.map { "\($0.time)  \($0.text)" }.joined(separator: "\n"), forType: .string)
                }.buttonStyle(.link).font(.subheadline)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(c.log) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(line.time).foregroundColor(.secondary)
                                Text(line.text).foregroundColor(line.isError ? .red : .primary)
                                    .selectable().fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 11.5, design: .monospaced)).id(line.id)
                        }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onReceive(c.$log) { lines in if let last = lines.last { DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        }
    }
}

struct ContentView: View {
    @ObservedObject var c: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let m = c.model {        // tên app đã có trên thanh tiêu đề cửa sổ; ở đây hiện thiết bị vừa nhận ra
                    HStack(spacing: 9) {
                        DeviceIcon(model: m)
                        Text("WITRN \(m.id)").font(.title3.bold())
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer()
                if c.model?.id == Model.k2.id {     // chỉ hiện khi đã nhận ra K2; CC1 không có phần tuỳ biến
                    Button { CustomWindow.shared.show(c) } label: { Label(L("Customize K2", "Tuỳ biến K2"), systemImage: "paintbrush") }
                        .help(L("Edit the K2's watch face, background image and boot image", "Sửa mặt đồng hồ, hình nền và hình khởi động của K2"))
                }
                if c.mode == .normal, c.model?.id == "K2" {
                    Button { MonitorWindow.shared.show() } label: { Label(L("Open Monitor", "Mở Monitor"), systemImage: "waveform.path.ecg") }.prominent()
                        .help(L("View the K2's voltage, current and power charts, REC data and USB PD packets", "Xem đồ thị điện áp, dòng, công suất, bản REC và gói USB PD của K2"))
                }
                statusPill
                Picker("", selection: Binding(get: { Lang.shared.code }, set: { Lang.shared.set($0) })) {
                    ForEach(Lang.all, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().fixedSize().help(L("Language", "Ngôn ngữ"))
            }
            .frame(height: 30)      // cố định để bố cục không nhảy khi icon thiết bị hiện / ẩn
            if let b = c.banner { bannerView(b) }
            Group {
                if c.mode == .dfu { UpgradeView(c: c) } else { GuideView(c: c) }
            }
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .center)
            LogView(c: c).frame(minHeight: 120, maxHeight: .infinity)
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 620)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var statusPill: some View {
        let name = c.model?.id ?? L("device", "thiết bị")
        let (text, color): (String, Color) = {
            switch c.mode {
            case .none: return (L("No device found", "Chưa thấy thiết bị"), .secondary)
            case .probing: return (L("Checking \(name)…", "Đang kiểm tra \(name)…"), .secondary)
            case .normal: return (L("\(name) in normal mode", "\(name) ở chế độ thường"), .orange)
            case .noResponse: return (L("\(name) not responding", "\(name) không phản hồi"), .orange)
            case .dfu: return (L("\(name) · DFU mode", "\(name) · chế độ DFU"), .green)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func bannerView(_ b: Banner) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: b.ok ? "checkmark.seal.fill" : "xmark.octagon.fill").font(.title3).foregroundColor(b.ok ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.title).font(.headline)
                Text(b.detail).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { c.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundColor(.secondary)
                .accessibilityLabel(L("Dismiss", "Đóng thông báo"))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill((b.ok ? Color.green : Color.red).opacity(0.13)))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller = Controller()
    let bus = HIDBus()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Witrn USB Tester"
        window.contentView = NSHostingView(rootView: Localized { [controller] in ContentView(c: controller) })
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("--monitor-demo") || value("--monitor-snapshot") != nil {
            MonitorWindow.shared.show(demo: true)
            if let f = value("--open") { MonitorWindow.shared.ctl?.openFile(URL(fileURLWithPath: f)) }
            if value("--tab") == "pd" { MonitorWindow.shared.ctl?.tab = 1; MonitorWindow.shared.ctl?.pdSel = 3 }
            if let out = value("--monitor-snapshot") {
                Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                    guard let v = MonitorWindow.shared.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(2) }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    exit(0)
                }
            }
        }
        if args.contains("--monitor") { MonitorWindow.shared.show() }
        if args.contains("--custom") || value("--custom-snapshot") != nil {
            CustomWindow.shared.show(controller)
            if let f = value("--open") { CustomWindow.shared.cz.load(URL(fileURLWithPath: f)) }
            if let out = value("--custom-snapshot") {
                Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                    guard let v = CustomWindow.shared.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(2) }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    exit(0)
                }
            }
        }      // mở sẵn cửa sổ Monitor với thiết bị thật
        if let dir = value("--snapshot") {
            runSnapshots(dir, Model.named(value("--model") ?? "K2"), firmware: value("--firmware"))
        } else if args.contains("--demo") {
            let m = Model.named(value("--model") ?? "K2")
            controller.say(L("DEMO MODE: using a simulated \(m.id); nothing is written to a real device.", "CHẾ ĐỘ DEMO: dùng \(m.id) giả lập, không ghi vào thiết bị thật."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.controller.attach(FakeDevice(m, delayMicros: 250), m) }
            if let file = value("--firmware") {     // Timer: khối main-queue không lồng nhau được khi đang modal
                Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                    self.controller.loadFirmware(URL(fileURLWithPath: file))
                }
            }
        } else {
            controller.say(L("Waiting for a WITRN device (K2 or CC1)…", "Đang chờ thiết bị WITRN (K2 hoặc CC1)…"))
            bus.onAttach = { [controller] t in
                guard let m = Model.with(pid: t.pid) else { return }
                controller.attach(t, m, product: t.product)
            }
            bus.onDetach = { [controller] in controller.detach() }
            bus.start()
        }
    }

    @objc func showMain() { window.makeKeyAndOrderFront(nil) }
    @objc func showCustom() { CustomWindow.shared.show(controller) }
    @objc func pickLanguage(_ sender: NSMenuItem) { if let code = sender.representedObject as? String { Lang.shared.set(code) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Mở file firmware bằng app (kéo vào icon hoặc "Mở bằng").
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // AppKit cũng gọi hàm này cho tham số dòng lệnh không phải file (vd giá trị của --model); bỏ qua chúng.
        guard FileManager.default.fileExists(atPath: filename) else { return false }
        let url = URL(fileURLWithPath: filename)
        if ["csv", "wpd", "k2pd", "jsonl"].contains(url.pathExtension.lowercased()) {      // file đo → cửa sổ Monitor
            onMainLoop { MonitorWindow.shared.show(); MonitorWindow.shared.ctl?.openFile(url) }
            return true
        }
        onMainLoop { self.controller.loadFirmware(url) }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmQuit() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmQuit() ? .terminateNow : .terminateCancel
    }

    private func confirmQuit() -> Bool {
        guard controller.flashing else { return true }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("Firmware flashing in progress", "Đang nạp firmware")
        alert.informativeText = L("Quitting now leaves the device without complete firmware (you would have to enter DFU and flash again).", "Thoát lúc này sẽ để thiết bị không có firmware hoàn chỉnh (phải vào DFU nạp lại).")
        alert.addButton(withTitle: L("Keep flashing", "Tiếp tục nạp"))
        alert.addButton(withTitle: L("Quit anyway", "Vẫn thoát"))
        return showCentered(alert) == .alertSecondButtonReturn
    }

    // Chụp các màn hình ra PNG để kiểm tra giao diện (không cần thiết bị).
    private func runSnapshots(_ dir: String, _ m: Model, firmware: String?) {
        let c = controller
        func shot(_ name: String) {
            guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(m.id)-\(name).png"))
        }
        var steps: [() -> Void] = []
        steps.append { c.guideModel = m.id; c.say(L("Waiting for a WITRN device (K2 or CC1)…", "Đang chờ thiết bị WITRN (K2 hoặc CC1)…")) }
        steps.append { shot("1-guide"); c.model = m; c.mode = .normal; c.say(L("\(m.id) is running in normal mode, not in DFU yet.", "\(m.id) đang chạy chế độ thường, chưa vào DFU.")) }
        steps.append { shot("2-normal"); c.attach(FakeDevice(m), m) }
        steps.append {
            shot("3-dfu-empty")
            if let firmware, let pick = try? Firmware.candidates(URL(fileURLWithPath: firmware)).first(where: { $0.fw.model == m }) {
                c.firmware = pick.fw; c.firmwareName = pick.name
            }
        }
        steps.append { shot("4-dfu-ready"); c.flashing = true; c.progress = 0.37; c.phase = "Ghi 64%" }
        steps.append { shot("5-flashing"); c.flashing = false; c.flash() }
        steps.append { shot("6-done"); NSApp.terminate(nil) }
        for (i, s) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + Double(i) * 1.6, execute: s)
        }
    }
}


// ============================ MONITOR K2 (chỉ đọc) ============================

// MARK: - Tiện ích

enum K {
    static let vid = 0x0716, pid = 0x5060
    static let maxSamples = 4_000_000
    static let maxPD = 20_000
}

func u16(_ f: [UInt8], _ o: Int) -> UInt32 { UInt32(f[o]) | UInt32(f[o + 1]) << 8 }
func u32(_ f: [UInt8], _ o: Int) -> UInt32 { UInt32(f[o]) | UInt32(f[o + 1]) << 8 | UInt32(f[o + 2]) << 16 | UInt32(f[o + 3]) << 24 }
func f32(_ f: [UInt8], _ o: Int) -> Float { Float(bitPattern: u32(f, o)) }
func fmt(_ x: Double, _ d: Int) -> String { String(format: "%.\(d)f", abs(x) < 0.5 * pow(10, -Double(d)) ? 0 : x) }
func num(_ x: Double) -> String { String(format: "%g", (x * 1000).rounded() / 1000) }
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func clock(_ s: Double) -> String {
    let t = Int(max(0, s)); let h = t / 3600, m = t / 60 % 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

// MARK: - Gói số đo

struct Reading {
    var thresholdmA = 0
    var ah = 0.0, wh = 0.0
    var recSeconds = 0, upSeconds = 0
    var dp = 0.0, dm = 0.0
    var tempIn: Double? = nil, tempExt: Double? = nil
    var v = 0.0, a = 0.0
    var group = 1
    var cc1 = 0.0, cc2 = 0.0
    var w: Double { v * abs(a) }
}

func parseTelemetry(_ f: [UInt8]) -> Reading? {
    guard f.count >= 64, f[0] == 0xFF, f[1] == 0x55, f[8] == 0x1A else { return nil }
    var s1 = 0, s2 = 0
    for i in 8..<62 { s1 += Int(f[i]) }
    for i in 0..<62 { s2 += Int(f[i]) }
    guard UInt8(s1 & 0xff) == f[62], UInt8(s2 & 0xff) == f[63] else { return nil }
    var r = Reading()
    r.thresholdmA = Int(u16(f, 12))
    r.ah = Double(f32(f, 14)); r.wh = Double(f32(f, 18))
    r.recSeconds = Int(u32(f, 22)); r.upSeconds = Int(u32(f, 26))
    r.dp = Double(f32(f, 30)); r.dm = Double(f32(f, 34))
    let ti = Double(f32(f, 38)), te = Double(f32(f, 42))
    r.tempIn = (ti.isFinite && ti > -40 && ti < 200) ? ti : nil
    r.tempExt = (te.isFinite && te > -40 && te < 200) ? te : nil
    r.v = Double(f32(f, 46)); r.a = Double(f32(f, 50))
    guard r.v.isFinite, r.a.isFinite, r.dp.isFinite, r.dm.isFinite, r.ah.isFinite, r.wh.isFinite else { return nil }
    r.group = Int(f[54]) + 1
    r.cc1 = Double(f[55]) / 10; r.cc2 = Double(f[56]) / 10
    return r
}

func buildTelemetry(_ r: Reading, tick: UInt32) -> [UInt8] {
    var f = [UInt8](repeating: 0, count: 64)
    func put32(_ v: UInt32, _ o: Int) { for i in 0..<4 { f[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) } }
    f[0] = 0xFF; f[1] = 0x55; put32(tick, 2); f[8] = 0x1A; f[9] = 0x34
    f[12] = UInt8(r.thresholdmA & 0xff); f[13] = UInt8(r.thresholdmA >> 8)
    put32(Float(r.ah).bitPattern, 14); put32(Float(r.wh).bitPattern, 18)
    put32(UInt32(r.recSeconds), 22); put32(UInt32(r.upSeconds), 26)
    put32(Float(r.dp).bitPattern, 30); put32(Float(r.dm).bitPattern, 34)
    put32(Float(r.tempIn ?? -100).bitPattern, 38); put32(Float(r.tempExt ?? -100).bitPattern, 42)
    put32(Float(r.v).bitPattern, 46); put32(Float(r.a).bitPattern, 50)
    f[54] = UInt8(max(0, r.group - 1)); f[55] = UInt8(r.cc1 * 10 + 0.5); f[56] = UInt8(r.cc2 * 10 + 0.5)
    var s1 = 0, s2 = 0
    for i in 8..<62 { s1 += Int(f[i]) }
    f[62] = UInt8(s1 & 0xff)
    for i in 0..<62 { s2 += Int(f[i]) }
    f[63] = UInt8(s2 & 0xff)
    return f
}

// MARK: - Dữ liệu đồ thị

struct Sample {
    var t: Double
    var v: Float, a: Float, dp: Float, dm: Float, temp: Float
    var cc1: UInt8, cc2: UInt8
}

final class Series {
    var s: [Sample] = []
    var every = 1            // giữ 1 trong `every` mẫu nhận được
    private var counter = 0
    var name = ""
    var start = Date()
    var device = ""

    func add(_ x: Sample) {
        counter += 1
        if counter % every != 0 { return }
        s.append(x)
        if s.count > K.maxSamples {         // đầy: bỏ bớt một nửa, giảm nửa tốc độ ghi, giữ nguyên toàn bộ thời lượng
            var out: [Sample] = []; out.reserveCapacity(s.count / 2 + 1)
            var i = 0
            while i < s.count { out.append(s[i]); i += 2 }
            s = out; every *= 2
        }
    }
    func clear() { s.removeAll(); counter = 0 }
    func lowerBound(_ t: Double) -> Int {
        var lo = 0, hi = s.count
        while lo < hi { let m = (lo + hi) / 2; if s[m].t < t { lo = m + 1 } else { hi = m } }
        return lo
    }
    var dt: Double {
        let n = min(200, s.count - 1)
        guard n > 0 else { return 0.01 }
        return max(0.001, (s[n].t - s[0].t) / Double(n))
    }
    var gapLimit: Double { max(1.0, 5 * dt) }
}

struct Stats {
    var lo = 0.0, hi = 0.0, count = 0
    var vMin = 0.0, vMax = 0.0, vAvg = 0.0
    var aMin = 0.0, aMax = 0.0, aAvg = 0.0
    var wMax = 0.0, wAvg = 0.0
    var ah = 0.0, wh = 0.0, active = 0.0
    var selected = false
}

func computeStats(_ ser: Series, _ lo: Double, _ hi: Double, signed: Bool = true) -> Stats? {
    let S = ser.s
    var i = ser.lowerBound(lo)
    guard i < S.count, S[i].t <= hi else { return nil }
    let gap = ser.gapLimit
    var st = Stats(); st.lo = lo; st.hi = hi
    var vMin = Double.infinity, vMax = -Double.infinity, aMin = Double.infinity, aMax = -Double.infinity, wMax = 0.0
    var sv = 0.0, sa = 0.0, sw = 0.0, n = 0
    var prev: Sample? = nil
    while i < S.count, S[i].t <= hi {
        let x = S[i]; let v = Double(x.v), a = signed ? Double(x.a) : abs(Double(x.a)), w = v * abs(a)
        vMin = min(vMin, v); vMax = max(vMax, v); aMin = min(aMin, a); aMax = max(aMax, a); wMax = max(wMax, w)
        sv += v; sa += a; sw += w; n += 1
        if let p = prev {
            let d = x.t - p.t
            if d > 0, d <= gap {
                st.ah += (abs(Double(p.a)) + abs(a)) / 2 * d / 3600
                st.wh += (Double(p.v) * abs(Double(p.a)) + w) / 2 * d / 3600
                st.active += d
            }
        }
        prev = x; i += 1
    }
    st.count = n
    st.vMin = vMin; st.vMax = vMax; st.vAvg = sv / Double(n)
    st.aMin = aMin; st.aMax = aMax; st.aAvg = sa / Double(n)
    st.wMax = wMax; st.wAvg = sw / Double(n)
    return st
}

// MARK: - File CSV

enum CSV {
    static let header = "time_s,voltage_V,current_A,power_W,dp_V,dm_V,cc1_V,cc2_V,temp_C"

    static func write(_ ser: Series, lo: Double?, hi: Double?, to url: URL) throws {
        var out = "# Witrn Monitor\n# device=\(ser.device)\n# start=\(ISO8601DateFormatter().string(from: ser.start))\n\(header)\n"
        out.reserveCapacity(ser.s.count * 64)
        let base = lo ?? ser.s.first?.t ?? 0
        for x in ser.s {
            if let lo = lo, x.t < lo { continue }
            if let hi = hi, x.t > hi { break }
            let w = Double(x.v) * abs(Double(x.a))
            let temp = x.temp.isFinite ? String(format: "%.1f", x.temp) : ""
            out += String(format: "%.3f,%.5f,%.5f,%.5f,%.3f,%.3f,%.1f,%.1f,", x.t - base, x.v, x.a, w, x.dp, x.dm, Double(x.cc1) / 10, Double(x.cc2) / 10) + temp + "\n"
        }
        try out.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    // "1.00:02:03.450", "00:02:03.450", "123.45"
    static func time(_ raw: Substring) -> Double? {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " =\"\r\t"))
        if s.isEmpty { return nil }
        if !s.contains(":") { return Double(s) }
        var days = 0.0
        if let dot = s.firstIndex(of: "."), let colon = s.firstIndex(of: ":"), dot < colon {
            days = Double(s[s.startIndex..<dot]) ?? 0; s = String(s[s.index(after: dot)...])
        }
        let parts = s.split(separator: ":").map { Double($0) ?? 0 }
        var t = 0.0
        for p in parts { t = t * 60 + p }
        return days * 86400 + t
    }

    // Đọc được file của app này và file 4 cột của phần mềm WITRN (Time, Voltage, Current, Power).
    static func read(_ url: URL) throws -> Series {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: "csv", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Cannot read the file contents", "Không đọc được nội dung file")])
        }
        let ser = Series(); ser.name = url.lastPathComponent
        var col: [String: Int] = [:]
        var haveHeader = false
        for lineSub in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            if lineSub.hasPrefix("#") {
                if lineSub.hasPrefix("# device=") { ser.device = String(lineSub.dropFirst(9)) }
                if lineSub.hasPrefix("# start="), let d = ISO8601DateFormatter().date(from: String(lineSub.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)) { ser.start = d }
                continue
            }
            let cells = lineSub.split(separator: ",", omittingEmptySubsequences: false)
            if !haveHeader {
                let low = lineSub.lowercased()
                guard low.contains("volt") || low.contains("电压") else { continue }
                for (i, c) in cells.enumerated() {
                    let k = c.lowercased().replacingOccurrences(of: "\u{feff}", with: "")
                    if k.contains("time") || k.contains("时间") { col["t"] = col["t"] ?? i }
                    else if k.contains("volt") || k.contains("电压") { col["v"] = col["v"] ?? i }
                    else if k.contains("curr") || k.contains("电流") { col["a"] = col["a"] ?? i }
                    else if k.hasPrefix("dp") || k.contains("d+") { col["dp"] = i }
                    else if k.hasPrefix("dm") || k.contains("d-") { col["dm"] = i }
                    else if k.contains("cc1") { col["cc1"] = i }
                    else if k.contains("cc2") { col["cc2"] = i }
                    else if k.contains("temp") || k.contains("温度") { col["temp"] = i }
                }
                haveHeader = col["t"] != nil && col["v"] != nil && col["a"] != nil
                continue
            }
            guard let ti = col["t"], let vi = col["v"], let ai = col["a"], cells.count > max(ti, vi, ai),
                  let t = time(cells[ti]), let v = Float(cells[vi].trimmingCharacters(in: .whitespaces)), let a = Float(cells[ai].trimmingCharacters(in: .whitespaces)) else { continue }
            func opt(_ k: String) -> Float? { guard let i = col[k], i < cells.count else { return nil }; return Float(cells[i].trimmingCharacters(in: .whitespaces)) }
            ser.s.append(Sample(t: t, v: v, a: abs(a), dp: opt("dp") ?? 0, dm: opt("dm") ?? 0, temp: opt("temp") ?? .nan,
                                cc1: UInt8(max(0, min(25, opt("cc1") ?? 0)) * 10 + 0.5), cc2: UInt8(max(0, min(25, opt("cc2") ?? 0)) * 10 + 0.5)))
        }
        guard ser.s.count >= 2 else {
            throw NSError(domain: "csv", code: 2, userInfo: [NSLocalizedDescriptionKey: L("No measurement data found in the file (time, voltage and current columns are required)", "Không tìm thấy dữ liệu đo trong file (cần các cột thời gian, điện áp, dòng)")])
        }
        ser.s.sort { $0.t < $1.t }
        return ser
    }
}

// MARK: - Giải mã USB PD

struct PDMsg: Identifiable {
    let id: Int
    let t: Double          // giây kể từ đầu phiên
    let wall: Date
    let frame: [UInt8]     // nguyên gói 64 byte từ K2
    var sop = ""
    var raw: [UInt8] = []
    var name = ""
    var from = ""
    var summary = ""
    var detail: [String] = []
    var kind = 0           // 0 thường, 1 khả năng nguồn, 2 yêu cầu, 3 chấp nhận, 4 lỗi/reset, 5 GoodCRC, 6 VDM
}

final class PDDecoder {
    var srcCaps: [UInt32] = []
    var lastRequest = ""
    var contract = ""
    private var chunkType = -1
    private var chunkBuf: [UInt8] = []

    func reset() { srcCaps = []; lastRequest = ""; contract = ""; chunkType = -1; chunkBuf = [] }

    static let control = [1: "GoodCRC", 2: "GotoMin", 3: "Accept", 4: "Reject", 5: "Ping", 6: "PS_RDY", 7: "Get_Source_Cap", 8: "Get_Sink_Cap",
                          9: "DR_Swap", 10: "PR_Swap", 11: "VCONN_Swap", 12: "Wait", 13: "Soft_Reset", 14: "Data_Reset", 15: "Data_Reset_Complete",
                          16: "Not_Supported", 17: "Get_Source_Cap_Extended", 18: "Get_Status", 19: "FR_Swap", 20: "Get_PPS_Status",
                          21: "Get_Country_Codes", 22: "Get_Sink_Cap_Extended", 23: "Get_Source_Info", 24: "Get_Revision"]
    static let dataMsg = [1: "Source_Capabilities", 2: "Request", 3: "BIST", 4: "Sink_Capabilities", 5: "Battery_Status", 6: "Alert",
                          7: "Get_Country_Info", 8: "Enter_USB", 9: "EPR_Request", 10: "EPR_Mode", 11: "Source_Info", 12: "Revision", 15: "Vendor_Defined"]
    static let extMsg = [1: "Source_Capabilities_Extended", 2: "Status", 3: "Get_Battery_Cap", 4: "Get_Battery_Status", 5: "Battery_Capabilities",
                         6: "Get_Manufacturer_Info", 7: "Manufacturer_Info", 8: "Security_Request", 9: "Security_Response",
                         10: "Firmware_Update_Request", 11: "Firmware_Update_Response", 12: "PPS_Status", 13: "Country_Info", 14: "Country_Codes",
                         15: "Sink_Capabilities_Extended", 16: "Extended_Control", 17: "EPR_Source_Capabilities", 18: "EPR_Sink_Capabilities",
                         30: "Vendor_Defined_Extended"]
    static let sopNames: [UInt8: String] = [224: "SOP", 192: "SOP'", 160: "SOP''", 128: "SOP'_DBG", 96: "SOP''_DBG", 64: "Hard Reset", 32: "Cable Reset"]

    static func pdoText(_ p: UInt32) -> String {
        if p == 0 { return L("(empty)", "(trống)") }
        switch p >> 30 {
        case 0:
            let v = Double((p >> 10) & 0x3ff) * 0.05, i = Double(p & 0x3ff) * 0.01
            return "Fixed \(num(v))V \(num(i))A (\(num(v * i))W)"
        case 1:
            return "Battery \(num(Double((p >> 10) & 0x3ff) * 0.05))–\(num(Double((p >> 20) & 0x3ff) * 0.05))V \(num(Double(p & 0x3ff) * 0.25))W"
        case 2:
            return "Variable \(num(Double((p >> 10) & 0x3ff) * 0.05))–\(num(Double((p >> 20) & 0x3ff) * 0.05))V \(num(Double(p & 0x3ff) * 0.01))A"
        default:
            switch (p >> 28) & 3 {
            case 0: return "PPS \(num(Double((p >> 8) & 0xff) * 0.1))–\(num(Double((p >> 17) & 0xff) * 0.1))V \(num(Double(p & 0x7f) * 0.05))A"
            case 1: return "EPR AVS \(num(Double((p >> 8) & 0xff) * 0.1))–\(num(Double((p >> 17) & 0x1ff) * 0.1))V \(p & 0xff)W"
            case 2: return "SPR AVS 9–15V \(num(Double((p >> 10) & 0x3ff) * 0.01))A, 15–20V \(num(Double(p & 0x3ff) * 0.01))A"
            default: return String(format: L("Unknown APDO 0x%08X", "APDO không rõ 0x%08X"), p)
            }
        }
    }

    func rdoText(_ r: UInt32) -> String {
        let pos = Int(r >> 28)
        var s = "PDO #\(pos): "
        if pos >= 1, pos <= srcCaps.count, srcCaps[pos - 1] != 0 {
            let p = srcCaps[pos - 1]
            if p >> 30 == 3 {
                let i = Double(r & 0x7f) * 0.05
                if (p >> 28) & 3 == 0 { s += "PPS \(num(Double((r >> 9) & 0xfff) * 0.02))V \(num(i))A" }
                else { s += "AVS \(num(Double((r >> 9) & 0xfff) * 0.025))V \(num(i))A" }
            } else if p >> 30 == 1 {
                s += L("Battery, power \(num(Double((r >> 10) & 0x3ff) * 0.25))W", "Battery, công suất \(num(Double((r >> 10) & 0x3ff) * 0.25))W")
            } else {
                let v = Double((p >> 10) & 0x3ff) * 0.05
                s += L("\(num(v))V, operating \(num(Double((r >> 10) & 0x3ff) * 0.01))A (max \(num(Double(r & 0x3ff) * 0.01))A)", "\(num(v))V, dùng \(num(Double((r >> 10) & 0x3ff) * 0.01))A (tối đa \(num(Double(r & 0x3ff) * 0.01))A)")
            }
        } else {
            s += L("operating \(num(Double((r >> 10) & 0x3ff) * 0.01))A if Fixed (Source_Capabilities was not captured, so the type is unknown)", "dùng \(num(Double((r >> 10) & 0x3ff) * 0.01))A nếu là Fixed (chưa bắt được Source_Capabilities nên không rõ loại)")
        }
        if r & (1 << 26) != 0 { s += L(" · capability mismatch", " · thiếu công suất") }
        if r & (1 << 22) != 0 { s += " · EPR" }
        return s
    }

    func decode(_ m: inout PDMsg) {
        let f = m.frame
        m.sop = PDDecoder.sopNames[f[2]] ?? String(format: "SOP?%02X", f[2])
        let end = max(3, min(64, Int(f[1]) + 2))
        m.raw = Array(f[3..<end])
        if f[2] == 64 || f[2] == 32 {
            m.name = m.sop; m.kind = 4; m.summary = L("PD link reset", "Đặt lại liên kết PD")
            if f[2] == 64 { lastRequest = ""; contract = "" }
            return
        }
        let raw = m.raw
        guard raw.count >= 2 else { m.name = L("(packet too short)", "(gói quá ngắn)"); m.kind = 4; return }
        let h = UInt32(raw[0]) | UInt32(raw[1]) << 8
        let type = Int(h & 0x1f), n = Int((h >> 12) & 7), ext = (h >> 15) & 1 == 1
        let isSOP = f[2] == 224
        let bit8 = (h >> 8) & 1 == 1
        m.from = isSOP ? (bit8 ? L("Source", "Nguồn") : L("Sink", "Thiết bị")) : (bit8 ? L("Cable", "Cáp") : L("Port", "Cổng"))
        m.detail.append(String(format: L("Header 0x%04X: type %d, %d objects, MsgID %d, PD rev %d.0%@", "Header 0x%04X: loại %d, số object %d, MsgID %d, PD rev %d.0%@"), h, type, n, (h >> 9) & 7, ((h >> 6) & 3) + 1, ext ? ", extended" : ""))
        if isSOP {
            let pr = bit8 ? "Source" : "Sink", dr = (h >> 5) & 1 == 1 ? "DFP" : "UFP"
            m.detail.append(L("Power role: \(pr), data role: \(dr)", "Vai trò nguồn: \(pr), vai trò dữ liệu: \(dr)"))
        }
        var objs: [UInt32] = []
        for i in 0..<n where 2 + 4 * i + 4 <= raw.count { objs.append(u32(raw, 2 + 4 * i)) }

        if ext {
            m.name = PDDecoder.extMsg[type] ?? "Extended_\(type)"
            guard raw.count >= 4 else { return }
            let eh = UInt32(raw[2]) | UInt32(raw[3]) << 8
            let size = Int(eh & 0x1ff), chunked = (eh >> 15) & 1 == 1, chunkNo = Int((eh >> 11) & 0xf), req = (eh >> 10) & 1 == 1
            let ck = chunked ? ", chunk \(chunkNo)" : "", rq = req ? L(" (chunk request)", " (yêu cầu chunk)") : ""
            m.detail.append(L("Extended header: \(size) data bytes\(ck)\(rq)", "Extended header: \(size) byte dữ liệu\(ck)\(rq)"))
            if req { m.summary = L("chunk \(chunkNo) requested", "yêu cầu chunk \(chunkNo)"); return }
            let dataEnd = n > 0 ? min(raw.count, 2 + 4 * n) : raw.count
            let part = Array(raw[min(4, dataEnd)..<dataEnd])
            if chunkNo == 0 || chunkType != type { chunkBuf = []; chunkType = type }
            chunkBuf += part
            guard chunkBuf.count >= size else { m.summary = L("chunk \(chunkNo), received \(chunkBuf.count)/\(size) bytes", "chunk \(chunkNo), đã nhận \(chunkBuf.count)/\(size) byte"); return }
            let full = Array(chunkBuf.prefix(size)); chunkBuf = []; chunkType = -1
            decodeExtended(type, full, isSOP: isSOP, &m)
            return
        }
        if n == 0 {
            m.name = PDDecoder.control[type] ?? "Control_\(type)"
            switch type {
            case 1: m.kind = 5
            case 3: m.kind = 3
            case 6: m.kind = 3; if isSOP, !lastRequest.isEmpty { contract = lastRequest; m.summary = L("Source ready: \(contract)", "Nguồn đã sẵn sàng: \(contract)") }
            case 4, 12, 13, 14, 16: m.kind = 4
            default: break
            }
            return
        }
        m.name = PDDecoder.dataMsg[type] ?? "Data_\(type)"
        switch type {
        case 1, 4:
            if type == 1 { m.kind = 1; if isSOP { srcCaps = objs } }
            m.summary = objs.map { PDDecoder.pdoText($0) }.joined(separator: " · ")
            for (i, p) in objs.enumerated() { m.detail.append(String(format: "PDO %d  0x%08X  %@", i + 1, p, PDDecoder.pdoText(p))) }
            if type == 1, let p = objs.first, p >> 30 == 0 {
                var flags: [String] = []
                if p & (1 << 29) != 0 { flags.append(L("dual-role power", "đổi vai nguồn được")) }
                if p & (1 << 27) != 0 { flags.append(L("unconstrained power", "nguồn không giới hạn")) }
                if p & (1 << 26) != 0 { flags.append(L("USB communications capable", "có giao tiếp USB")) }
                if p & (1 << 25) != 0 { flags.append(L("dual-role data", "đổi vai dữ liệu được")) }
                if p & (1 << 23) != 0 { flags.append(L("EPR capable", "hỗ trợ EPR")) }
                if !flags.isEmpty { m.detail.append(L("Flags: ", "Cờ: ") + flags.joined(separator: ", ")) }
            }
        case 2, 9:
            m.kind = 2
            if let r = objs.first {
                m.summary = rdoText(r); lastRequest = m.summary
                m.detail.append(String(format: "RDO 0x%08X  %@", r, m.summary))
                if type == 9, objs.count > 1 { m.detail.append(String(format: L("Attached PDO 0x%08X  %@", "PDO kèm theo 0x%08X  %@"), objs[1], PDDecoder.pdoText(objs[1]))) }
            }
        case 10:
            if let o = objs.first {
                let act = [1: "Enter", 2: "Enter Acknowledged", 3: "Enter Succeeded", 4: "Enter Failed", 5: "Exit"][Int(o >> 24)] ?? L("action \(o >> 24)", "hành động \(o >> 24)")
                m.summary = L("\(act), data \((o >> 16) & 0xff)", "\(act), dữ liệu \((o >> 16) & 0xff)")
            }
        case 6:
            if let o = objs.first { m.summary = String(format: L("Alert type 0x%02X", "Alert loại 0x%02X"), o >> 24) }
        case 12:
            if let o = objs.first { m.summary = L("PD \(o >> 28).\((o >> 24) & 0xf), version \((o >> 20) & 0xf).\((o >> 16) & 0xf)", "PD \(o >> 28).\((o >> 24) & 0xf), phiên bản \((o >> 20) & 0xf).\((o >> 16) & 0xf)") }
        case 15:
            m.kind = 6
            if let o = objs.first { decodeVDM(o, Array(objs.dropFirst()), &m) }
        default:
            m.summary = objs.map { String(format: "%08X", $0) }.joined(separator: " ")
        }
    }

    private func decodeVDM(_ o: UInt32, _ rest: [UInt32], _ m: inout PDMsg) {
        let svid = o >> 16
        guard (o >> 15) & 1 == 1 else { m.summary = String(format: L("Unstructured VDM, VID 0x%04X, data 0x%04X", "VDM không cấu trúc, VID 0x%04X, dữ liệu 0x%04X"), svid, o & 0x7fff); return }
        let cmd = Int(o & 0x1f), ct = Int((o >> 6) & 3)
        let cmdName = [1: "Discover Identity", 2: "Discover SVIDs", 3: "Discover Modes", 4: "Enter Mode", 5: "Exit Mode", 6: "Attention", 16: "DP Status", 17: "DP Configure"][cmd] ?? L("command \(cmd)", "lệnh \(cmd)")
        m.summary = String(format: "%@ %@ (SVID 0x%04X)", cmdName, ["REQ", "ACK", "NAK", "BUSY"][ct], svid)
        for (i, v) in rest.enumerated() { m.detail.append(String(format: "VDO %d  0x%08X", i + 1, v)) }
        if cmd == 1, ct == 1, rest.count >= 1 {
            let idh = rest[0]
            let ptype = Int((idh >> 27) & 7)
            m.detail.append(String(format: L("ID Header: VID 0x%04X, product type %d", "ID Header: VID 0x%04X, loại sản phẩm %d"), idh & 0xffff, ptype))
            m.summary += String(format: " · VID 0x%04X", idh & 0xffff)
            if rest.count >= 3 { m.detail.append(String(format: "Product: PID 0x%04X, bcdDevice 0x%04X", rest[2] >> 16, rest[2] & 0xffff)) }
            if m.sop.hasPrefix("SOP'"), rest.count >= 4 {
                let c = rest[3]
                let cur = [0: L("unknown", "không rõ"), 1: "3A", 2: "5A"][Int((c >> 5) & 3)] ?? "?"
                let volt = ["20V", "30V", "40V", "50V"][Int((c >> 9) & 3)]
                let speed = ["USB 2.0", "USB 3.2 Gen1", "USB 3.2 Gen2", "USB4 Gen3", "USB4 Gen4"]
                let sp = Int(c & 7)
                let spd = sp < speed.count ? speed[sp] : L("speed \(sp)", "tốc độ \(sp)"), active = ptype == 4 ? L(", active cable", ", cáp chủ động") : ""
                    let line = L("E-marker cable: \(cur), max \(volt), \(spd)\(active)", "Cáp e-marker: \(cur), tối đa \(volt), \(spd)\(active)")
                m.detail.append(line); m.summary += " · " + line
            }
        }
    }

    private func decodeExtended(_ type: Int, _ d: [UInt8], isSOP: Bool, _ m: inout PDMsg) {
        switch type {
        case 17, 18:
            var objs: [UInt32] = []
            var i = 0
            while i + 4 <= d.count { objs.append(u32(d, i)); i += 4 }
            if type == 17 { m.kind = 1; if isSOP { srcCaps = objs } }
            m.summary = objs.filter { $0 != 0 }.map { PDDecoder.pdoText($0) }.joined(separator: " · ")
            for (i, p) in objs.enumerated() where p != 0 { m.detail.append(String(format: "PDO %d  0x%08X  %@", i + 1, p, PDDecoder.pdoText(p))) }
        case 1:
            if d.count >= 24 {
                m.summary = String(format: L("VID 0x%04X PID 0x%04X, rated power %dW", "VID 0x%04X PID 0x%04X, công suất danh định %dW"), u16(d, 0), u16(d, 2), d[23]) + (d.count >= 25 && d[24] > 0 ? ", EPR \(d[24])W" : "")
                m.detail.append(L("Firmware \(d[8]), hardware \(d[9])", "Firmware \(d[8]), phần cứng \(d[9])"))
            }
        case 12:
            if d.count >= 4 {
                let v = u16(d, 0), i = d[2]
                m.summary = L("Output ", "Ngõ ra ") + (v == 0xffff ? "?" : num(Double(v) * 0.02)) + "V " + (i == 0xff ? "?" : num(Double(i) * 0.05)) + "A" + (d[3] & 0x08 != 0 ? L(" · current limiting", " · đang giới hạn dòng") : "")
            }
        case 2:
            if d.count >= 1 { m.summary = L("Internal temperature \(d[0])°C", "Nhiệt độ trong \(d[0])°C") }
        case 7:
            if d.count >= 4 {
                let str = String(bytes: d[4...].prefix { $0 != 0 }, encoding: .utf8) ?? ""
                m.summary = String(format: "VID 0x%04X PID 0x%04X %@", u16(d, 0), u16(d, 2), str)
            }
        case 16:
            if d.count >= 1 { m.summary = [1: "EPR_Get_Source_Cap", 2: "EPR_Get_Sink_Cap", 3: "EPR_KeepAlive", 4: "EPR_KeepAlive_Ack"][Int(d[0])] ?? L("type \(d[0])", "loại \(d[0])") }
        default:
            m.summary = "\(d.count) byte"
        }
        if m.detail.count < 12 { m.detail.append(L("Data: ", "Dữ liệu: ") + hex(d)) }
    }
}

// MARK: - Nguồn dữ liệu (K2 thật qua IOKit HID, hoặc giả lập)

enum Event {
    case connected(name: String, serial: String)
    case disconnected
    case frame(time: Double, bytes: [UInt8])
}

protocol Source: AnyObject {
    func start()
    func drain() -> [Event]
}

final class HIDSource: Source {
    private let lock = NSLock()
    private var pending: [Event] = []
    private var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private var manager: IOHIDManager?

    func start() {
        let th = Thread { [unowned self] in
            let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = m
            IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: K.vid, kIOHIDProductIDKey: K.pid] as CFDictionary)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
                Unmanaged<HIDSource>.fromOpaque(ctx!).takeUnretainedValue().matched(dev)
            }, ctx)
            IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
                Unmanaged<HIDSource>.fromOpaque(ctx!).takeUnretainedValue().removed(dev)
            }, ctx)
            IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
            CFRunLoopRun()
        }
        th.name = "hid"; th.qualityOfService = .userInteractive; th.start()
    }
    private func push(_ e: Event) { lock.lock(); pending.append(e); lock.unlock() }
    private func matched(_ dev: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "WITRN K2"
        let serial = IOHIDDeviceGetProperty(dev, kIOHIDSerialNumberKey as CFString) as? String ?? ""
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffers[dev] = buf
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { ctx, _, _, _, _, report, length in
            let me = Unmanaged<HIDSource>.fromOpaque(ctx!).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            me.push(.frame(time: ProcessInfo.processInfo.systemUptime, bytes: bytes))
        }, Unmanaged.passUnretained(self).toOpaque())
        push(.connected(name: name, serial: serial))
    }
    private func removed(_ dev: IOHIDDevice) {
        buffers.removeValue(forKey: dev)       // không giải phóng vùng nhớ: callback có thể còn dùng trong lúc gỡ
        if buffers.isEmpty { push(.disconnected) }
    }
    func drain() -> [Event] { lock.lock(); let p = pending; pending = []; lock.unlock(); return p }
}

// Giả lập một lần sạc: 5V → đàm phán PD 9V → 20V, dòng giảm dần. Dùng cho --demo, --snapshot và tự kiểm tra.
final class DemoSource: Source {
    private var began = 0.0
    private var produced = 0
    private var sentConnect = false
    private var ah = 0.0, wh = 0.0
    private var pdSent = 0
    let prefill: Double
    init(prefill: Double = 240) { self.prefill = prefill }
    func start() { began = ProcessInfo.processInfo.systemUptime - prefill }

    static func pdFrame(sop: UInt8, _ msg: [UInt8]) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 64)
        f[0] = 0xFE; f[1] = UInt8(msg.count + 1); f[2] = sop
        for (i, b) in msg.enumerated() where 3 + i < 64 { f[3 + i] = b }
        return f
    }
    static func msg(type: Int, source: Bool, id: Int, _ objs: [UInt32] = []) -> [UInt8] {
        let h = UInt32(type) | (source ? 1 << 5 : 0) | (2 << 6) | (source ? 1 << 8 : 0) | UInt32(id & 7) << 9 | UInt32(objs.count) << 12
        var b: [UInt8] = [UInt8(h & 0xff), UInt8(h >> 8)]
        for o in objs { for i in 0..<4 { b.append(UInt8((o >> (8 * UInt32(i))) & 0xff)) } }
        return b
    }
    static let caps: [UInt32] = [(100 << 10) | 300 | (1 << 26) | (1 << 25), (180 << 10) | 300, (300 << 10) | 300, (400 << 10) | 500,
                                 0xC000_0000 | (210 << 17) | (33 << 8) | 100]
    static var script: [(Double, [UInt8])] {
        func rdo(_ pos: UInt32, _ ma: UInt32) -> UInt32 { pos << 28 | (ma / 10) << 10 | (ma / 10) }
        return [
            (4.00, pdFrame(sop: 224, msg(type: 1, source: true, id: 0, caps))),
            (4.01, pdFrame(sop: 224, msg(type: 1, source: false, id: 0))),
            (4.05, pdFrame(sop: 224, msg(type: 2, source: false, id: 0, [rdo(2, 3000)]))),
            (4.06, pdFrame(sop: 224, msg(type: 1, source: true, id: 0))),
            (4.08, pdFrame(sop: 224, msg(type: 3, source: true, id: 1))),
            (4.30, pdFrame(sop: 224, msg(type: 6, source: true, id: 2))),
            (20.00, pdFrame(sop: 224, msg(type: 2, source: false, id: 1, [rdo(4, 3250)]))),
            (20.02, pdFrame(sop: 224, msg(type: 3, source: true, id: 3))),
            (20.30, pdFrame(sop: 224, msg(type: 6, source: true, id: 4))),
        ]
    }
    static func state(_ t: Double) -> (Double, Double) {
        let wob = sin(t * 2.1) * 0.02 + sin(t * 37) * 0.006
        if t < 4.3 { return (5.08 + wob * 0.2, 0.12 + wob) }
        if t < 20.3 { return (9.02 + wob * 0.3, 1.95 + wob * 3 + min(1, (t - 4.3) / 2) * 0.3) }
        let decay = 0.35 + 2.9 * exp(-(t - 20.3) / 120)
        return (20.05 - decay * 0.02 + wob * 0.3, decay + wob * 2)
    }
    func drain() -> [Event] {
        var out: [Event] = []
        if !sentConnect { sentConnect = true; out.append(.connected(name: L("WITRN.K2 (simulated)", "WITRN.K2 (giả lập)"), serial: "DEMO")) }
        let now = ProcessInfo.processInfo.systemUptime
        let target = Int((now - began) * 100)
        while produced < target {
            let t = Double(produced) / 100
            let (v, a) = DemoSource.state(t)
            ah += a * 0.01 / 3600; wh += v * a * 0.01 / 3600
            var r = Reading()
            r.thresholdmA = 80; r.ah = ah; r.wh = wh; r.recSeconds = Int(t); r.upSeconds = Int(t) + 3
            r.dp = 0.6 + sin(t) * 0.01; r.dm = 0.6; r.tempIn = 27.5 + t / 200; r.v = v; r.a = a; r.cc1 = 1.7; r.cc2 = 0
            out.append(.frame(time: began + t, bytes: buildTelemetry(r, tick: UInt32(produced))))
            while pdSent < DemoSource.script.count, DemoSource.script[pdSent].0 <= t {
                out.append(.frame(time: began + DemoSource.script[pdSent].0, bytes: DemoSource.script[pdSent].1)); pdSent += 1
            }
            produced += 1
        }
        return out
    }
}

// MARK: - Điều khiển

final class ChartState {
    var t0 = 0.0, t1 = 1.0
    var sel: (Double, Double)? = nil
}

final class MonCtl: ObservableObject {
    @Published var connected = false
    @Published var devName = ""
    @Published var serial = ""
    @Published var reading: Reading? = nil
    @Published var pps = 0
    @Published var tick = 0
    @Published var paused = false
    @Published var rate = 100 { didSet { live.every = max(1, 100 / max(1, rate)) } }
    @Published var file: Series? = nil
    @Published var viewMode = 0             // 0 toàn bộ, >0 bám N giây cuối, -1 tự do
    @Published var rightIsPower = false
    @Published var showD = false
    @Published var stats: Stats? = nil
    @Published var pd: [PDMsg] = []
    @Published var pdSel: Int? = nil
    @Published var hideGoodCRC = true
    @Published var tab = 0
    @Published var note = ""
    @Published var busy = false
    @Published var session = (vMin: 0.0, vMax: 0.0, aMax: 0.0, wMax: 0.0)

    let live = Series()
    let chart = ChartState()
    let decoder = PDDecoder()
    var source: Source
    private var origin: Double? = nil
    private var timer: Timer?
    private var windowCount = 0, windowStart = 0.0
    private var pdSeq = 0
    private var lastFrameAt = 0.0

    var shown: Series { file ?? live }

    init(source: Source) { self.source = source; live.name = L("Live", "Trực tiếp") }

    func start() {
        source.start()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pump() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pump() {
        let events = source.drain()
        var changed = false
        var last: Reading? = nil
        var newPD: [PDMsg] = []
        for e in events {
            switch e {
            case .connected(let name, let serial):
                connected = true; devName = name; self.serial = serial
                live.device = serial.isEmpty ? name : "\(name) SN \(serial)"
                if file == nil, !busy { note = "" }
            case .disconnected:
                connected = false; pps = 0
            case .frame(let time, let bytes):
                guard bytes.count >= 64 else { continue }
                windowCount += 1; lastFrameAt = time
                if origin == nil { origin = time; live.start = Date(timeIntervalSinceNow: time - ProcessInfo.processInfo.systemUptime) }
                let t = time - origin!
                if bytes[0] == 0xFF, let r = parseTelemetry(bytes) {
                    last = r
                    if !paused {
                        live.add(Sample(t: t, v: Float(r.v), a: Float(abs(r.a)), dp: Float(r.dp), dm: Float(r.dm), temp: Float(r.tempExt ?? r.tempIn ?? .nan),
                                        cc1: UInt8(r.cc1 * 10 + 0.5), cc2: UInt8(r.cc2 * 10 + 0.5)))
                        if live.s.count == 1 { session = (r.v, r.v, abs(r.a), r.w) }
                        else { session = (min(session.vMin, r.v), max(session.vMax, r.v), max(session.aMax, abs(r.a)), max(session.wMax, r.w)) }
                        changed = true
                    }
                } else if bytes[0] == 0xFE {
                    pdSeq += 1
                    var m = PDMsg(id: pdSeq, t: t, wall: Date(), frame: Array(bytes.prefix(64)))
                    decoder.decode(&m)
                    newPD.append(m)
                }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - windowStart >= 1 { pps = Int(Double(windowCount) / (now - windowStart) + 0.5); windowCount = 0; windowStart = now }
        if let r = last { reading = r }
        if !newPD.isEmpty {
            pd.append(contentsOf: newPD)
            if pd.count > K.maxPD { pd.removeFirst(pd.count - K.maxPD) }
        }
        if changed || !newPD.isEmpty { tick += 1 }
        if tick % 5 == 0 || !changed { refreshStats() }
    }

    func refreshStats() {
        let ser = shown
        guard ser.s.count >= 2 else { if stats != nil { stats = nil }; return }
        let range = chart.sel ?? (chart.t0, chart.t1)
        var st = computeStats(ser, range.0, range.1)
        st?.selected = chart.sel != nil
        stats = st
    }

    func clearLive() {
        live.clear(); origin = nil; chart.sel = nil; viewMode = 0
        session = (0, 0, 0, 0); tick += 1; refreshStats()
    }
    func clearPD() { pd = []; pdSel = nil; decoder.reset() }

    func openFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "wpd" || ext == "k2pd" || ext == "jsonl" { openPD(url); return }
        busy = true; note = L("Opening \(url.lastPathComponent)…", "Đang mở \(url.lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CSV.read(url) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let ser):
                    self.file = ser; self.chart.sel = nil; self.viewMode = 0; self.tab = 0
                    self.note = L("Viewing file \(ser.name): \(ser.s.count) samples, \(clock(ser.s.last!.t - ser.s.first!.t)) long", "Đang xem file \(ser.name): \(ser.s.count) mẫu, dài \(clock(ser.s.last!.t - ser.s.first!.t))")
                    self.tick += 1; self.refreshStats()
                case .failure(let e):
                    self.note = "\(url.lastPathComponent): \(e.localizedDescription)"
                }
            }
        }
    }
    func closeFile() { file = nil; chart.sel = nil; viewMode = 0; note = ""; tick += 1; refreshStats() }

    func saveCSV() {
        let ser = shown
        guard ser.s.count >= 2 else { note = L("No data to save yet", "Chưa có dữ liệu để lưu"); return }
        let p = NSSavePanel()
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        p.nameFieldStringValue = "k2-\(df.string(from: ser.start)).csv"
        p.allowedFileTypes = ["csv"]
        let sel = chart.sel
        if sel != nil { p.message = L("A selection is active: only the selected range is saved", "Đang có vùng chọn: chỉ lưu phần được chọn") }
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try CSV.write(ser, lo: sel?.0, hi: sel?.1, to: url); note = L("Saved \(url.lastPathComponent)", "Đã lưu \(url.lastPathComponent)") }
        catch { note = L("Could not save: \(error.localizedDescription)", "Không lưu được: \(error.localizedDescription)") }
    }
    func openPanel() {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["csv", "wpd", "k2pd", "jsonl", "txt"]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        openFile(url)
    }

    // File bắt PD: mỗi dòng JSON {"t": giây, "hex": 64 byte}. Đọc khoan dung: lấy chuỗi hex 128 ký tự và số đầu tiên trên mỗi dòng.
    func savePD() {
        guard !pd.isEmpty else { note = L("No PD packets yet", "Chưa có gói PD nào"); return }
        let p = NSSavePanel()
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        p.nameFieldStringValue = "k2-pd-\(df.string(from: Date())).wpd"
        p.allowedFileTypes = ["wpd"]
        guard p.runModal() == .OK, let url = p.url else { return }
        var out = "{\"format\":\"witrn-monitor-pd\",\"version\":1}\n"
        for m in pd { out += String(format: "{\"t\":%.3f,\"unix\":%.3f,\"hex\":\"%@\"}\n", m.t, m.wall.timeIntervalSince1970, m.frame.map { String(format: "%02x", $0) }.joined()) }
        do { try out.data(using: .utf8)!.write(to: url, options: .atomic); note = L("Saved \(url.lastPathComponent)", "Đã lưu \(url.lastPathComponent)") }
        catch { note = L("Could not save: \(error.localizedDescription)", "Không lưu được: \(error.localizedDescription)") }
    }
    func openPD(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { note = L("Cannot read \(url.lastPathComponent)", "Không đọc được \(url.lastPathComponent)"); return }
        let msgs = MonCtl.parsePDFile(text)
        guard !msgs.isEmpty else { note = L("\(url.lastPathComponent): no PD packets found", "\(url.lastPathComponent): không thấy gói PD nào"); return }
        decoder.reset()
        var out: [PDMsg] = []
        for (i, m) in msgs.enumerated() {
            var x = PDMsg(id: -(i + 1), t: m.0, wall: Date(timeIntervalSince1970: m.1), frame: m.2)
            decoder.decode(&x); out.append(x)
        }
        pd = out; pdSel = nil; tab = 1
        note = L("Opened \(out.count) PD packets from \(url.lastPathComponent)", "Đã mở \(out.count) gói PD từ \(url.lastPathComponent)")
    }
    static func parsePDFile(_ text: String) -> [(Double, Double, [UInt8])] {
        var out: [(Double, Double, [UInt8])] = []
        for line in text.split(separator: "\n") {
            guard let r = line.range(of: "\"[0-9a-fA-F]{128}\"", options: .regularExpression) else { continue }
            let h = Array(line[r].dropFirst().dropLast())
            var bytes: [UInt8] = []
            var i = 0
            while i + 1 < h.count { bytes.append(UInt8(String(h[i...i + 1]), radix: 16) ?? 0); i += 2 }
            guard bytes.count == 64, bytes[0] == 0xFE else { continue }
            func value(_ key: String) -> Double {
                guard let k = line.range(of: "\"\(key)\":") else { return 0 }
                return Double(line[k.upperBound...].prefix { "0123456789.-".contains($0) }) ?? 0
            }
            out.append((value("t"), value("unix"), bytes))
        }
        return out
    }
}

// MARK: - Đồ thị (NSView vẽ bằng Core Graphics, gộp min/max theo từng cột điểm ảnh)

final class ChartNSView: NSView {
    weak var ctl: MonCtl?
    private var hoverX: CGFloat? = nil
    private var dragStart: CGFloat? = nil
    private var area: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    static let colV = NSColor.systemGreen, colA = NSColor.systemBlue, colW = NSColor.systemOrange
    static let colDp = NSColor.systemPink, colDm = NSColor.systemPurple

    var plot: NSRect { NSRect(x: 56, y: 12, width: max(10, bounds.width - 112), height: max(10, bounds.height - 40)) }

    override func updateTrackingAreas() {
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a); area = a
    }

    static func niceCeil(_ x: Double) -> Double {
        guard x > 0 else { return 1 }
        let p = pow(10, floor(log10(x))); let m = x / p
        for c in [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10] where m <= c + 1e-9 { return c * p }
        return 10 * p
    }
    static func timeStep(_ span: Double, _ maxTicks: Double) -> Double {
        let steps: [Double] = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 28800, 86400]
        for s in steps where span / s <= maxTicks { return s }
        return 86400
    }
    static func timeLabel(_ t: Double, _ step: Double) -> String {
        if step < 1 { let whole = Int(t); return String(format: "%d:%02d", whole / 60, whole % 60) + String(format: "%.2f", t - Double(whole)).dropFirst() }
        return clock(t)
    }

    private func text(_ s: String, _ p: NSPoint, _ color: NSColor, size: CGFloat = 10, align: Int = 0, bold: Bool = false) {
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color])
        let w = a.size().width
        a.draw(at: NSPoint(x: align == 0 ? p.x : (align == 1 ? p.x - w / 2 : p.x - w), y: p.y))
    }

    override func draw(_ dirty: NSRect) {
        guard let ctl = ctl, let g = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        let ser = ctl.shown, S = ser.s, pr = plot
        NSColor.separatorColor.setStroke()
        let frame = NSBezierPath(rect: pr); frame.lineWidth = 1; frame.stroke()
        guard S.count >= 2 else {
            text(ctl.connected ? L("Waiting for data…", "Đang chờ dữ liệu…") : L("Connect a WITRN K2 (normal mode) or drop a CSV file here", "Cắm WITRN K2 (chế độ thường) hoặc kéo một file CSV vào đây"), NSPoint(x: pr.midX, y: pr.midY - 8), .secondaryLabelColor, size: 13, align: 1)
            return
        }
        let first = S[0].t, last = S[S.count - 1].t
        var t0 = ctl.chart.t0, t1 = ctl.chart.t1
        if ctl.viewMode == 0 { t0 = first; t1 = max(last, first + 1) }
        else if ctl.viewMode > 0 {
            let span = Double(ctl.viewMode)
            if last - first < span { t0 = first; t1 = first + span } else { t1 = last; t0 = last - span }
        }
        if t1 - t0 < 0.02 { t1 = t0 + 0.02 }
        ctl.chart.t0 = t0; ctl.chart.t1 = t1

        let W = Int(pr.width)
        let power = ctl.rightIsPower, showD = ctl.showD
        var vMin = [Float](repeating: .infinity, count: W), vMax = [Float](repeating: -.infinity, count: W)
        var rMin = vMin, rMax = vMax
        var tFirst = [Double](repeating: 0, count: W), tLast = tFirst
        var dpSum = [Float](repeating: 0, count: showD ? W : 0), dmSum = dpSum
        var cnt = [Int32](repeating: 0, count: W)
        let scale = Double(W) / (t1 - t0)
        var i = ser.lowerBound(t0)
        var gV: Float = 0, gRmax: Float = 0, gRmin: Float = 0
        S.withUnsafeBufferPointer { p in
            while i < p.count, p[i].t <= t1 {
                let x = p[i]; let c = min(W - 1, max(0, Int((x.t - t0) * scale)))
                let r = power ? x.v * abs(x.a) : x.a
                if cnt[c] == 0 { tFirst[c] = x.t }
                tLast[c] = x.t; cnt[c] += 1
                if x.v < vMin[c] { vMin[c] = x.v }; if x.v > vMax[c] { vMax[c] = x.v }
                if r < rMin[c] { rMin[c] = r }; if r > rMax[c] { rMax[c] = r }
                if showD { dpSum[c] += x.dp; dmSum[c] += x.dm }
                if x.v > gV { gV = x.v }; if r > gRmax { gRmax = r }; if r < gRmin { gRmin = r }
                i += 1
            }
        }
        let vTop = ChartNSView.niceCeil(max(Double(gV) * 1.08, 1))
        var rTop = ChartNSView.niceCeil(max(Double(gRmax) * 1.08, 0.1))
        var rBot = 0.0
        if gRmin < -0.005 {      // có dòng ngược: chia 5 khoảng tròn số, vạch 0 nằm đúng trên lưới
            let stepR = ChartNSView.niceCeil((max(Double(gRmax), 0.05) - Double(gRmin)) * 1.08 / 4)
            rBot = (Double(gRmin) * 1.04 / stepR).rounded(.down) * stepR
            rTop = rBot + 5 * stepR
        }
        func yV(_ v: Float) -> CGFloat { pr.maxY - CGFloat(Double(v) / vTop) * pr.height }
        func yR(_ v: Float) -> CGFloat { pr.maxY - CGFloat((Double(v) - rBot) / (rTop - rBot)) * pr.height }
        func xT(_ t: Double) -> CGFloat { pr.minX + CGFloat((t - t0) / (t1 - t0)) * pr.width }

        // lưới + nhãn trục
        let colR = power ? ChartNSView.colW : ChartNSView.colA
        g.setLineWidth(0.5)
        for k in 0...5 {
            let y = pr.maxY - pr.height * CGFloat(k) / 5
            g.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.5).cgColor)
            g.move(to: CGPoint(x: pr.minX, y: y)); g.addLine(to: CGPoint(x: pr.maxX, y: y)); g.strokePath()
            text(num(vTop * Double(k) / 5) + (k == 5 ? " V" : ""), NSPoint(x: pr.minX - 5, y: y - 6), ChartNSView.colV, align: 2)
            text(num(rBot + (rTop - rBot) * Double(k) / 5) + (k == 5 ? (power ? " W" : " A") : ""), NSPoint(x: pr.maxX + 5, y: y - 6), colR)
        }
        let step = ChartNSView.timeStep(t1 - t0, Double(pr.width / 80))
        var tt = (t0 / step).rounded(.up) * step
        while tt <= t1 + 1e-9 {
            let x = xT(tt)
            g.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.5).cgColor)
            g.move(to: CGPoint(x: x, y: pr.minY)); g.addLine(to: CGPoint(x: x, y: pr.maxY)); g.strokePath()
            text(ChartNSView.timeLabel(tt, step), NSPoint(x: x, y: pr.maxY + 5), .secondaryLabelColor, align: 1)
            tt += step
        }

        // vùng chọn
        if let sel = ctl.chart.sel {
            let a = max(pr.minX, min(pr.maxX, xT(sel.0))), b = max(pr.minX, min(pr.maxX, xT(sel.1)))
            g.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
            g.fill(CGRect(x: a, y: pr.minY, width: b - a, height: pr.height))
        }

        g.saveGState(); g.clip(to: pr.insetBy(dx: 0, dy: -1))
        let gap = ser.gapLimit
        func stroke(_ color: NSColor, _ width: CGFloat, lo: (Int) -> CGFloat, hi: (Int) -> CGFloat) {
            let path = CGMutablePath(); var open = false; var prev = -1
            for c in 0..<W where cnt[c] > 0 {
                let x = pr.minX + CGFloat(c) + 0.5
                if open, prev >= 0, tFirst[c] - tLast[prev] <= gap { path.addLine(to: CGPoint(x: x, y: lo(c))) } else { path.move(to: CGPoint(x: x, y: lo(c))) }
                let h = hi(c); if h != lo(c) { path.addLine(to: CGPoint(x: x, y: h)) }
                open = true; prev = c
            }
            g.addPath(path); g.setStrokeColor(color.cgColor); g.setLineWidth(width); g.setLineJoin(.round); g.strokePath()
        }
        if rBot < 0 {
            g.setStrokeColor(colR.withAlphaComponent(0.4).cgColor); g.setLineDash(phase: 0, lengths: [3, 3])
            g.move(to: CGPoint(x: pr.minX, y: yR(0))); g.addLine(to: CGPoint(x: pr.maxX, y: yR(0))); g.strokePath(); g.setLineDash(phase: 0, lengths: [])
        }
        if showD {
            stroke(ChartNSView.colDp, 1, lo: { yV(dpSum[$0] / Float(cnt[$0])) }, hi: { yV(dpSum[$0] / Float(cnt[$0])) })
            stroke(ChartNSView.colDm, 1, lo: { yV(dmSum[$0] / Float(cnt[$0])) }, hi: { yV(dmSum[$0] / Float(cnt[$0])) })
        }
        stroke(colR, 1.3, lo: { yR(rMin[$0]) }, hi: { yR(rMax[$0]) })
        stroke(ChartNSView.colV, 1.3, lo: { yV(vMin[$0]) }, hi: { yV(vMax[$0]) })
        g.restoreGState()

        // con trỏ
        if let hx = hoverX, hx >= pr.minX, hx <= pr.maxX, dragStart == nil {
            let th = t0 + Double((hx - pr.minX) / pr.width) * (t1 - t0)
            var k = ser.lowerBound(th)
            if k >= S.count { k = S.count - 1 }
            if k > 0, abs(S[k - 1].t - th) < abs(S[k].t - th) { k -= 1 }
            let x = S[k]
            if abs(x.t - th) <= max(gap, (t1 - t0) / Double(W) * 3) {
                let px = xT(x.t)
                g.setStrokeColor(NSColor.secondaryLabelColor.cgColor); g.setLineWidth(0.5)
                g.move(to: CGPoint(x: px, y: pr.minY)); g.addLine(to: CGPoint(x: px, y: pr.maxY)); g.strokePath()
                let r = power ? x.v * abs(x.a) : x.a
                for (y, c) in [(yV(x.v), ChartNSView.colV), (yR(r), colR)] {
                    g.setFillColor(c.cgColor); g.fillEllipse(in: CGRect(x: px - 3, y: y - 3, width: 6, height: 6))
                }
                let label = "\(ChartNSView.timeLabel(x.t, 0.01))   \(fmt(Double(x.v), 4)) V   \(fmt(Double(x.a), 4)) A   \(fmt(Double(x.v) * abs(Double(x.a)), 3)) W"
                let a = NSAttributedString(string: label, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
                let sz = a.size()
                var bx = px + 10; if bx + sz.width + 12 > pr.maxX { bx = px - sz.width - 22 }
                let box = NSRect(x: bx, y: pr.minY + 6, width: sz.width + 12, height: sz.height + 6)
                NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
                let bp = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5); bp.fill()
                NSColor.separatorColor.setStroke(); bp.stroke()
                a.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3))
            }
        }
    }

    private func timeAt(_ x: CGFloat) -> Double {
        guard let c = ctl?.chart else { return 0 }
        let pr = plot
        return c.t0 + Double((min(max(x, pr.minX), pr.maxX) - pr.minX) / pr.width) * (c.t1 - c.t0)
    }
    private func changed() { needsDisplay = true; ctl?.refreshStats() }

    override func mouseMoved(with e: NSEvent) { hoverX = convert(e.locationInWindow, from: nil).x; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hoverX = nil; needsDisplay = true }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { ctl?.chart.sel = nil; ctl?.viewMode = 0; changed(); return }
        dragStart = convert(e.locationInWindow, from: nil).x
    }
    override func mouseDragged(with e: NSEvent) {
        guard let s = dragStart, let ctl = ctl else { return }
        let x = convert(e.locationInWindow, from: nil).x
        if abs(x - s) >= 3 {
            if ctl.viewMode > 0 { ctl.viewMode = -1 }       // đứng yên khung nhìn để chọn vùng
            let a = timeAt(min(s, x)), b = timeAt(max(s, x))
            ctl.chart.sel = (a, b); changed()
        }
    }
    override func mouseUp(with e: NSEvent) {
        guard let s = dragStart else { return }
        dragStart = nil
        if abs(convert(e.locationInWindow, from: nil).x - s) < 3, e.clickCount == 1 { ctl?.chart.sel = nil }
        changed()
    }
    private func zoom(_ factor: Double, at x: CGFloat) {
        guard let ctl = ctl, let first = ctl.shown.s.first?.t, let last = ctl.shown.s.last?.t else { return }
        let c = ctl.chart, tc = timeAt(x)
        let total = max(1, last - first)
        let span = min(max((c.t1 - c.t0) * factor, 0.05), total * 1.2)
        let frac = (tc - c.t0) / (c.t1 - c.t0)
        c.t0 = tc - span * frac; c.t1 = c.t0 + span
        ctl.viewMode = -1; changed()
    }
    override func scrollWheel(with e: NSEvent) {
        guard let ctl = ctl, ctl.shown.s.count >= 2 else { return }
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        let precise = e.hasPreciseScrollingDeltas
        if abs(dy) >= abs(dx) {
            zoom(exp(-Double(dy) * (precise ? 0.01 : 0.12)), at: convert(e.locationInWindow, from: nil).x)
        } else {
            let c = ctl.chart
            let shift = -Double(dx) * (precise ? 1 : 10) / Double(plot.width) * (c.t1 - c.t0)
            c.t0 += shift; c.t1 += shift; ctl.viewMode = -1; changed()
        }
    }
    override func magnify(with e: NSEvent) { zoom(1 / (1 + Double(e.magnification)), at: convert(e.locationInWindow, from: nil).x) }
}

struct ChartView: NSViewRepresentable {
    @ObservedObject var ctl: MonCtl
    func makeNSView(context: Context) -> ChartNSView { let v = ChartNSView(); v.ctl = ctl; return v }
    func updateNSView(_ v: ChartNSView, context: Context) { _ = ctl.tick; v.needsDisplay = true }
}

// MARK: - Giao diện

extension View {
    func card() -> some View {
        self.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

struct Big: View {
    let value: String, unit: String, color: NSColor, sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit()).foregroundColor(Color(color))
                Text(unit).font(.system(size: 15, weight: .medium)).foregroundColor(Color(color))
            }
            Text(sub).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
        }
    }
}

struct Row: View {
    let k: String, v: String
    var body: some View {
        HStack { Text(k).foregroundColor(.secondary); Spacer(); Text(v).font(.system(size: 12).monospacedDigit()) }.font(.system(size: 12))
    }
}

struct SidePanel: View {
    @ObservedObject var ctl: MonCtl
    var body: some View {
        let r = ctl.reading
        ScrollView {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Big(value: r.map { fmt($0.v, 4) } ?? "–", unit: "V", color: ChartNSView.colV,
                        sub: L("min \(fmt(ctl.session.vMin, 3))  ·  max \(fmt(ctl.session.vMax, 3))", "thấp nhất \(fmt(ctl.session.vMin, 3))  ·  cao nhất \(fmt(ctl.session.vMax, 3))"))
                    Big(value: r.map { fmt(abs($0.a), 4) } ?? "–", unit: "A", color: ChartNSView.colA, sub: L("max \(fmt(ctl.session.aMax, 3))", "cao nhất \(fmt(ctl.session.aMax, 3))"))
                    Big(value: r.map { fmt($0.w, 3) } ?? "–", unit: "W", color: ChartNSView.colW, sub: L("max \(fmt(ctl.session.wMax, 3))", "cao nhất \(fmt(ctl.session.wMax, 3))"))
                }.card()
                VStack(spacing: 5) {
                    Row(k: "D+", v: r.map { fmt($0.dp, 3) + " V" } ?? "–")
                    Row(k: "D−", v: r.map { fmt($0.dm, 3) + " V" } ?? "–")
                    Row(k: "CC1", v: r.map { fmt($0.cc1, 1) + " V" } ?? "–")
                    Row(k: "CC2", v: r.map { fmt($0.cc2, 1) + " V" } ?? "–")
                    Row(k: L("Device temp", "Nhiệt độ máy"), v: r?.tempIn.map { fmt($0, 1) + " °C" } ?? "–")
                    Row(k: L("External probe", "Đầu dò ngoài"), v: r?.tempExt.map { fmt($0, 1) + " °C" } ?? L("not connected", "chưa cắm"))
                    Row(k: L("Uptime", "Đã bật"), v: r.map { clock(Double($0.upSeconds)) } ?? "–")
                }.card()
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(L("Device REC", "REC trong máy")).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(r.map { L("group \($0.group)", "nhóm \($0.group)") } ?? "").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Row(k: L("Capacity", "Dung lượng"), v: r.map { fmt($0.ah * 1000, 2) + " mAh" } ?? "–")
                    Row(k: L("Energy", "Năng lượng"), v: r.map { fmt($0.wh, 4) + " Wh" } ?? "–")
                    Row(k: L("Recording time", "Thời gian ghi"), v: r.map { clock(Double($0.recSeconds)) } ?? "–")
                    Row(k: L("Threshold", "Ngưỡng ghi"), v: r.map { "> \($0.thresholdmA) mA" } ?? "–")
                    if let r = r, r.recSeconds > 0, r.ah > 0 {
                        Divider()
                        Row(k: L("Average", "Trung bình"), v: "\(fmt(r.wh / r.ah, 2)) V · \(fmt(r.ah * 3600 / Double(r.recSeconds), 3)) A")
                        Row(k: "", v: "\(fmt(r.wh * 3600 / Double(r.recSeconds), 2)) W")
                    }
                    Text(L("Press BACK on the K2 to switch groups.", "Bấm BACK trên K2 để đổi nhóm.")).font(.system(size: 10)).foregroundColor(.secondary)
                }.card()
            }.padding(10)
        }.frame(width: 250)
    }
}

struct Chip: View {
    let title: String, on: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.85) : Color(NSColor.controlColor)))
                .foregroundColor(on ? .white : .primary)
        }.buttonStyle(PlainButtonStyle())
    }
}

struct StatCell: View {
    let k: String, v: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 10)).foregroundColor(.secondary)
            Text(v).font(.system(size: 12, weight: .medium).monospacedDigit())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChartTab: View {
    @ObservedObject var ctl: MonCtl
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(L("View", "Xem")).font(.system(size: 11)).foregroundColor(.secondary)
                Chip(title: L("All", "Toàn bộ"), on: ctl.viewMode == 0) { ctl.viewMode = 0; ctl.tick += 1 }
                ForEach([(10, L("10 s", "10 giây")), (60, L("1 min", "1 phút")), (600, L("10 min", "10 phút"))], id: \.0) { m in
                    Chip(title: m.1, on: ctl.viewMode == m.0) { ctl.viewMode = m.0; ctl.tick += 1 }
                }
                Divider().frame(height: 14)
                Chip(title: L("Current (A)", "Dòng (A)"), on: !ctl.rightIsPower) { ctl.rightIsPower = false }
                Chip(title: L("Power (W)", "Công suất (W)"), on: ctl.rightIsPower) { ctl.rightIsPower = true }
                Chip(title: "D+ / D−", on: ctl.showD) { ctl.showD.toggle() }
                Spacer()
                Text(L("Scroll: zoom · drag: select · double-click: all", "Cuộn: phóng to · kéo: chọn vùng · nhấp đôi: toàn bộ")).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }.padding(.horizontal, 10).padding(.vertical, 7)
            ChartView(ctl: ctl).frame(minHeight: 240)
            Divider()
            HStack(spacing: 8) {
                if let s = ctl.stats {
                    StatCell(k: s.selected ? L("Selection", "Vùng chọn") : L("Visible range", "Vùng đang xem"), v: clock(s.hi - s.lo) + String(format: L(" (%d samples)", " (%d mẫu)"), s.count))
                    StatCell(k: L("V min / avg / max", "V thấp / TB / cao"), v: "\(fmt(s.vMin, 3)) / \(fmt(s.vAvg, 3)) / \(fmt(s.vMax, 3))")
                    StatCell(k: L("A min / avg / max", "A thấp / TB / cao"), v: "\(fmt(s.aMin, 3)) / \(fmt(s.aAvg, 3)) / \(fmt(s.aMax, 3))")
                    StatCell(k: L("W avg / max", "W TB / cao"), v: "\(fmt(s.wAvg, 2)) / \(fmt(s.wMax, 2))")
                    StatCell(k: L("Capacity", "Dung lượng"), v: fmt(s.ah * 1000, 2) + " mAh")
                    StatCell(k: L("Energy", "Năng lượng"), v: fmt(s.wh, 4) + " Wh")
                    if s.selected { Button(L("Clear selection", "Bỏ chọn")) { ctl.chart.sel = nil; ctl.tick += 1; ctl.refreshStats() }.controlSize(.small) }
                } else {
                    Text(L("No data for statistics yet", "Chưa có dữ liệu để thống kê")).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

struct PDTab: View {
    @ObservedObject var ctl: MonCtl
    @State private var follow = true
    static let colors: [Color] = [.primary, Color(NSColor.systemBlue), Color(NSColor.systemOrange), Color(NSColor.systemGreen), Color(NSColor.systemRed), .secondary, Color(NSColor.systemPurple)]
    var rows: [PDMsg] { ctl.hideGoodCRC ? ctl.pd.filter { $0.kind != 5 } : ctl.pd }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L("\(ctl.pd.count) packets", "\(ctl.pd.count) gói")).font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
                Chip(title: L("Hide GoodCRC", "Ẩn GoodCRC"), on: ctl.hideGoodCRC) { ctl.hideGoodCRC.toggle() }
                Chip(title: L("Auto-scroll", "Tự cuộn"), on: follow) { follow.toggle() }
                Spacer()
                Button(L("Open…", "Mở…")) { ctl.openPanel() }.controlSize(.small)
                Button(L("Save capture…", "Lưu bản bắt…")) { ctl.savePD() }.controlSize(.small).disabled(ctl.pd.isEmpty)
                Button(L("Clear", "Xoá")) { ctl.clearPD() }.controlSize(.small).disabled(ctl.pd.isEmpty)
            }.padding(.horizontal, 10).padding(.vertical, 7)
            if !ctl.decoder.srcCaps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Source capabilities", "Khả năng của nguồn")).font(.system(size: 11, weight: .semibold))
                    ForEach(Array(ctl.decoder.srcCaps.enumerated()).filter { $0.element != 0 }, id: \.offset) { i, p in
                        Text("\(i + 1).  \(PDDecoder.pdoText(p))").font(.system(size: 12).monospacedDigit())
                    }
                    if !ctl.decoder.contract.isEmpty { Text(L("Contract: \(ctl.decoder.contract)", "Đang cấp: \(ctl.decoder.contract)")).font(.system(size: 12, weight: .medium)).foregroundColor(Color(NSColor.systemGreen)) }
                    else if !ctl.decoder.lastRequest.isEmpty { Text(L("Requesting: \(ctl.decoder.lastRequest)", "Đang yêu cầu: \(ctl.decoder.lastRequest)")).font(.system(size: 12)).foregroundColor(Color(NSColor.systemOrange)) }
                }.card().padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            if ctl.pd.isEmpty {
                VStack(spacing: 8) {
                    Text(L("No PD packets captured yet", "Chưa bắt được gói PD nào")).font(.system(size: 14, weight: .medium))
                    Text(L("The K2 only sends PD packets once the PD link to the computer (PD 联机) is enabled in the device settings — the vendor says firmware 4.6 or later is required — and a charger and a device must be negotiating PD through the K2. The app only sees packets generated after the K2 is connected to the Mac.", "K2 chỉ gửi gói PD khi đã bật mục kết nối PD với máy tính (PD 联机) trong cài đặt của máy — hãng ghi cần firmware 4.6 trở lên — và phải có sạc cùng thiết bị đang đàm phán PD đi qua K2. App chỉ thấy các gói phát sinh sau khi đã cắm vào Mac."))
                        .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { m in
                                HStack(spacing: 8) {
                                    Text(fmt(m.t, 3)).frame(width: 72, alignment: .trailing).foregroundColor(.secondary)
                                    Text(m.sop).frame(width: 62, alignment: .leading)
                                    Text(m.from).frame(width: 58, alignment: .leading).foregroundColor(.secondary)
                                    Text(m.name).frame(width: 190, alignment: .leading).foregroundColor(PDTab.colors[m.kind])
                                    Text(m.summary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 11.5).monospacedDigit()).padding(.horizontal, 10).padding(.vertical, 3)
                                .background(ctl.pdSel == m.id ? Color.accentColor.opacity(0.22) : Color.clear)
                                .contentShape(Rectangle()).onTapGesture { ctl.pdSel = m.id; follow = false }
                                .id(m.id)
                            }
                        }
                    }
                    .onChange(of: ctl.pd.count) { _ in if follow, let l = rows.last { proxy.scrollTo(l.id, anchor: .bottom) } }
                }
                if let m = ctl.pd.first(where: { $0.id == ctl.pdSel }) {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(m.sop) · \(m.name)" + (m.from.isEmpty ? "" : L(" · from \(m.from)", " · từ \(m.from)"))).font(.system(size: 12, weight: .semibold))
                            if !m.summary.isEmpty { Text(m.summary).font(.system(size: 12)) }
                            ForEach(Array(m.detail.enumerated()), id: \.offset) { _, line in Text(line).font(.system(size: 11.5, design: .monospaced)) }
                            Text(L("Message: ", "Bản tin: ") + hex(m.raw)).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                        }.selectable().frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }.frame(height: 150)
                }
            }
        }
    }
}

struct MonitorView: View {
    @ObservedObject var ctl: MonCtl
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(ctl.connected ? Color(NSColor.systemGreen) : Color(NSColor.systemGray)).frame(width: 9, height: 9)
                if ctl.connected {
                    Text(ctl.devName + (ctl.serial.isEmpty ? "" : " · SN \(ctl.serial)")).font(.system(size: 13, weight: .semibold))
                    Text(L("\(ctl.pps) packets/s", "\(ctl.pps) gói/giây")).font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
                } else {
                    Text(L("No K2 in normal mode found", "Chưa thấy K2 ở chế độ thường")).font(.system(size: 13, weight: .semibold))
                    Text(L("connect a K2 in normal mode through its USB HID port", "cắm K2 ở chế độ thường vào cổng USB HID")).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Picker("", selection: $ctl.tab) { Text(L("Chart", "Đồ thị")).tag(0); Text("USB PD\(ctl.pd.isEmpty ? "" : " (\(ctl.pd.count))")").tag(1) }
                    .pickerStyle(SegmentedPickerStyle()).labelsHidden().frame(width: 220)
                Spacer()
                Picker("", selection: $ctl.rate) { Text(L("100 samples/s", "100 mẫu/giây")).tag(100); Text(L("10 samples/s", "10 mẫu/giây")).tag(10); Text(L("1 sample/s", "1 mẫu/giây")).tag(1) }
                    .labelsHidden().frame(width: 130).help(L("Rate recorded to the chart. The K2 always sends 100 samples per second.", "Tốc độ ghi vào đồ thị. K2 luôn gửi 100 mẫu mỗi giây."))
                Button(ctl.paused ? L("Resume", "Tiếp tục") : L("Pause", "Tạm dừng")) { ctl.paused.toggle() }
                Button(L("Clear", "Xoá")) { ctl.clearLive() }.help(L("Clear the live chart and start again from 0", "Xoá đồ thị trực tiếp và bắt đầu lại từ 0"))
                Button(L("Open…", "Mở…")) { ctl.openPanel() }
                Button(L("Save CSV…", "Lưu CSV…")) { ctl.saveCSV() }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if ctl.file != nil || !ctl.note.isEmpty {
                HStack(spacing: 8) {
                    if ctl.busy { ProgressView().scaleEffect(0.5).frame(width: 16, height: 16) }
                    Text(ctl.note).font(.system(size: 11.5)).lineLimit(1)
                    Spacer()
                    if ctl.file != nil { Button(L("Back to live chart", "Về đồ thị trực tiếp")) { ctl.closeFile() }.controlSize(.small) }
                    else { Button(L("Hide", "Ẩn")) { ctl.note = "" }.controlSize(.small) }
                }.padding(.horizontal, 12).padding(.vertical, 5).background(Color.accentColor.opacity(0.12))
                Divider()
            }
            HStack(spacing: 0) {
                SidePanel(ctl: ctl)
                Divider()
                if ctl.tab == 0 { ChartTab(ctl: ctl) } else { PDTab(ctl: ctl) }
            }
        }
        .frame(minWidth: 980, minHeight: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let d = item as? Data, let url = URL(dataRepresentation: d, relativeTo: nil) else { return }
                DispatchQueue.main.async { ctl.openFile(url) }
            }
            return true
        }
    }
}

// MARK: - Tự kiểm tra (không cần thiết bị)

func monitorSelfTest() -> Int32 {
    var fails = 0
    func check(_ name: String, _ ok: Bool, _ info: String = "") { print(ok ? "✔ \(name)" : "✖ \(name)  \(info)"); if !ok { fails += 1 } }
    func bytes(_ h: String) -> [UInt8] { var out: [UInt8] = []; let c = Array(h); var i = 0; while i + 1 < c.count { out.append(UInt8(String(c[i...i + 1]), radix: 16)!); i += 2 }; return out }

    // gói thật thu từ K2 (firmware đang dùng, 2026-11-10)
    let real = bytes("ff550608e1434c541a34000050000797fc3c5abb1a3ecc00000006000000eb8d303fc7f10f3f0000c8410000c8c22e3f0a3d00000000001f1e08a5060020f71d")
    if let r = parseTelemetry(real) {
        check("gói thật: REC", abs(r.ah - 0.03083) < 1e-4 && abs(r.wh - 0.15111) < 1e-4 && r.recSeconds == 204 && r.group == 1 && r.thresholdmA == 80, "\(r)")
        check("gói thật: số đo", abs(r.v - 0.03375) < 1e-4 && r.a == 0 && r.cc1 == 3.1 && r.cc2 == 3.0 && r.tempIn == 25 && r.tempExt == nil, "\(r)")
    } else { check("gói thật: checksum và header", false) }
    var bad = real; bad[46] ^= 1
    check("gói hỏng bị loại", parseTelemetry(bad) == nil)
    var r0 = Reading(); r0.v = 20.05; r0.a = -1.5; r0.ah = 1.25; r0.wh = 24; r0.recSeconds = 3600; r0.tempExt = 31.5; r0.cc1 = 1.7; r0.group = 2; r0.thresholdmA = 80
    let back = parseTelemetry(buildTelemetry(r0, tick: 7))
    check("tạo rồi đọc lại gói", back != nil && abs(back!.v - 20.05) < 1e-4 && back!.a == -1.5 && back!.group == 2 && back!.tempExt == 31.5 && back!.tempIn == nil)

    // PD
    let dec = PDDecoder()
    var m1 = PDMsg(id: 1, t: 0, wall: Date(), frame: DemoSource.script[0].1); dec.decode(&m1)
    check("PD Source_Capabilities", m1.name == "Source_Capabilities" && m1.sop == "SOP" && m1.from == "Nguồn" && dec.srcCaps.count == 5
          && m1.summary.contains("Fixed 9V 3A (27W)") && m1.summary.contains("Fixed 20V 5A (100W)") && m1.summary.contains("PPS 3.3–21V 5A"), m1.summary)
    var m2 = PDMsg(id: 2, t: 0, wall: Date(), frame: DemoSource.script[2].1); dec.decode(&m2)
    check("PD Request", m2.name == "Request" && m2.from == "Thiết bị" && m2.summary.contains("PDO #2: 9V, dùng 3A"), m2.summary)
    var m3 = PDMsg(id: 3, t: 0, wall: Date(), frame: DemoSource.script[1].1); dec.decode(&m3)
    var m4 = PDMsg(id: 4, t: 0, wall: Date(), frame: DemoSource.script[5].1); dec.decode(&m4)
    check("PD GoodCRC / PS_RDY", m3.name == "GoodCRC" && m3.kind == 5 && m4.name == "PS_RDY" && dec.contract.contains("9V"), "\(m3.name) \(m4.name) \(dec.contract)")
    // yêu cầu PPS 8V 3.45A ở PDO #5
    let pps: UInt32 = 5 << 28 | (400 << 9) | 69
    var m5 = PDMsg(id: 5, t: 0, wall: Date(), frame: DemoSource.pdFrame(sop: 224, DemoSource.msg(type: 2, source: false, id: 2, [pps]))); dec.decode(&m5)
    check("PD Request PPS", m5.summary.contains("PPS 8V 3.45A"), m5.summary)
    // vector thử của laPower: A1 11 2C 91 01 08 = Source_Capabilities 1 PDO 5V 3A
    var m6 = PDMsg(id: 6, t: 0, wall: Date(), frame: DemoSource.pdFrame(sop: 224, [0xA1, 0x11, 0x2C, 0x91, 0x01, 0x08])); PDDecoder().decode(&m6)
    check("PD vector tham chiếu", m6.name == "Source_Capabilities" && m6.summary.contains("Fixed 5V 3A"), m6.summary)
    var m7 = PDMsg(id: 7, t: 0, wall: Date(), frame: DemoSource.pdFrame(sop: 64, [])); dec.decode(&m7)
    check("PD Hard Reset", m7.name == "Hard Reset" && m7.kind == 4)
    // EPR_Source_Capabilities chia 2 chunk: 7 PDO SPR + 1 EPR 28V 5A = 32 byte
    var objs = DemoSource.caps + [0, 0]; objs.append((560 << 10) | 500)
    var data: [UInt8] = []; for o in objs { for i in 0..<4 { data.append(UInt8((o >> (8 * UInt32(i))) & 0xff)) } }
    func extFrame(_ chunk: Int, _ part: [UInt8]) -> [UInt8] {
        var body = part; while (body.count + 2) % 4 != 0 { body.append(0) }
        let n = (body.count + 2) / 4
        let h = UInt32(17) | (1 << 5) | (2 << 6) | (1 << 8) | UInt32(n) << 12 | (1 << 15)
        let eh = UInt32(data.count) | UInt32(chunk) << 11 | (1 << 15)
        return DemoSource.pdFrame(sop: 224, [UInt8(h & 0xff), UInt8(h >> 8), UInt8(eh & 0xff), UInt8(eh >> 8)] + body)
    }
    let d2 = PDDecoder()
    var e1 = PDMsg(id: 8, t: 0, wall: Date(), frame: extFrame(0, Array(data[0..<26]))); d2.decode(&e1)
    var e2 = PDMsg(id: 9, t: 0, wall: Date(), frame: extFrame(1, Array(data[26...]))); d2.decode(&e2)
    check("PD EPR chia chunk", e1.summary.contains("26/32") && e2.name == "EPR_Source_Capabilities" && e2.summary.contains("Fixed 28V 5A (140W)") && d2.srcCaps.count == 8, "\(e1.summary) | \(e2.summary)")

    // thống kê: 5 V, 1 A trong 1 giờ = 1000 mAh, 5 Wh
    let ser = Series()
    for i in 0...360_000 { ser.add(Sample(t: Double(i) / 100, v: 5, a: 1, dp: 0.6, dm: 0.6, temp: 25, cc1: 17, cc2: 0)) }
    let st = computeStats(ser, 0, 3600)
    check("tích phân dung lượng", st != nil && abs(st!.ah - 1) < 1e-6 && abs(st!.wh - 5) < 1e-5 && st!.count == 360_001, "\(String(describing: st))")
    let half = computeStats(ser, 900, 2700)
    check("thống kê theo vùng", half != nil && abs(half!.ah - 0.5) < 1e-4)
    let rc = MonCtl(source: DemoSource(prefill: 0)); var neg = Reading(); neg.v = 5; neg.a = -1
    _ = rc; let negBack = parseTelemetry(buildTelemetry(neg, tick: 1))
    check("dòng âm từ K2 vẫn đọc được", negBack != nil && negBack!.a == -1 && negBack!.w == 5)

    // CSV: ghi rồi đọc lại, và file 4 cột kiểu phần mềm WITRN
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("witrn-monitor-selftest-\(getpid()).csv")
    let small = Series(); small.device = "TEST"
    for i in 0..<500 { small.add(Sample(t: Double(i) / 100, v: 9 + Float(i) / 1000, a: -0.5, dp: 0.6, dm: 2.7, temp: i < 10 ? .nan : 30.5, cc1: 17, cc2: 4)) }
    do {
        try CSV.write(small, lo: nil, hi: nil, to: tmp)
        let b = try CSV.read(tmp)
        check("CSV ghi/đọc", b.s.count == 500 && abs(b.s[499].v - 9.499) < 1e-4 && b.s[499].a == 0.5 && b.s[0].temp.isNaN && b.s[499].temp == 30.5 && b.s[499].cc2 == 4 && b.device == "TEST" && abs(b.s[499].t - 4.99) < 1e-6)
        let official = "\u{feff}SUM,3,\r\nTotalTime,00:00:00.020,\r\nSampTime(ms),10,\r\nDateTime,2026/10/16 22:36:50,\r\nTime(D.hh:mm:ss.ms),Voltage(V),Current(A),Power(W),\r\n=\"00:00:00.000\",5.0123,1.0000,5.0123,\r\n=\"00:00:00.010\",5.0100,1.1000,5.5110,\r\n=\"1.00:00:01.500\",5.0000,1.2000,6.0000,\r\n"
        try official.data(using: .utf8)!.write(to: tmp)
        let o = try CSV.read(tmp)
        check("CSV 4 cột của WITRN", o.s.count == 3 && abs(o.s[1].t - 0.01) < 1e-9 && abs(o.s[1].a - 1.1) < 1e-6 && abs(o.s[2].t - 86401.5) < 1e-6, "\(o.s.count)")
    } catch { check("CSV", false, "\(error)") }
    try? FileManager.default.removeItem(at: tmp)

    // file bắt PD
    let line = "{\"t\":4.000,\"unix\":1794300000.500,\"hex\":\"" + DemoSource.script[0].1.map { String(format: "%02x", $0) }.joined() + "\"}"
    let parsed = MonCtl.parsePDFile("{\"format\":\"x\"}\n" + line + "\n")
    check("file bắt PD", parsed.count == 1 && parsed[0].0 == 4 && parsed[0].2 == DemoSource.script[0].1)

    // toàn tuyến với nguồn giả lập
    let c = MonCtl(source: DemoSource(prefill: 60)); c.source.start(); c.pump()
    check("luồng giả lập → đồ thị + PD", c.connected && c.live.s.count >= 5990 && c.pd.count == 9 && c.decoder.contract.contains("20V") && c.reading != nil,
          "mẫu \(c.live.s.count), pd \(c.pd.count), \(c.decoder.contract)")
    // đầy bộ nhớ thì tự thưa mẫu
    let big = Series(); for i in 0..<(K.maxSamples + 10) { big.add(Sample(t: Double(i), v: 1, a: 1, dp: 0, dm: 0, temp: 0, cc1: 0, cc2: 0)) }
    check("tự thưa mẫu khi đầy", big.every == 2 && big.s.count < K.maxSamples / 2 + 20 && big.s.last!.t > Double(K.maxSamples) - 5)
    print(fails == 0 ? "TẤT CẢ ĐẠT" : "\(fails) MỤC LỖI")
    return fails == 0 ? 0 : 1
}

// ============================ TUỲ BIẾN K2 (mặt đồng hồ, hình nền, hình khởi động) ============================
// Định dạng và địa chỉ theo tài liệu WITRN-K2-REVERSE (phân tích tĩnh công cụ K2Picture 1.1 của hãng),
// đã đối chiếu với các gói mặt đồng hồ hãng phát hành (.k2pic 400 byte + .bmp 240×240).

struct K2Res: Equatable {
    let kind: String
    let address: UInt32, size: Int, sectors: Int, dimension: Int
    var allocation: Int { sectors * 2048 }
    var title: String {
        switch kind {
        case "background": return L("background image", "hình nền")
        case "layout": return L("watch face parameters", "thông số mặt đồng hồ")
        default: return L("boot image", "hình khởi động")
        }
    }

    static let background = K2Res(kind: "background", address: 0x080C_6800, size: 115_208, sectors: 57, dimension: 240)
    static let layout = K2Res(kind: "layout", address: 0x080E_4000, size: 400, sectors: 1, dimension: 0)
    static let boot = K2Res(kind: "boot", address: 0x080E_4800, size: 110_458, sectors: 54, dimension: 235)
    static let all = [background, layout, boot]
    static let magic: [UInt8] = [0x5A, 0xA5, 0x5A, 0xA5]

    /// Kiểm tra dữ liệu trước khi ghi: đúng độ dài, đúng dấu đầu/cuối, thông số nằm trong phạm vi công cụ hãng cho phép.
    func validate(_ d: [UInt8]) throws {
        guard d.count == size else { throw WError(L("The \(title) data is \(d.count) bytes, expected \(size)", "Dữ liệu \(title) dài \(d.count) byte, cần \(size)")) }
        guard Array(d[0..<4]) == K2Res.magic, Array(d[(size - 4)...]) == K2Res.magic else { throw WError(L("Missing start/end marker in the \(title)", "Thiếu dấu đầu/cuối của \(title)")) }
        guard self == K2Res.layout else { return }
        for e in Dial.elements {
            let o = 4 + e.index * 10
            guard d[o + 8] <= 1 else { throw WError(L("\(e.name): invalid visibility switch", "\(e.name): công tắc hiển thị không hợp lệ")) }
            if d[o + 8] == 1, e.hasFont, d[o + 9] >= Dial.fonts.count { throw WError(L("\(e.name): invalid font size", "\(e.name): cỡ chữ không hợp lệ")) }
            if d[o + 8] == 1, let p = e.precision, !(p.lo...p.hi).contains(Int(d[224 + p.slot])) {
                throw WError(L("\(e.name): digits must be between \(p.lo) and \(p.hi)", "\(e.name): số chữ số phải từ \(p.lo) đến \(p.hi)"))
            }
        }
    }

    /// Bọc điểm ảnh RGB565 thành khối tài nguyên: dấu + điểm ảnh little-endian theo hàng + dấu.
    func wrap(_ px: [UInt16]) -> [UInt8] {
        var out = K2Res.magic; out.reserveCapacity(size)
        for p in px { out.append(UInt8(p & 0xff)); out.append(UInt8(p >> 8)) }
        return out + K2Res.magic
    }
    func pixels(_ d: [UInt8]) -> [UInt16]? {
        guard dimension > 0, d.count >= size, Array(d[0..<4]) == K2Res.magic, Array(d[(size - 4)..<size]) == K2Res.magic else { return nil }
        return (0..<dimension * dimension).map { UInt16(d[4 + $0 * 2]) | UInt16(d[5 + $0 * 2]) << 8 }
    }
}

enum Dial {
    struct Element { let index: Int, name: String, sample: String, hasFont: Bool, precision: (slot: Int, lo: Int, hi: Int)? }
    static let fonts = ["S7", "M12", "D15", "D18", "D28", "Bh36", "D36"]
    static let fontHeights: [CGFloat] = [11, 16, 21, 27, 40, 46, 58]
    static var elements: [Element] { [      // tính lại mỗi lần để tên mục theo ngôn ngữ đang chọn
        Element(index: 0, name: L("Voltage", "Điện áp"), sample: "5", hasFont: true, precision: (0, 2, 7)),
        Element(index: 1, name: L("Current", "Dòng"), sample: "2", hasFont: true, precision: (1, 2, 7)),
        Element(index: 2, name: L("Power", "Công suất"), sample: "10", hasFont: true, precision: (2, 3, 7)),
        Element(index: 15, name: "Wh", sample: "72", hasFont: true, precision: (7, 3, 7)),
        Element(index: 4, name: "D+", sample: "0", hasFont: true, precision: (3, 2, 3)),
        Element(index: 5, name: "D−", sample: "0", hasFont: true, precision: (4, 2, 3)),
        Element(index: 9, name: "CC1", sample: "1", hasFont: true, precision: (5, 2, 3)),
        Element(index: 10, name: "CC2", sample: "0", hasFont: true, precision: (6, 2, 3)),
        Element(index: 3, name: L("Time", "Thời gian"), sample: "00:00:00", hasFont: true, precision: nil),
        Element(index: 16, name: L("PD name", "Tên PD"), sample: "PD3.0", hasFont: true, precision: nil),
        Element(index: 7, name: L("PD info", "Thông tin PD"), sample: "20V 3.25A", hasFont: true, precision: nil),
        Element(index: 8, name: L("QC info", "Thông tin QC"), sample: "QC3.0", hasFont: true, precision: nil),
        Element(index: 11, name: L("Version", "Phiên bản"), sample: "V6.0", hasFont: true, precision: nil),
        Element(index: 12, name: L("Refresh rate", "Tốc độ làm mới"), sample: "3", hasFont: true, precision: nil),
        Element(index: 6, name: L("Temperature", "Nhiệt độ"), sample: "25.0", hasFont: true, precision: nil),
        Element(index: 14, name: L("Rotation icon", "Biểu tượng xoay"), sample: "⟳", hasFont: false, precision: nil),
        Element(index: 13, name: L("Direction arrow", "Mũi tên chiều dòng"), sample: "➔", hasFont: false, precision: nil),
    ] }

    /// Bố cục mặc định: ba hàng số lớn V / A / W, thời gian và thông tin giao thức ở dưới.
    static var defaultLayout: [UInt8] {
        var d = [UInt8](repeating: 0, count: 400)
        d.replaceSubrange(0..<4, with: K2Res.magic); d.replaceSubrange(396..<400, with: K2Res.magic)
        func set(_ i: Int, _ color: UInt32, _ x: Int, _ y: Int, _ on: Bool, _ font: Int) {
            let o = 4 + i * 10
            d.replaceSubrange(o..<o + 4, with: bytes32(color))
            d[o + 4] = UInt8(x & 0xff); d[o + 5] = UInt8((x >> 8) & 0xff); d[o + 6] = UInt8(y & 0xff); d[o + 7] = UInt8((y >> 8) & 0xff)
            d[o + 8] = on ? 1 : 0; d[o + 9] = UInt8(font)
        }
        let white: UInt32 = 0xFFFF_FFFF
        set(0, 0xFF34_C759, 4, 8, true, 5); set(1, 0xFF0A_84FF, 4, 60, true, 5); set(2, 0xFFFF_9F0A, 4, 112, true, 5)
        set(3, white, 132, 218, true, 1); set(4, white, 8, 196, false, 1); set(5, white, 90, 196, false, 1)
        set(6, white, 170, 196, false, 1); set(7, white, 60, 170, true, 1); set(8, white, 150, 170, false, 1)
        set(9, white, 8, 218, false, 1); set(10, white, 70, 218, false, 1); set(11, 0xFFAA_AAAA, 205, 4, false, 0)
        set(12, white, 110, 218, false, 0); set(13, white, 212, 60, true, 0); set(14, white, 212, 112, false, 0)
        set(15, white, 8, 196, true, 1); set(16, white, 8, 170, true, 1)
        d.replaceSubrange(224..<232, with: [6, 6, 6, 3, 3, 2, 2, 6])
        return d
    }
    static func sampleText(_ e: Element, digits: Int) -> String {
        guard e.precision != nil else { return e.sample }
        let dec = max(0, digits - e.sample.count)
        return dec > 0 ? e.sample + "." + String(repeating: "0", count: dec) : e.sample
    }
}

enum Pix {
    static func to565(r: UInt8, g: UInt8, b: UInt8) -> UInt16 { UInt16(r >> 3) << 11 | UInt16(g >> 2) << 5 | UInt16(b >> 3) }

    /// BMP không nén 24/32 bit đọc trực tiếp (bỏ qua kênh alpha, nhiều file 32 bit để alpha = 0); định dạng khác nhờ macOS giải mã.
    static func decode(_ data: [UInt8]) -> (w: Int, h: Int, rgba: [UInt8])? {
        if data.count > 54, data[0] == 0x42, data[1] == 0x4D {
            let off = Int(le32(data, 10)), w = Int(Int32(bitPattern: le32(data, 18))), hRaw = Int(Int32(bitPattern: le32(data, 22)))
            let bpp = Int(data[28]) | Int(data[29]) << 8, comp = le32(data, 30)
            let h = abs(hRaw), stride = (w * bpp / 8 + 3) & ~3
            if (bpp == 24 || bpp == 32), (comp == 0 || comp == 3), w > 0, h > 0, w <= 4096, h <= 4096, off + stride * h <= data.count {
                var out = [UInt8](repeating: 255, count: w * h * 4)
                for y in 0..<h {
                    let row = off + (hRaw > 0 ? h - 1 - y : y) * stride
                    for x in 0..<w {
                        let s = row + x * (bpp / 8), d = (y * w + x) * 4
                        out[d] = data[s + 2]; out[d + 1] = data[s + 1]; out[d + 2] = data[s]
                    }
                }
                return (w, h, out)
            }
        }
        guard let src = CGImageSourceCreateWithData(Data(data) as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0, w <= 8192, h <= 8192 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        return ok ? (w, h, out) : nil
    }
    static func cgImage(w: Int, h: Int, rgba: [UInt8]) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    /// Ảnh bất kỳ → n×n RGB565: đúng cỡ thì giữ nguyên từng điểm ảnh, khác cỡ thì phóng cho kín khung và cắt giữa.
    static func fit(_ data: [UInt8], _ n: Int) -> [UInt16]? {
        guard var img = decode(data) else { return nil }
        if img.w != n || img.h != n {
            guard let src = cgImage(w: img.w, h: img.h, rgba: img.rgba) else { return nil }
            var out = [UInt8](repeating: 0, count: n * n * 4)
            let scale = max(CGFloat(n) / CGFloat(img.w), CGFloat(n) / CGFloat(img.h))
            let dw = CGFloat(img.w) * scale, dh = CGFloat(img.h) * scale
            let ok = out.withUnsafeMutableBytes { p -> Bool in
                guard let ctx = CGContext(data: p.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(src, in: CGRect(x: (CGFloat(n) - dw) / 2, y: (CGFloat(n) - dh) / 2, width: dw, height: dh)); return true
            }
            guard ok else { return nil }
            img = (n, n, out)
        }
        return (0..<n * n).map { to565(r: img.rgba[$0 * 4], g: img.rgba[$0 * 4 + 1], b: img.rgba[$0 * 4 + 2]) }
    }
    static func image(_ px: [UInt16], _ n: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: n * n * 4)
        for (i, p) in px.enumerated() where i < n * n {
            let r = UInt8(p >> 11), g = UInt8((p >> 5) & 0x3f), b = UInt8(p & 0x1f)
            rgba[i * 4] = r << 3 | r >> 2; rgba[i * 4 + 1] = g << 2 | g >> 4; rgba[i * 4 + 2] = b << 3 | b >> 2
        }
        return cgImage(w: n, h: n, rgba: rgba)
    }
    static func bmp(_ px: [UInt16], _ n: Int) -> [UInt8] {
        let stride = (n * 3 + 3) & ~3, size = 54 + stride * n
        var out = [UInt8](repeating: 0, count: size)
        out[0] = 0x42; out[1] = 0x4D
        out.replaceSubrange(2..<6, with: bytes32(UInt32(size))); out.replaceSubrange(10..<14, with: bytes32(54)); out.replaceSubrange(14..<18, with: bytes32(40))
        out.replaceSubrange(18..<22, with: bytes32(UInt32(n))); out.replaceSubrange(22..<26, with: bytes32(UInt32(n)))
        out[26] = 1; out[28] = 24
        out.replaceSubrange(34..<38, with: bytes32(UInt32(stride * n)))
        for y in 0..<n { for x in 0..<n {
            let p = px[y * n + x], r = UInt8(p >> 11), g = UInt8((p >> 5) & 0x3f), b = UInt8(p & 0x1f)
            let o = 54 + (n - 1 - y) * stride + x * 3
            out[o] = b << 3 | b >> 2; out[o + 1] = g << 2 | g >> 4; out[o + 2] = r << 3 | r >> 2
        } }
        return out
    }
}

extension Updater {
    enum ResPhase { case backup, erase, write, verify }

    static func readRegion(_ dfu: Dfu, _ address: UInt32, _ size: Int, tick: (Int) -> Void) throws -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(size)
        while out.count < size {
            let n = min(1024, size - out.count)
            out += try dfu.read(address + UInt32(out.count), n)
            tick(out.count)
        }
        return out
    }

    /// Ghi một vùng tài nguyên của K2. Đọc toàn bộ vùng hai lần và giao bản sao lưu cho `backup` TRƯỚC khi xoá;
    /// giữ nguyên phần đuôi sau dữ liệu; đọc lại so từng byte rồi mới kết thúc phiên (lệnh 23).
    static func writeResource(_ dfu: Dfu, _ res: K2Res, image payload: [UInt8], raw: Bool = false,
                              backup: ([UInt8]) throws -> Void, progress: (ResPhase, Int, Int) -> Void) throws {
        if raw { guard payload.count == res.allocation else { throw WError(L("A \(res.title) backup must be exactly \(res.allocation) bytes", "Bản sao lưu \(res.title) phải dài đúng \(res.allocation) byte")) } }
        else { try res.validate(payload) }
        let total = res.allocation
        let first = try readRegion(dfu, res.address, total) { progress(.backup, $0 / 2, total) }
        let second = try readRegion(dfu, res.address, total) { progress(.backup, total / 2 + $0 / 2, total) }
        guard first == second else { throw WError(L("Two reads of the \(res.title) area returned different data; stopped, nothing erased.", "Hai lần đọc vùng \(res.title) cho kết quả khác nhau; dừng, chưa xoá gì.")) }
        try backup(first)
        var image = first
        image.replaceSubrange(0..<payload.count, with: payload)

        try dfu.command(22)
        try dfu.command(5)
        for i in 0..<res.sectors { try dfu.erase(res.address + UInt32(i * 2048)); progress(.erase, i + 1, res.sectors) }
        try dfu.command(4)
        try dfu.command(5)
        var off = 0
        while off < total {
            let end = min(off + 1024, total)
            try dfu.write(res.address + UInt32(off), image[off..<end])
            progress(.write, end, total); off = end
        }
        try dfu.command(4)
        let back = try readRegion(dfu, res.address, total) { progress(.verify, $0, total) }
        guard back == image else {
            let at = zip(back, image).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? 0
            throw WError(String(format: L("Read-back data differs at 0x%08X", "Dữ liệu đọc lại khác tại 0x%08X"), res.address + UInt32(at)))
        }
        try dfu.command(23)
    }
}

final class Customizer: ObservableObject {
    @Published var layout = Dial.defaultLayout
    @Published var background: [UInt16]? = nil
    @Published var boot: [UInt16]? = nil
    @Published var selected: Int? = 0
    @Published var tab = 0
    @Published var note = ""
    @Published var busy = false
    @Published var revision = 0
    var bgImage: CGImage? = nil, bootImage: CGImage? = nil

    func off(_ i: Int) -> Int { 4 + i * 10 }
    func x(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(layout[off(i) + 4]) | UInt16(layout[off(i) + 5]) << 8)) }
    func y(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(layout[off(i) + 6]) | UInt16(layout[off(i) + 7]) << 8)) }
    func on(_ i: Int) -> Bool { layout[off(i) + 8] == 1 }
    func font(_ i: Int) -> Int { Int(layout[off(i) + 9]) }
    func argb(_ i: Int) -> UInt32 { le32(layout, off(i)) }
    func setPos(_ i: Int, _ x: Int, _ y: Int) {
        let cx = UInt16(bitPattern: Int16(max(0, min(239, x)))), cy = UInt16(bitPattern: Int16(max(0, min(239, y))))
        layout[off(i) + 4] = UInt8(cx & 0xff); layout[off(i) + 5] = UInt8(cx >> 8); layout[off(i) + 6] = UInt8(cy & 0xff); layout[off(i) + 7] = UInt8(cy >> 8)
    }
    func setOn(_ i: Int, _ v: Bool) { layout[off(i) + 8] = v ? 1 : 0 }
    func setFont(_ i: Int, _ v: Int) { layout[off(i) + 9] = UInt8(v) }
    func setARGB(_ i: Int, _ v: UInt32) { layout.replaceSubrange(off(i)..<off(i) + 4, with: bytes32(v)) }
    func color(_ i: Int) -> NSColor {
        let c = argb(i)
        return NSColor(srgbRed: CGFloat((c >> 16) & 0xff) / 255, green: CGFloat((c >> 8) & 0xff) / 255, blue: CGFloat(c & 0xff) / 255, alpha: 1)
    }
    func setColor(_ i: Int, _ c: NSColor) {
        guard let s = c.usingColorSpace(.sRGB) else { return }
        let r = UInt32(max(0, min(255, s.redComponent * 255 + 0.5))), g = UInt32(max(0, min(255, s.greenComponent * 255 + 0.5))), b = UInt32(max(0, min(255, s.blueComponent * 255 + 0.5)))
        setARGB(i, 0xFF00_0000 | r << 16 | g << 8 | b)
    }
    func digits(_ e: Dial.Element) -> Int { e.precision.map { Int(layout[224 + $0.slot]) } ?? 0 }
    func setDigits(_ e: Dial.Element, _ v: Int) { if let p = e.precision { layout[224 + p.slot] = UInt8(v) } }

    func setBackground(_ px: [UInt16]?) { background = px; bgImage = px.flatMap { Pix.image($0, 240) }; revision += 1 }
    func setBoot(_ px: [UInt16]?) { boot = px; bootImage = px.flatMap { Pix.image($0, 235) }; revision += 1 }

    /// Nhận file bất kỳ: gói .zip của hãng, thông số .k2pic/.pic, ảnh làm hình nền hoặc hình khởi động (tuỳ tab đang mở).
    func load(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { note = L("Cannot read \(url.lastPathComponent)", "Không đọc được \(url.lastPathComponent)"); return }
        let ext = url.pathExtension.lowercased()
        var got = [String]()
        if ext == "zip" {
            for e in Zip.entries(data, maxSize: 8 << 20) {
                let n = e.name.lowercased()
                if n.hasSuffix("pic"), (try? K2Res.layout.validate(e.bytes)) != nil, !got.contains(L("parameters", "thông số")) { layout = e.bytes; got.append(L("parameters", "thông số")) }
                else if n.hasSuffix(".bmp"), let img = Pix.decode(e.bytes) {
                    if img.w == 240, img.h == 240, !got.contains(L("background image", "hình nền")), let px = Pix.fit(e.bytes, 240) { setBackground(px); got.append(L("background image", "hình nền")) }
                    else if img.w == 235, img.h == 235, !got.contains(L("boot image", "hình khởi động")), let px = Pix.fit(e.bytes, 235) { setBoot(px); got.append(L("boot image", "hình khởi động")) }
                }
            }
            note = got.isEmpty ? L("\(url.lastPathComponent): no .k2pic or 240×240 .bmp file found in the package", "\(url.lastPathComponent): không thấy file .k2pic hay .bmp 240×240 nào trong gói") : L("Loaded \(got.joined(separator: " + ")) from \(url.lastPathComponent)", "Đã nạp \(got.joined(separator: " + ")) từ \(url.lastPathComponent)")
        } else if ext == "k2pic" || ext == "pic" {
            let b = [UInt8](data)
            do { try K2Res.layout.validate(b); layout = b; note = L("Loaded parameters from \(url.lastPathComponent)", "Đã nạp thông số từ \(url.lastPathComponent)") }
            catch { note = "\(url.lastPathComponent): \(error.localizedDescription)" }
        } else {
            let n = tab == 1 ? 235 : 240
            guard let px = Pix.fit([UInt8](data), n) else { note = L("\(url.lastPathComponent): cannot read the image", "\(url.lastPathComponent): không đọc được ảnh"); return }
            if tab == 1 { setBoot(px) } else { setBackground(px) }
            let what = tab == 1 ? L("235×235 boot image", "hình khởi động 235×235") : L("240×240 background image", "hình nền 240×240")
            note = L("Using \(url.lastPathComponent) as the \(what)", "Đã lấy \(url.lastPathComponent) làm \(what)")
        }
        revision += 1
    }
    func openPanel() {
        let p = NSOpenPanel(); p.allowedFileTypes = ["zip", "k2pic", "pic", "bmp", "png", "jpg", "jpeg", "heic", "tiff", "gif"]
        guard p.runModal() == .OK, let u = p.url else { return }
        load(u)
    }
    func save(_ bytes: [UInt8], name: String, ext: String) {
        let p = NSSavePanel(); p.nameFieldStringValue = name; p.allowedFileTypes = [ext]
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try Data(bytes).write(to: u, options: .atomic); note = L("Saved \(u.lastPathComponent)", "Đã lưu \(u.lastPathComponent)") } catch { note = L("Could not save: \(error.localizedDescription)", "Không lưu được: \(error.localizedDescription)") }
    }
    static var backupDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Witrn USB Tester/Backups", isDirectory: true)
    }
}

extension Controller {
    var canCustomize: Bool { mode == .dfu && model?.id == Model.k2.id && !flashing && !sessionDone }

    /// Chỉ đọc: lấy hình nền, thông số, hình khởi động đang có trong K2. Không kết thúc phiên nên máy vẫn ở DFU.
    func readCustom(into cz: Customizer) {
        guard canCustomize, let t = transport else { return }
        flashing = true; progress = 0; phase = L("Read from K2", "Đọc từ K2"); cz.busy = true
        say(L("Reading customization from the K2 (read-only)…", "Đọc phần tuỳ biến từ K2 (chỉ đọc)…"))
        worker.async { [self] in
            var found = [String](), failure: Error?
            var got = [String: [UInt8]]()
            do {
                let dfu = Dfu(t)
                _ = try Updater.identify(dfu, .k2)
                let total = K2Res.all.reduce(0) { $0 + $1.size }
                var done = 0
                for r in K2Res.all {
                    let base = done
                    got[r.kind] = try Updater.readRegion(dfu, r.address, r.size) { n in
                        let p = Double(base + n) / Double(total)
                        if n % 8192 < 1024 || n == r.size { self.main { self.progress = p } }
                    }
                    done += r.size
                }
            } catch { failure = error }
            main { [self] in
                flashing = false; phase = ""; progress = 0; cz.busy = false
                if let failure { say(L("READ ERROR: \(failure.localizedDescription)", "LỖI đọc: \(failure.localizedDescription)"), error: true); cz.note = L("Could not read: \(failure.localizedDescription)", "Không đọc được: \(failure.localizedDescription)"); return }
                if let d = got["layout"], (try? K2Res.layout.validate(d)) != nil { cz.layout = d; found.append(L("parameters", "thông số")) }
                if let d = got["background"], let px = K2Res.background.pixels(d) { cz.setBackground(px); found.append(L("background image", "hình nền")) }
                if let d = got["boot"], let px = K2Res.boot.pixels(d) { cz.setBoot(px); found.append(L("boot image", "hình khởi động")) }
                cz.revision += 1
                let msg = found.isEmpty ? L("The K2 has no customization yet (the areas are empty).", "K2 chưa có phần tuỳ biến nào (các vùng đang trống).") : L("Read from the K2: \(found.joined(separator: ", ")).", "Đã đọc từ K2: \(found.joined(separator: ", ")).")
                say(msg); cz.note = msg
            }
        }
    }

    func confirmWriteCustom(_ res: K2Res, _ payload: [UInt8], raw: Bool = false, cz: Customizer) {
        guard canCustomize else { return }
        let alert = NSAlert()
        alert.messageText = raw ? L("Restore the \(res.title) from the backup to the K2?", "Khôi phục \(res.title) từ bản sao lưu vào K2?") : L("Write the \(res.title) to the K2?", "Ghi \(res.title) vào K2?")
        let dur = res.sectors > 1 ? L("about half a minute", "khoảng nửa phút") : L("a few seconds", "khoảng vài giây")
        alert.informativeText = L("The app backs up this area first, then erases, writes and reads back to compare. Do not unplug the cable while writing (\(dur)).\n\nAfter writing, the K2 leaves DFU; to write another item you must enter DFU again. The watch face only shows when enabled in the K2 settings (item 6, theme screen switch).",
                                  "App sẽ sao lưu vùng này trước, rồi xoá, ghi và đọc lại để so. Không rút cáp trong lúc ghi (\(dur)).\n\nGhi xong K2 sẽ thoát DFU; muốn ghi mục khác phải vào DFU lại. Mặt đồng hồ chỉ hiện khi bật trong cài đặt của K2 (mục 6, công tắc màn hình chủ đề).")
        alert.addButton(withTitle: raw ? L("Restore", "Khôi phục") : L("Write", "Ghi"))
        alert.addButton(withTitle: L("Cancel", "Huỷ"))
        guard showCentered(alert) == .alertFirstButtonReturn else { return }
        writeCustom(res, payload, raw: raw, cz: cz)
    }

    func writeCustom(_ res: K2Res, _ payload: [UInt8], raw: Bool = false, cz: Customizer) {
        guard canCustomize, let t = transport else { return }
        let gen = generation
        flashing = true; banner = nil; progress = 0; phase = L("Backing up", "Sao lưu"); cz.busy = true
        say(L("Writing the \(res.title) (\(payload.count) bytes at 0x\(String(res.address, radix: 16, uppercase: true)))…", "Bắt đầu ghi \(res.title) (\(payload.count) byte tại 0x\(String(res.address, radix: 16, uppercase: true)))…"))
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: L("Writing K2 customization", "Ghi tuỳ biến K2"))
        worker.async { [self] in
            var failure: Error?, backupName = ""
            do {
                let dfu = Dfu(t)
                _ = try Updater.identify(dfu, .k2)
                var last = -1
                try Updater.writeResource(dfu, res, image: payload, raw: raw, backup: { bytes in
                    let dir = Customizer.backupDir
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
                    let url = dir.appendingPathComponent("K2-\(res.kind)-\(df.string(from: Date())).bin")
                    try Data(bytes).write(to: url, options: .atomic)
                    guard (try? Data(contentsOf: url)) == Data(bytes) else { throw WError(L("Could not verify the backup file; stopped, nothing erased.", "Không xác nhận được file sao lưu; dừng, chưa xoá gì.")) }
                    backupName = url.lastPathComponent
                    self.main { self.say(L("Backed up the existing \(res.title) area: \(url.path)", "Đã sao lưu vùng \(res.title) hiện có: \(url.path)")) }
                }, progress: { ph, done, total in
                    let part = Double(done) / Double(max(total, 1))
                    let overall: Double, label: String
                    switch ph {
                    case .backup: overall = 0.30 * part; label = L("Backing up", "Sao lưu")
                    case .erase: overall = 0.30 + 0.05 * part; label = L("Erasing", "Xoá")
                    case .write: overall = 0.35 + 0.40 * part; label = L("Writing", "Ghi")
                    case .verify: overall = 0.75 + 0.25 * part; label = L("Verifying", "Kiểm tra")
                    }
                    let pct = Int(overall * 200)
                    if pct == last { return }
                    last = pct
                    self.main { self.progress = overall; self.phase = "\(label) \(Int(part * 100))%" }
                })
            } catch { failure = error }
            main { [self] in
                ProcessInfo.processInfo.endActivity(activity)
                flashing = false; cz.busy = false
                if let failure {
                    say(L("ERROR: \(failure.localizedDescription)", "LỖI: \(failure.localizedDescription)"), error: true)
                    let hint = backupName.isEmpty ? L("Nothing on the K2 was erased.", "Chưa xoá gì trong K2.") : L("Backup: \(backupName). Enter DFU again and write again, or use Restore backup.", "Bản sao lưu: \(backupName). Vào lại DFU rồi ghi lại, hoặc dùng Khôi phục sao lưu.")
                    banner = Banner(ok: false, title: L("Writing the \(res.title) did not finish", "Ghi \(res.title) chưa xong"), detail: "\(failure.localizedDescription). \(hint)")
                    cz.note = L("Write did not finish: \(failure.localizedDescription)", "Ghi chưa xong: \(failure.localizedDescription)")
                    progress = 0; phase = ""
                    if gen == generation { mode = .probing; probe(gen, t, .k2, quiet: false) }
                } else {
                    say(L("Wrote the \(res.title); the read-back matches byte for byte.", "Đã ghi \(res.title) và đọc lại khớp từng byte."))
                    banner = Banner(ok: true, title: L("Wrote the \(res.title) to the K2", "Đã ghi \(res.title) vào K2"),
                                    detail: L("Unplug and replug the cable. To write another item, enter DFU again. Enable the watch face in the K2 settings: item 6, theme screen switch.", "Rút cáp rồi cắm lại. Muốn ghi mục khác thì vào DFU lần nữa. Bật mặt đồng hồ trong cài đặt K2: mục 6, công tắc màn hình chủ đề."))
                    cz.note = L("Wrote the \(res.title). Enter DFU again to write the next item.", "Đã ghi \(res.title). Vào DFU lại để ghi mục tiếp theo.")
                    progress = 1; phase = L("Done", "Xong"); sessionDone = true
                }
            }
        }
    }

    func restoreCustom(cz: Customizer) {
        let p = NSOpenPanel(); p.directoryURL = Customizer.backupDir; p.allowedFileTypes = ["bin"]
        guard p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) else { return }
        guard let res = K2Res.all.first(where: { $0.allocation == d.count && u.lastPathComponent.contains("-\($0.kind)-") }) else {
            cz.note = L("\(u.lastPathComponent): not a backup made by this app (wrong name or wrong size)", "\(u.lastPathComponent): không phải bản sao lưu do app này tạo (sai tên hoặc sai kích thước)"); return
        }
        confirmWriteCustom(res, [UInt8](d), raw: true, cz: cz)
    }
}

// Khung xem trước 240×240 (phóng 2 lần): hình nền + các số ở đúng toạ độ; nhấp để chọn, kéo hoặc phím mũi tên để dời.
final class DialNSView: NSView {
    weak var cz: Customizer?
    private var grab: (index: Int, dx: CGFloat, dy: CGFloat)? = nil
    static let scale: CGFloat = 2
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 480, height: 480) }

    private func font(_ e: Dial.Element, _ cz: Customizer) -> NSFont {
        let h = e.hasFont ? Dial.fontHeights[min(cz.font(e.index), Dial.fontHeights.count - 1)] : 20
        return NSFont.monospacedDigitSystemFont(ofSize: h * DialNSView.scale * 0.92, weight: h >= 40 ? .semibold : .regular)
    }
    private func box(_ e: Dial.Element, _ cz: Customizer) -> (NSRect, NSAttributedString) {
        let f = font(e, cz)
        let s = NSAttributedString(string: Dial.sampleText(e, digits: cz.digits(e)), attributes: [.font: f, .foregroundColor: cz.color(e.index)])
        let h = (e.hasFont ? Dial.fontHeights[min(cz.font(e.index), 6)] : 20) * DialNSView.scale
        return (NSRect(x: CGFloat(cz.x(e.index)) * DialNSView.scale, y: CGFloat(cz.y(e.index)) * DialNSView.scale, width: max(12, s.size().width), height: h), s)
    }
    override func draw(_ dirty: NSRect) {
        guard let cz = cz, let g = NSGraphicsContext.current?.cgContext else { return }
        let n: CGFloat = cz.tab == 1 ? 235 : 240
        let area = NSRect(x: 0, y: 0, width: n * 2, height: n * 2)
        NSColor.black.setFill(); area.fill()
        if let img = cz.tab == 1 ? cz.bootImage : cz.bgImage {
            g.saveGState(); g.translateBy(x: 0, y: area.height); g.scaleBy(x: 1, y: -1)
            g.interpolationQuality = .none; g.draw(img, in: area); g.restoreGState()
        } else {
            let t = NSAttributedString(string: cz.tab == 1 ? L("No boot image selected", "Chưa chọn hình khởi động") : L("No background image selected", "Chưa chọn hình nền"), attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.gray])
            t.draw(at: NSPoint(x: (area.width - t.size().width) / 2, y: area.height - 26))
        }
        guard cz.tab == 0 else { return }
        g.saveGState(); g.clip(to: area)
        for e in Dial.elements where cz.on(e.index) {
            let (r, s) = box(e, cz)
            s.draw(at: NSPoint(x: r.minX, y: r.minY + (r.height - s.size().height) / 2))
            if cz.selected == e.index {
                let p = NSBezierPath(rect: r.insetBy(dx: -2, dy: -2)); p.lineWidth = 1; p.setLineDash([4, 3], count: 2, phase: 0)
                NSColor.controlAccentColor.setStroke(); p.stroke()
            }
        }
        g.restoreGState()
    }
    override func mouseDown(with ev: NSEvent) {
        guard let cz = cz, cz.tab == 0, !cz.busy else { return }
        window?.makeFirstResponder(self)
        let p = convert(ev.locationInWindow, from: nil)
        grab = nil
        for e in Dial.elements.reversed() where cz.on(e.index) {
            let (r, _) = box(e, cz)
            if r.insetBy(dx: -3, dy: -3).contains(p) { cz.selected = e.index; grab = (e.index, p.x - r.minX, p.y - r.minY); break }
        }
        needsDisplay = true
    }
    override func mouseDragged(with ev: NSEvent) {
        guard let cz = cz, let gr = grab else { return }
        let p = convert(ev.locationInWindow, from: nil)
        cz.setPos(gr.index, Int(((p.x - gr.dx) / DialNSView.scale).rounded()), Int(((p.y - gr.dy) / DialNSView.scale).rounded()))
        needsDisplay = true
    }
    override func mouseUp(with ev: NSEvent) { grab = nil }
    override func keyDown(with ev: NSEvent) {
        guard let cz = cz, cz.tab == 0, let i = cz.selected, !cz.busy else { super.keyDown(with: ev); return }
        let step = ev.modifierFlags.contains(.shift) ? 10 : 1
        switch ev.keyCode {
        case 123: cz.setPos(i, cz.x(i) - step, cz.y(i))
        case 124: cz.setPos(i, cz.x(i) + step, cz.y(i))
        case 126: cz.setPos(i, cz.x(i), cz.y(i) - step)
        case 125: cz.setPos(i, cz.x(i), cz.y(i) + step)
        default: super.keyDown(with: ev); return
        }
        needsDisplay = true
    }
}

struct DialView: NSViewRepresentable {
    @ObservedObject var cz: Customizer
    func makeNSView(context: Context) -> DialNSView { let v = DialNSView(); v.cz = cz; return v }
    func updateNSView(_ v: DialNSView, context: Context) { _ = cz.layout; _ = cz.revision; _ = cz.selected; _ = cz.tab; v.needsDisplay = true }
}

struct NumField: View {
    let value: Int, set: (Int) -> Void
    var body: some View {
        TextField("", text: Binding(get: { String(value) }, set: { if let v = Int($0.filter { "0123456789".contains($0) }) { set(v) } else if $0.isEmpty { set(0) } }))
            .textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 46).multilineTextAlignment(.trailing).font(.system(size: 12).monospacedDigit())
    }
}

struct CustomView: View {
    @ObservedObject var c: Controller
    @ObservedObject var cz: Customizer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $cz.tab) { Text(L("Watch face", "Mặt đồng hồ")).tag(0); Text(L("Boot image", "Hình khởi động")).tag(1) }.pickerStyle(SegmentedPickerStyle()).labelsHidden().frame(width: 250)
                Spacer()
                Button(L("Open package / image…", "Mở gói / ảnh…")) { cz.openPanel() }.help(L("A WITRN watch face .zip package, a .k2pic parameter file, or any image (cropped square and resized automatically)", "Gói .zip mặt đồng hồ của WITRN, file thông số .k2pic, hoặc ảnh bất kỳ (tự cắt vuông và đổi cỡ)"))
                Button(L("Save parameters…", "Lưu thông số…")) { cz.save(cz.layout, name: L("watch-face.k2pic", "mat-dong-ho.k2pic"), ext: "k2pic") }
                Button(L("Save background .bmp…", "Lưu hình nền .bmp…")) { if let b = cz.background { cz.save(Pix.bmp(b, 240), name: L("background-240.bmp", "hinh-nen-240.bmp"), ext: "bmp") } }.disabled(cz.background == nil)
                Button(L("Reset to default", "Về mặc định")) { cz.layout = Dial.defaultLayout; cz.revision += 1 }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    DialView(cz: cz).frame(width: 480, height: 480).overlay(Rectangle().stroke(Color(NSColor.separatorColor), lineWidth: 1))
                    Text(cz.tab == 0 ? L("The preview is approximate: fonts and positions on the K2 screen differ slightly, and the vendor also recommends adjusting by trial. Unit letters (V, A, W…) do not appear by themselves; they must be part of the background image. Click to select, drag or use the arrow keys to move.", "Xem trước chỉ gần đúng: phông chữ và vị trí trên màn hình K2 lệch đôi chút, hãng cũng khuyên chỉnh thử dần. Chữ đơn vị (V, A, W…) không tự hiện, phải có sẵn trong hình nền. Nhấp để chọn, kéo hoặc dùng phím mũi tên để dời.")
                                     : L("The boot image is 235×235. Other sizes are scaled to fill the frame and center-cropped.", "Hình khởi động 235×235. Ảnh khác cỡ sẽ được phóng cho kín khung và cắt giữa."))
                        .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).frame(width: 480, alignment: .leading)
                }.padding(12)
                Divider()
                if cz.tab == 0 { table } else { bootSide }
            }
            Divider()
            footer
        }
        .frame(minWidth: 1010, minHeight: 690)
        .background(Color(NSColor.windowBackgroundColor))
        .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let d = item as? Data, let url = URL(dataRepresentation: d, relativeTo: nil) else { return }
                DispatchQueue.main.async { cz.load(url) }
            }
            return true
        }
    }

    private var table: some View {
        ScrollView {
            VStack(spacing: 3) {
                HStack(spacing: 8) {
                    Text(L("Show", "Hiện")).frame(width: 36); Text(L("Item", "Mục")).frame(width: 128, alignment: .leading); Text("X").frame(width: 46); Text("Y").frame(width: 46)
                    Text(L("Color", "Màu")).frame(width: 44); Text(L("Font size", "Cỡ chữ")).frame(width: 78); Text(L("Digits", "Số chữ số")).frame(width: 62); Spacer()
                }.font(.system(size: 10)).foregroundColor(.secondary)
                ForEach(Dial.elements, id: \.index) { e in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { cz.on(e.index) }, set: { cz.setOn(e.index, $0); cz.selected = e.index })).labelsHidden().frame(width: 36)
                        Text(e.name).font(.system(size: 12)).frame(width: 128, alignment: .leading)
                        NumField(value: cz.x(e.index)) { cz.setPos(e.index, $0, cz.y(e.index)) }
                        NumField(value: cz.y(e.index)) { cz.setPos(e.index, cz.x(e.index), $0) }
                        ColorPicker("", selection: Binding(get: { Color(cz.color(e.index)) }, set: { cz.setColor(e.index, NSColor($0)) }), supportsOpacity: false).labelsHidden().frame(width: 44)
                        if e.hasFont {
                            Picker("", selection: Binding(get: { min(cz.font(e.index), 6) }, set: { cz.setFont(e.index, $0) })) {
                                ForEach(0..<Dial.fonts.count, id: \.self) { Text(Dial.fonts[$0]).tag($0) }
                            }.labelsHidden().frame(width: 78)
                        } else { Spacer().frame(width: 78) }
                        if let p = e.precision {
                            Picker("", selection: Binding(get: { min(max(cz.digits(e), p.lo), p.hi) }, set: { cz.setDigits(e, $0) })) {
                                ForEach(p.lo...p.hi, id: \.self) { Text("\($0)").tag($0) }
                            }.labelsHidden().frame(width: 62)
                        } else { Spacer().frame(width: 62) }
                        Spacer()
                    }
                    .padding(.vertical, 1).padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(cz.selected == e.index ? Color.accentColor.opacity(0.16) : Color.clear))
                    .contentShape(Rectangle()).onTapGesture { cz.selected = e.index }
                    .opacity(cz.on(e.index) ? 1 : 0.55)
                }
            }.padding(10)
        }.disabled(cz.busy)
    }

    private var bootSide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Boot image", "Hình khởi động")).font(.headline)
            Text(L("Shown when the K2 powers on. Choose any image (PNG, JPEG, BMP…) or drop one onto this window.", "Hiện khi K2 bật nguồn. Chọn một ảnh bất kỳ (PNG, JPEG, BMP…) hoặc kéo ảnh vào cửa sổ này.")).fixedSize(horizontal: false, vertical: true)
            Button(L("Choose image…", "Chọn ảnh…")) { cz.openPanel() }
            Button(L("Save as 235×235 .bmp…", "Lưu thành .bmp 235×235…")) { if let b = cz.boot { cz.save(Pix.bmp(b, 235), name: L("boot-235.bmp", "hinh-khoi-dong-235.bmp"), ext: "bmp") } }.disabled(cz.boot == nil)
            Spacer()
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(c.canCustomize ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(c.canCustomize ? L("K2 is in DFU: ready to read / write", "K2 đang ở DFU: sẵn sàng đọc / ghi") : (c.flashing ? "\(c.phase)…" : (c.sessionDone ? L("DFU session finished: unplug and enter DFU again to write more", "Phiên DFU đã xong: rút cáp, vào DFU lại để ghi tiếp") : L("Editing needs no device. To read / write: put the K2 into DFU (hold − while plugging into the USB HID port)", "Sửa thì không cần cắm máy. Muốn đọc / ghi: đưa K2 vào DFU (giữ nút − khi cắm cổng USB HID)"))))
                    .font(.system(size: 12)).lineLimit(1)
                Spacer()
                if c.flashing { ProgressView(value: c.progress).frame(width: 150) }
            }
            HStack(spacing: 8) {
                Button(L("Read from K2", "Đọc từ K2")) { c.readCustom(into: cz) }.help(L("Fetch the watch face, background image and boot image currently on the device (read-only)", "Lấy mặt đồng hồ, hình nền, hình khởi động đang có trong máy (chỉ đọc)"))
                Button(L("Restore backup…", "Khôi phục sao lưu…")) { c.restoreCustom(cz: cz) }
                Spacer()
                Button(L("Write background", "Ghi hình nền")) { if let b = cz.background { c.confirmWriteCustom(.background, K2Res.background.wrap(b), cz: cz) } }.disabled(cz.background == nil || !c.canCustomize)
                Button(L("Write parameters", "Ghi thông số")) { c.confirmWriteCustom(.layout, cz.layout, cz: cz) }.disabled(!c.canCustomize)
                Button(L("Write boot image", "Ghi hình khởi động")) { if let b = cz.boot { c.confirmWriteCustom(.boot, K2Res.boot.wrap(b), cz: cz) } }.disabled(cz.boot == nil || !c.canCustomize)
            }.disabled(!c.canCustomize)
            if !cz.note.isEmpty { Text(cz.note).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(2) }
        }.padding(.horizontal, 12).padding(.vertical, 9)
    }
}

final class CustomWindow: NSObject {
    static let shared = CustomWindow()
    static var title: String { L("Customize K2 — Witrn USB Tester", "Tuỳ biến K2 — Witrn USB Tester") }
    var window: NSWindow?
    let cz = Customizer()

    func show(_ c: Controller) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = CustomWindow.title
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: Localized { [cz] in CustomView(c: c, cz: cz) })
            w.center(); w.setFrameAutosaveName("custom")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Tự kiểm tra phần tuỳ biến trên thiết bị giả lập; có thêm gói .zip của hãng thì thử cả gói đó.
func customSelfTest(_ zipPath: String?) -> Int32 {
    var fails = 0
    func check(_ name: String, _ ok: Bool, _ info: String = "") { print(ok ? "✔ \(name)" : "✖ \(name)  \(info)"); if !ok { fails += 1 } }
    let def = Dial.defaultLayout
    check("bố cục mặc định hợp lệ", (try? K2Res.layout.validate(def)) != nil && def.count == 400)
    var badDigits = def; badDigits[224] = 9
    var badMagic = def; badMagic[399] = 0
    check("từ chối thông số sai", (try? K2Res.layout.validate(badDigits)) == nil && (try? K2Res.layout.validate(badMagic)) == nil && (try? K2Res.layout.validate(Array(def.dropLast()))) == nil)
    check("các vùng không chồng nhau", K2Res.background.address + UInt32(K2Res.background.allocation) == 0x080E_3000 && K2Res.layout.address + UInt32(K2Res.layout.allocation) == K2Res.boot.address
          && K2Res.boot.address + UInt32(K2Res.boot.allocation) == 0x080F_F800 && K2Res.background.wrap([UInt16](repeating: 0, count: 57600)).count == 115_208
          && K2Res.boot.wrap([UInt16](repeating: 0, count: 55225)).count == 110_458)
    // ảnh thử không đối xứng: góc trên-trái đỏ, trên-phải lục, dưới-trái lam
    var rgba = [UInt8](repeating: 0, count: 240 * 240 * 4)
    func put(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) { let o = (y * 240 + x) * 4; rgba[o] = r; rgba[o + 1] = g; rgba[o + 2] = b; rgba[o + 3] = 255 }
    put(0, 0, 255, 0, 0); put(239, 0, 0, 255, 0); put(0, 239, 0, 0, 255); put(100, 50, 255, 255, 255)
    let px = (0..<57600).map { Pix.to565(r: rgba[$0 * 4], g: rgba[$0 * 4 + 1], b: rgba[$0 * 4 + 2]) }
    let viaBMP = Pix.fit(Pix.bmp(px, 240), 240)
    check("RGB565 và chiều ảnh BMP", px[0] == 0xF800 && px[239] == 0x07E0 && px[239 * 240] == 0x001F && viaBMP != nil && viaBMP! == px)
    if let img = Pix.image(px, 240), let rep = Optional(NSBitmapImageRep(cgImage: img)), let png = rep.representation(using: .png, properties: [:]), let viaPNG = Pix.fit([UInt8](png), 240) {
        check("ảnh PNG qua bộ giải mã macOS giữ đúng chiều", viaPNG[0] == 0xF800 && viaPNG[239] == 0x07E0 && viaPNG[239 * 240] == 0x001F && viaPNG[50 * 240 + 100] == 0xFFFF, String(format: "%04X %04X %04X", viaPNG[0], viaPNG[239], viaPNG[239 * 240]))
    } else { check("ảnh PNG", false) }
    let scaled = Pix.fit(Pix.bmp(px, 240), 235)
    check("đổi cỡ sang 235×235", scaled?.count == 55225)
    check("bọc / mở điểm ảnh", K2Res.background.pixels(K2Res.background.wrap(px)) == px)

    // ghi lên K2 giả lập
    func run(_ res: K2Res, _ payload: [UInt8], corrupt: Int? = nil, raw: Bool = false) -> (FakeDevice, [UInt8]?, Error?) {
        let dev = FakeDevice(.k2, corruptAt: corrupt)
        let o = Int(res.address - W.flashBase)
        for i in 0..<res.allocation { dev.mem[o + i] = UInt8((i * 7 + 3) & 0xff) }      // dữ liệu cũ để kiểm tra sao lưu và phần đuôi
        var saved: [UInt8]? = nil
        do { try Updater.writeResource(Dfu(dev), res, image: payload, raw: raw, backup: { saved = $0 }, progress: { _, _, _ in }); return (dev, saved, nil) }
        catch { return (dev, saved, error) }
    }
    for (res, payload) in [(K2Res.layout, def), (K2Res.background, K2Res.background.wrap(px)), (K2Res.boot, K2Res.boot.wrap(scaled ?? []))] {
        let (dev, saved, err) = run(res, payload)
        let o = Int(res.address - W.flashBase)
        let old = (0..<res.allocation).map { UInt8(($0 * 7 + 3) & 0xff) }
        let tailOK = (payload.count..<res.allocation).allSatisfy { dev.mem[o + $0] == old[$0] }
        let before = dev.mem[o - 1], after = o + res.allocation < dev.mem.count ? dev.mem[o + res.allocation] : 0x11
        check("ghi \(res.title)", err == nil && Array(dev.mem[o..<o + payload.count]) == payload && tailOK && saved == old && before == 0x11 && after == 0x11 && dev.sent.last == 23,
              "\(err?.localizedDescription ?? "") tail=\(tailOK)")
    }
    let (devBad, savedBad, errBad) = run(.background, K2Res.background.wrap(px), corrupt: Int(K2Res.background.address - W.flashBase) + 5000)
    check("phát hiện lỗi ghi, không kết thúc phiên", errBad != nil && savedBad != nil && devBad.sent.last != 23, errBad?.localizedDescription ?? "")
    let (devNo, savedNo, errNo) = run(.layout, badDigits)
    check("dữ liệu sai thì không đụng tới máy", errNo != nil && savedNo == nil && devNo.sent.isEmpty)
    let old = (0..<K2Res.layout.allocation).map { UInt8(($0 * 5 + 1) & 0xff) }
    let (devR, _, errR) = run(.layout, old, raw: true)
    check("khôi phục bản sao lưu", errR == nil && Array(devR.mem[Int(K2Res.layout.address - W.flashBase)..<Int(K2Res.layout.address - W.flashBase) + 2048]) == old)

    if let zipPath = zipPath {
        let cz = Customizer(); cz.load(URL(fileURLWithPath: zipPath))
        print("  " + cz.note)
        check("gói của hãng: thông số", (try? K2Res.layout.validate(cz.layout)) != nil && cz.layout != def)
        check("gói của hãng: hình nền 240×240", cz.background?.count == 57600 && cz.bgImage != nil)
        if let bg = cz.background {
            let (dev, _, err) = run(.background, K2Res.background.wrap(bg))
            check("gói của hãng: ghi hình nền giả lập", err == nil && dev.sent.last == 23)
        }
    }
    print(fails == 0 ? "TẤT CẢ ĐẠT" : "\(fails) MỤC LỖI")
    return fails == 0 ? 0 : 1
}

// MARK: - Cửa sổ Monitor

final class MonitorWindow: NSObject {
    static let shared = MonitorWindow()
    static var title: String { L("K2 Monitor — Witrn USB Tester", "Monitor K2 — Witrn USB Tester") }
    var window: NSWindow?
    var ctl: MonCtl?

    func show(demo: Bool = false) {
        if window == nil {
            let c = MonCtl(source: demo ? DemoSource() : HIDSource())
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = MonitorWindow.title
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: Localized { MonitorView(ctl: c) })
            w.center(); w.setFrameAutosaveName("monitor")
            window = w; ctl = c
            c.start()
        }
        window?.makeKeyAndOrderFront(nil)
    }
    @objc func open() { show() }
    @objc func openFile() { show(); ctl?.openPanel() }
    @objc func save() { guard let c = ctl else { return }; if c.tab == 1 { c.savePD() } else { c.saveCSV() } }
    @objc func clear() { ctl?.clearLive() }
}

// MARK: - Khởi động

let argv = CommandLine.arguments
if argv.contains(where: { $0.hasPrefix("--selftest") }) { Lang.vi = true }     // tự kiểm tra so chuỗi tiếng Việt
if argv.contains("--selftest-monitor") { exit(monitorSelfTest()) }
if let i = argv.firstIndex(of: "--selftest-custom") { exit(customSelfTest(i + 1 < argv.count ? argv[i + 1] : nil)) }
if let i = argv.firstIndex(of: "--selftest"), i + 1 < argv.count {
    exit(selfTest(argv[i + 1]))
}
if argv.contains("--hidtest") {
    // Kiểm tra đường ghi/đọc USB: gửi lệnh bắt tay (không ghi gì vào flash) rồi in các loại gói nhận về.
    let bus = HIDBus()
    bus.onAttach = { t in
        DispatchQueue.global().async {
            print(String(format: "thiết bị PID 0x%04X \"%@\" → model %@", t.pid, t.product, Model.with(pid: t.pid)?.id ?? "?"))
            Thread.sleep(forTimeInterval: 0.3); t.clear()
            do {
                try t.write(Frame.build(3))
                var seen = [UInt8: Int]()
                let end = Date().addingTimeInterval(0.6)
                while Date() < end {
                    if let raw = try t.read(timeoutMs: 50), let f = try? Frame.parse(raw) { seen[f.cmd, default: 0] += 1 }
                }
                print("ghi OK; gói nhận về theo mã lệnh:", seen.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
                exit(0)
            } catch { print("LỖI: \(error.localizedDescription)"); exit(1) }
        }
    }
    bus.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { print("Không thấy thiết bị WITRN"); exit(2) }
    dispatchMain()
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

/// Dựng thanh menu theo ngôn ngữ đang chọn (gọi lại mỗi khi đổi ngôn ngữ).
func buildMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem(); menu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: L("Hide Witrn USB Tester", "Ẩn Witrn USB Tester"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: L("Quit Witrn USB Tester", "Thoát Witrn USB Tester"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let fileItem = NSMenuItem(); menu.addItem(fileItem)
    let fileMenu = NSMenu(title: L("File", "Tệp"))
    func monitorItem(_ title: String, _ sel: Selector, _ key: String) {
        let it = fileMenu.addItem(withTitle: title, action: sel, keyEquivalent: key); it.target = MonitorWindow.shared
    }
    fileMenu.addItem(withTitle: L("Firmware Window", "Cửa sổ nạp firmware"), action: #selector(AppDelegate.showMain), keyEquivalent: "1").target = delegate
    monitorItem(L("K2 Monitor Window", "Cửa sổ Monitor K2"), #selector(MonitorWindow.open), "2")
    fileMenu.addItem(withTitle: L("Customize K2 Window", "Cửa sổ Tuỳ biến K2"), action: #selector(AppDelegate.showCustom), keyEquivalent: "3").target = delegate
    fileMenu.addItem(.separator())
    monitorItem(L("Open Measurement File…", "Mở file đo…"), #selector(MonitorWindow.openFile), "o")
    monitorItem(L("Save Measurement…", "Lưu bản đo…"), #selector(MonitorWindow.save), "s")
    monitorItem(L("Clear Live Chart", "Xoá đồ thị trực tiếp"), #selector(MonitorWindow.clear), "k")
    fileMenu.addItem(.separator())
    fileMenu.addItem(withTitle: L("Close Window", "Đóng cửa sổ"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = fileMenu
    let editItem = NSMenuItem(); menu.addItem(editItem)
    let editMenu = NSMenu(title: L("Edit", "Sửa"))
    editMenu.addItem(withTitle: L("Copy", "Sao chép"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: L("Select All", "Chọn tất cả"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    let langItem = NSMenuItem(); menu.addItem(langItem)
    let langMenu = NSMenu(title: L("Language", "Ngôn ngữ"))
    for (code, title) in Lang.all {
        let it = langMenu.addItem(withTitle: title, action: #selector(AppDelegate.pickLanguage(_:)), keyEquivalent: "")
        it.target = delegate; it.representedObject = code; it.state = Lang.shared.code == code ? .on : .off
    }
    langItem.submenu = langMenu
    app.mainMenu = menu
}
buildMenu()
Lang.shared.onChange = {
    buildMenu()
    CustomWindow.shared.window?.title = CustomWindow.title
    MonitorWindow.shared.window?.title = MonitorWindow.title
}
app.run()
