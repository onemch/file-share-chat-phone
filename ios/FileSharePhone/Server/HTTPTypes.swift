import Foundation

// MARK: - 通用工具

/// 与 Python `datetime.now().isoformat(timespec='seconds')` 等价的本地时间字符串。
func isoTimestamp(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f.string(from: date)
}

/// 在 Data 中查找子序列首次出现的位置（边界串很短，朴素搜索足够）。
/// 自己实现以避免不同 Foundation 版本上 `Data.range(of:)` 的可用性差异。
func dataRange(of needle: Data, in haystack: Data) -> Range<Int>? {
    let h = Array(haystack)      // 统一为下标从 0 开始的字节数组，避免 Data 切片下标偏移
    let nb = Array(needle)
    let n = nb.count
    let m = h.count
    guard n > 0, m >= n else { return nil }
    let first = nb[0]
    var i = 0
    while i <= m - n {
        if h[i] != first {
            i += 1
            continue
        }
        var j = 1
        while j < n && h[i + j] == nb[j] { j += 1 }
        if j == n { return i..<(i + n) }
        i += 1
    }
    return nil
}

/// 与 Python `datetime.now().strftime('%Y-%m-%d %H:%M')` 等价。
func displayTimestamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

func humanSize(_ size: UInt64) -> String {
    let d = Double(size)
    if size < 1024 { return "\(size) B" }
    if size < 1024 * 1024 { return String(format: "%.2f KB", d / 1024.0) }
    if size < 1024 * 1024 * 1024 { return String(format: "%.2f MB", d / 1048576.0) }
    return String(format: "%.2f GB", d / 1073741824.0)
}

/// 百分号解码。`+` 是否按空格处理：查询串按空格，路径不按。
func percentDecode(_ input: String, plusAsSpace: Bool) -> String {
    let bytes = Array(input.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if b == 0x25, i + 2 < bytes.count,
           let hi = hexDigit(bytes[i + 1]), let lo = hexDigit(bytes[i + 2]) {
            out.append(hi << 4 | lo)
            i += 3
        } else if b == 0x2B, plusAsSpace {
            out.append(0x20)
            i += 1
        } else {
            out.append(b)
            i += 1
        }
    }
    return String(bytes: out, encoding: .utf8) ?? String(decoding: out, as: UTF8.self)
}

private func hexDigit(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: return b - 0x30
    case 0x41...0x46: return b - 0x41 + 10
    case 0x61...0x66: return b - 0x61 + 10
    default: return nil
    }
}

/// 根据扩展名推断 Content-Type，与 Flask `send_from_directory` 的行为接近。
func mimeType(for filename: String) -> String {
    let ext = (filename as NSString).pathExtension.lowercased()
    switch ext {
    case "html", "htm": return "text/html; charset=utf-8"
    case "css": return "text/css; charset=utf-8"
    case "js", "mjs": return "application/javascript; charset=utf-8"
    case "json": return "application/json; charset=utf-8"
    case "webmanifest", "manifest": return "application/manifest+json"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "bmp": return "image/bmp"
    case "heic": return "image/heic"
    case "svg": return "image/svg+xml"
    case "ico": return "image/x-icon"
    case "pdf": return "application/pdf"
    case "txt", "md", "log": return "text/plain; charset=utf-8"
    case "mp4", "m4v", "mov": return "video/mp4"
    case "webm": return "video/webm"
    case "mp3": return "audio/mpeg"
    case "wav": return "audio/wav"
    case "m4a", "aac": return "audio/aac"
    case "flac": return "audio/flac"
    case "ogg": return "audio/ogg"
    case "zip": return "application/zip"
    default: return "application/octet-stream"
    }
}

/// 生成 `Content-Disposition`，同时提供 ASCII 回退与 RFC 5987 `filename*`（中文文件名）。
func contentDisposition(attachment: Bool, filename: String) -> String {
    var ascii = ""
    for ch in filename.unicodeScalars {
        if ch.value >= 0x20 && ch.value < 0x7F && ch.value != 0x22 && ch.value != 0x5C {
            ascii.unicodeScalars.append(ch)
        } else {
            ascii.append("_")
        }
    }
    if ascii.isEmpty { ascii = "download" }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let encoded = filename.addingPercentEncoding(withAllowedCharacters: allowed) ?? "download"
    let type = attachment ? "attachment" : "inline"
    return "\(type); filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
}

