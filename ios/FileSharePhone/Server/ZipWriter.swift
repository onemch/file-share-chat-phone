import Foundation

/// 最小 ZIP writer（store 模式，无压缩，无第三方依赖）。
/// 结构：local file header + file data → central directory → EOCD。
/// 文件名统一 UTF-8，并置 general purpose flag bit 11 (0x0800)，
/// 保证 macOS「归档实用工具」与 Windows 资源管理器能正确解压中文文件名。
///
/// 采用两遍读取：第一遍算 CRC32 与大小，第二遍写数据，
/// 这样 local header 里能写正确值，不需要 data descriptor，兼容性最好。
final class ZipWriter {

    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
        let time: UInt16
        let date: UInt16
    }

    private let url: URL
    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt32 = 0
    private var finished = false

    init(url: URL) throws {
        self.url = url
        if !FileManager.default.createFile(atPath: url.path, contents: nil) {
            throw NSError(domain: "ZipWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 ZIP 文件"])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func addFile(at fileURL: URL, arcname: String) throws {
        guard !finished else { return }

        // 超过 4GB 的文件在非 Zip64 的 store 模式下无法表示，跳过以保证 ZIP 可解压。
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let n = attrs[.size] as? NSNumber, n.uint64Value > 0xFFFF_FFFF {
            return
        }

        let nameData = Data(arcname.replacingOccurrences(of: "\\", with: "/").utf8)
        let mod = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        let (time, date) = ZipWriter.dosDateTime(mod ?? Date())
        let localOffset = offset

        // Pass 1 — 计算 CRC32 与大小（流式，不把文件读入内存）
        var crc: UInt32 = 0xFFFF_FFFF
        var size: UInt32 = 0
        let src = try FileHandle(forReadingFrom: fileURL)
        while true {
            let chunk = src.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            crc = CRC32.update(crc, with: chunk)
            size &+= UInt32(chunk.count)
        }
        try? src.close()
        crc ^= 0xFFFF_FFFF

        // Local file header
        var local = Data()
        local.append(le32(0x0403_4B50))
        local.append(le16(20))          // version needed to extract
        local.append(le16(0x0800))      // flags: UTF-8 filename
        local.append(le16(0))           // compression method: store
        local.append(le16(time))
        local.append(le16(date))
        local.append(le32(crc))
        local.append(le32(size))
        local.append(le32(size))
        local.append(le16(UInt16(nameData.count)))
        local.append(le16(0))           // extra field length
        local.append(nameData)
        try write(local)

        // Pass 2 — 写文件数据（流式）
        let src2 = try FileHandle(forReadingFrom: fileURL)
        while true {
            let chunk = src2.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            try write(chunk)
        }
        try? src2.close()

        entries.append(Entry(name: nameData, crc: crc, size: size,
                             offset: localOffset, time: time, date: date))
    }

    func finish() throws {
        guard !finished else { return }
        finished = true

        let cdOffset = offset
        var cd = Data()
        for e in entries {
            cd.append(le32(0x0201_4B50))
            cd.append(le16(20))         // version made by
            cd.append(le16(20))         // version needed
            cd.append(le16(0x0800))     // flags
            cd.append(le16(0))          // method: store
            cd.append(le16(e.time))
            cd.append(le16(e.date))
            cd.append(le32(e.crc))
            cd.append(le32(e.size))
            cd.append(le32(e.size))
            cd.append(le16(UInt16(e.name.count)))
            cd.append(le16(0))          // extra length
            cd.append(le16(0))          // file comment length
            cd.append(le16(0))          // disk number start
            cd.append(le16(0))          // internal file attributes
            cd.append(le32(0))          // external file attributes
            cd.append(le32(e.offset))   // relative offset of local header
            cd.append(e.name)
        }
        let cdSize = UInt32(cd.count)
        try write(cd)

        var eocd = Data()
        eocd.append(le32(0x0605_4B50))
        eocd.append(le16(0))            // number of this disk
        eocd.append(le16(0))            // disk with start of central directory
        eocd.append(le16(UInt16(entries.count)))
        eocd.append(le16(UInt16(entries.count)))
        eocd.append(le32(cdSize))
        eocd.append(le32(cdOffset))
        eocd.append(le16(0))            // comment length
        try write(eocd)

        try? handle.close()
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset &+= UInt32(data.count)
    }

    // MARK: - 辅助

    private func le16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    private func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
              UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(c.year ?? 1980, 1980), 2107)
        let month = min(max(c.month ?? 1, 1), 12)
        let day = min(max(c.day ?? 1, 1), 31)
        let hour = min(max(c.hour ?? 0, 0), 23)
        let minute = min(max(c.minute ?? 0, 0), 59)
        let second = min(max(c.second ?? 0, 0), 59)
        let t = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let d = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (t, d)
    }

    private enum CRC32 {
        static let table: [UInt32] = {
            var t = [UInt32](repeating: 0, count: 256)
            for i in 0..<256 {
                var c = UInt32(i)
                for _ in 0..<8 {
                    c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
                }
                t[i] = c
            }
            return t
        }()

        static func update(_ crc: UInt32, with data: Data) -> UInt32 {
            var c = crc
            for b in data {
                c = (c >> 8) ^ table[Int((c ^ UInt32(b)) & 0xFF)]
            }
            return c
        }
    }
}
