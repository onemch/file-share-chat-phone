import Foundation

/// 共享目录封装：`Documents/SharedFiles`，以及临时 ZIP / 上传暂存目录。
/// 所有外部传入的名称都必须经过 `safeBasename` 或 `resolveWithin`，
/// 与 Python `server.py` 的 `safe_basename` / `resolve_within` 等价，防 `../` 穿越。
final class FileStore {

    let shareDir: URL
    let tempDir: URL

    init() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        shareDir = documents.appendingPathComponent("SharedFiles", isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        tempDir = caches.appendingPathComponent("FileShareTemp", isDirectory: true)
        try? fm.createDirectory(at: shareDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    // MARK: - 名称安全

    /// 顶层项目名：只保留单个文件名，剔除路径分隔符与非法字符。
    func safeBasename(_ raw: String) -> String? {
        var name = raw.replacingOccurrences(of: "\\", with: "/")
        if let last = name.split(separator: "/", omittingEmptySubsequences: false).last {
            name = String(last)
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "." || name == ".." { return nil }

        var out = ""
        let illegal = Set("<>:\"|?*".unicodeScalars)
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || illegal.contains(scalar) {
                out.append("_")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if out.isEmpty || out.count > 200 { return nil }
        return out
    }

    /// 把用户给的名称解析为 SHARE_DIR 内的绝对 URL，越界返回 nil。
    func resolveWithin(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let rel = trimmed.replacingOccurrences(of: "\\", with: "/")
        if rel.hasPrefix("/") { return nil }
        if rel.count >= 2 {
            let second = rel[rel.index(rel.startIndex, offsetBy: 1)]
            if (rel.first?.isLetter ?? false) && second == ":" { return nil } // C:\...
        }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init).filter { $0 != "." }
        if parts.isEmpty || parts.contains("..") { return nil }

        let base = shareDir.standardizedFileURL
        var target = base
        for p in parts { target.appendPathComponent(p) }
        target = target.standardizedFileURL
        let basePath = base.path
        if target.path == basePath || !target.path.hasPrefix(basePath + "/") { return nil }
        return target
    }

    /// 判断某个相对路径（文件夹上传用）是否安全且不含非法字符。
    func safeRelativeParts(_ raw: String) -> [String]? {
        let rel = raw.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespaces)
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init).filter { $0 != "." }
        if parts.isEmpty || parts.contains("..") { return nil }
        let illegal = Set("<>:\"|?*".unicodeScalars)
        for p in parts {
            for scalar in p.unicodeScalars {
                if scalar.value < 0x20 || illegal.contains(scalar) { return nil }
            }
        }
        return parts
    }

    // MARK: - 重命名 / 枚举

    func uniqueName(for name: String) -> String {
        if !FileManager.default.fileExists(atPath: shareDir.appendingPathComponent(name).path) {
            return name
        }
        let ns = name as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        var counter = 1
        while true {
            let candidate = "\(stem)(\(counter))\(suffix)"
            if !FileManager.default.fileExists(atPath: shareDir.appendingPathComponent(candidate).path) {
                return candidate
            }
            counter += 1
        }
    }

    func uniqueFolderName(for name: String) -> String {
        if !FileManager.default.fileExists(atPath: shareDir.appendingPathComponent(name).path) {
            return name
        }
        var counter = 1
        while true {
            let candidate = "\(name)(\(counter))"
            if !FileManager.default.fileExists(atPath: shareDir.appendingPathComponent(candidate).path) {
                return candidate
            }
            counter += 1
        }
    }

    func topLevelNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: shareDir.path)) ?? []
        return names.filter { resolveWithin($0) != nil }
    }

    // MARK: - 列表

    func itemInfo(_ url: URL) -> [String: Any]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let bytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mod = (attrs[.modificationDate] as? Date) ?? Date()

        var info: [String: Any] = [
            "name": url.lastPathComponent,
            "size": humanSize(bytes),
            "bytes": bytes,
            "modified": mod.timeIntervalSince1970,
            "modified_str": displayTimestamp(mod),
        ]
        if isDir.boolValue {
            var total: UInt64 = 0
            var count = 0
            if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                                       options: [.skipsHiddenFiles]) {
                while let f = e.nextObject() as? URL {
                    var d: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: f.path, isDirectory: &d), !d.boolValue else { continue }
                    if let s = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, s >= 0 {
                        total += UInt64(s)
                        count += 1
                    }
                }
            }
            info["type"] = "folder"
            info["size"] = humanSize(total)
            info["bytes"] = total
            info["file_count"] = count
        } else {
            info["type"] = "file"
        }
        return info
    }

    /// 文件夹优先、按 modified 倒序。
    func listItems() -> [[String: Any]] {
        var items: [[String: Any]] = []
        for name in topLevelNames() {
            if let info = itemInfo(shareDir.appendingPathComponent(name)) { items.append(info) }
        }
        items.sort { a, b in
            let aFolder = (a["type"] as? String) == "folder"
            let bFolder = (b["type"] as? String) == "folder"
            if aFolder != bFolder { return aFolder }
            let am = (a["modified"] as? Double) ?? 0
            let bm = (b["modified"] as? Double) ?? 0
            return am > bm
        }
        return items
    }

    // MARK: - 删除

    @discardableResult
    func removeItem(named name: String) -> Bool {
        guard let path = resolveWithin(name),
              FileManager.default.fileExists(atPath: path.path) else { return false }
        do {
            try FileManager.default.removeItem(at: path)
            return true
        } catch {
            return false
        }
    }

    func clearAll() -> Int {
        var deleted = 0
        for name in topLevelNames() {
            if removeItem(named: name) { deleted += 1 }
        }
        return deleted
    }

    // MARK: - ZIP

    func makeZip(names: [String], prefix: String) -> URL? {
        cleanupOldZips(prefix: prefix)
        let fname = "\(prefix)_\(zipTimestamp()).zip"
        let url = tempDir.appendingPathComponent(fname)
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? ZipWriter(url: url) else { return nil }
        for name in names {
            guard let path = resolveWithin(name) else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = FileManager.default.enumerator(at: path,
                                                             includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { continue }
                while let f = e.nextObject() as? URL {
                    var d: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: f.path, isDirectory: &d), !d.boolValue else { continue }
                    let rel = relativePath(of: f, from: path)
                    try? writer.addFile(at: f, arcname: name + "/" + rel)
                }
            } else {
                try? writer.addFile(at: path, arcname: name)
            }
        }
        do {
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func relativePath(of file: URL, from base: URL) -> String {
        let bp = base.standardizedFileURL.path
        let fp = file.standardizedFileURL.path
        if fp.hasPrefix(bp + "/") { return String(fp.dropFirst(bp.count + 1)) }
        return file.lastPathComponent
    }

    private func zipTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    private func cleanupOldZips(prefix: String) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: tempDir.path)) ?? []
        for n in names where n.hasPrefix(prefix + "_") && n.hasSuffix(".zip") {
            let u = tempDir.appendingPathComponent(n)
            if let attrs = try? fm.attributesOfItem(atPath: u.path),
               let d = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(d) > 3600 {
                try? fm.removeItem(at: u)
            }
        }
    }
}