func jsonData(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
}

func jsonString(_ object: Any) -> String {
    String(data: jsonData(object), encoding: .utf8) ?? "{}"
}

// MARK: - HTTP 请求

struct HTTPQueryItem {
    let name: String
    let value: String
}

struct HTTPRequest {
    var method: String = "GET"
    var path: String = "/"              // 已做百分号解码（+ 不转空格）
    var version: String = "HTTP/1.1"
    var headers: [String: String] = [:] // key 全小写
    var query: [HTTPQueryItem] = []
    var contentLength: Int = 0
    var contentType: String = ""
    var boundary: String?
    var webSocketKey: String?
    var isWebSocketUpgrade: Bool = false
    var expectContinue: Bool = false

    static func parse(_ raw: Data) -> HTTPRequest? {
        guard let text = String(data: raw, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        var req = HTTPRequest()
        req.method = String(parts[0]).uppercased()
        req.version = parts.count >= 3 ? String(parts[2]) : "HTTP/1.1"
        let target = String(parts[1])

        let qMark = target.firstIndex(of: "?")
        let rawPath = qMark.map { String(target[..<$0]) } ?? target
        req.path = percentDecode(rawPath, plusAsSpace: false)
        if let q = qMark {
            let rawQuery = String(target[target.index(after: q)...])
            for pair in rawQuery.components(separatedBy: "&") where !pair.isEmpty {
                let eq = pair.firstIndex(of: "=")
                let k = eq.map { String(pair[..<$0]) } ?? pair
                let v = eq.map { String(pair[pair.index(after: $0)...]) } ?? ""
                req.query.append(HTTPQueryItem(
                    name: percentDecode(k, plusAsSpace: true),
                    value: percentDecode(v, plusAsSpace: true)))
            }
        }

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            req.headers[key] = value
        }

        if let cl = req.headers["content-length"], let n = Int(cl), n > 0 {
            req.contentLength = n
        }
        req.contentType = req.headers["content-type"] ?? ""
        if req.contentType.lowercased().hasPrefix("multipart/form-data") {
            req.boundary = boundaryFromContentType(req.contentType)
        }
        let upgrade = (req.headers["upgrade"] ?? "").lowercased()
        let connection = (req.headers["connection"] ?? "").lowercased()
        req.isWebSocketUpgrade = upgrade == "websocket" && connection.contains("upgrade")
        req.webSocketKey = req.headers["sec-websocket-key"]
        req.expectContinue = (req.headers["expect"] ?? "").lowercased().contains("100-continue")
        return req
    }

    func queryValues(_ name: String) -> [String] {
        query.filter { $0.name == name }.map { $0.value }
    }

    /// 解析 `Access-Control-Request-Headers`，没有则回退 `*`。
    var requestedHeaders: String {
        headers["access-control-request-headers"] ?? "*"
    }
}

private func boundaryFromContentType(_ ct: String) -> String? {
    for seg in splitHeaderParams(ct) {
        let s = seg.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("boundary=") {
            var v = String(s.dropFirst("boundary=".count)).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.count >= 2 {
                v = String(v.dropFirst())
                if let end = v.firstIndex(of: "\"") { v = String(v[..<end]) }
            }
            return v.isEmpty ? nil : v
        }
    }
    return nil
}

/// 按 `;` 切分但保留引号内的分号（Content-Disposition / Content-Type 解析用）。
func splitHeaderParams(_ value: String) -> [String] {
    var result: [String] = []
    var current = ""
    var inQuote = false
    var i = value.startIndex
    while i < value.endIndex {
        let c = value[i]
        if c == "\"" {
            inQuote.toggle()
            current.append(c)
        } else if c == ";" && !inQuote {
            result.append(current)
            current = ""
        } else {
            current.append(c)
        }
        i = value.index(after: i)
    }
    result.append(current)
    return result
}

/// 从 `Content-Disposition` 中取 `name=` / `filename=` 参数（支持引号与中文）。
func headerParam(_ contentDisposition: String, key: String) -> String? {
    for seg in splitHeaderParams(contentDisposition) {
        let s = seg.trimmingCharacters(in: .whitespaces)
        guard s.lowercased().hasPrefix(key.lowercased() + "=") else { continue }
        var v = String(s.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") {
            v = String(v.dropFirst())
            if let end = v.firstIndex(of: "\"") { v = String(v[..<end]) }
            return v
        }
        if let semi = v.firstIndex(of: ";") { v = String(v[..<semi]) }
        return v.trimmingCharacters(in: .whitespaces)
    }
    return nil
}

/// 兼容 `filename*=UTF-8''%E4%B8%AD%E6%96%87.txt`。
func encodedHeaderParam(_ contentDisposition: String, key: String) -> String? {
    for seg in splitHeaderParams(contentDisposition) {
        let s = seg.trimmingCharacters(in: .whitespaces)
        guard s.lowercased().hasPrefix(key.lowercased() + "*=") else { continue }
        var v = String(s.dropFirst(key.count + 2)).trimmingCharacters(in: .whitespaces)
        if let apos = v.firstIndex(of: "'") {
            let rest = String(v[v.index(after: apos)...])
            if let apos2 = rest.firstIndex(of: "'") {
                v = String(rest[rest.index(after: apos2)...])
            }
        }
        return percentDecode(v, plusAsSpace: false)
    }
    return nil
}

// MARK: - HTTP 响应

struct HTTPResponse {
    var status: Int = 200
    var reason: String = "OK"
    var headers: [String: String] = [:]
    var body: Data = Data()
    var fileURL: URL?
    var cleanupURL: URL?
    var isWebSocketHandshake: Bool = false

    static func statusReason(_ code: Int) -> String {
        switch code {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }

    init(status: Int = 200, reason: String? = nil) {
        self.status = status
        self.reason = reason ?? HTTPResponse.statusReason(status)
    }

    mutating func set(_ key: String, _ value: String) {
        headers[key] = value
    }

    /// 序列化状态行 + 头部（不含 body）。
    func headerData() -> Data {
        var s = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in headers {
            s += "\(k): \(v)\r\n"
        }
        s += "\r\n"
        return Data(s.utf8)
    }

    static func json(_ object: Any, status: Int = 200, extra: [String: String] = [:]) -> HTTPResponse {
        var r = HTTPResponse(status: status)
        let body = jsonData(object)
        r.body = body
        r.set("Content-Type", "application/json; charset=utf-8")
        r.set("Content-Length", "\(body.count)")
        r.set("Cache-Control", "no-cache")
        for (k, v) in extra { r.set(k, v) }
        return r
    }

    static func data(_ data: Data, mime: String, extra: [String: String] = [:]) -> HTTPResponse {
        var r = HTTPResponse()
        r.body = data
        r.set("Content-Type", mime)
        r.set("Content-Length", "\(data.count)")
        r.set("Cache-Control", "no-cache")
        for (k, v) in extra { r.set(k, v) }
        return r
    }

    static func file(_ url: URL, mime: String, disposition: String?, extra: [String: String] = [:], cleanup: URL? = nil) -> HTTPResponse {
        var r = HTTPResponse()
        r.fileURL = url
        r.cleanupURL = cleanup
        r.set("Content-Type", mime)
        if let d = disposition { r.set("Content-Disposition", d) }
        for (k, v) in extra { r.set(k, v) }
        return r
    }

    static var notFound: HTTPResponse {
        .json(["success": false, "message": "Not Found"], status: 404)
    }

    static var badRequest: HTTPResponse {
        .json(["success": false, "message": "Bad Request"], status: 400)
    }

    static var serverError: HTTPResponse {
        .json(["success": false, "message": "Internal Server Error"], status: 500)
    }
}
