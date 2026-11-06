import Foundation

/// 流式 multipart/form-data 解析器。
/// 每收到一段 body 就 `feed` 一次：文件 part 直接流式写入临时文件，
/// 文本 part 收集到内存（上限 1MB）。**不会把大文件整块读进内存**。
/// 解析完成后 `onFinish` 回调给出全部 part。
final class MultipartParser {

    struct Part {
        var headers: [String: String] = [:]
        var name: String?
        var fileName: String?
        var contentType: String?
        var tempURL: URL?       // 文件 part 的暂存路径
        var textValue: String?  // 文本 part 的值
    }

    private enum State {
        case preamble   // 等待首个 --boundary
        case headers    // 等待 part 的 \r\n\r\n
        case body       // 流式写 part 内容，直到 \r\n--boundary
        case suffix     // 已吃掉 \r\n--boundary，等待 "--" 或 "\r\n"
        case done
    }

    private let boundaryLine: Data   // "--" + boundary
    private let delimiter: Data      // "\r\n--" + boundary
    private let crlfCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])
    private let tempDir: URL

    private var buffer = Data()
    private var state: State = .preamble
    private var parts: [Part] = []
    private var current = Part()
    private var partOpen = false
    private var currentHandle: FileHandle?
    private var currentText = Data()
    private let textLimit = 1024 * 1024
    private var finished = false

    /// 全部 part 解析完成后调用（恰好一次）。
    var onFinish: (([Part]) -> Void)?

    init?(boundary: String, tempDir: URL) {
        let b = boundary.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return nil }
        boundaryLine = Data(("--" + b).utf8)
        delimiter = Data(("\r\n--" + b).utf8)
        self.tempDir = tempDir
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func feed(_ data: Data) {
        guard !finished, !data.isEmpty else { return }
        buffer.append(data)
        drain()
    }

    /// Content-Length 已全部收齐时调用；正常情况下 closing boundary 已在 feed 中处理完。
    func finish() {
        complete()
    }

    // MARK: - 状态机

    private func drain() {
        while !finished {
            switch state {
            case .preamble:
                guard let r = dataRange(of: boundaryLine, in: buffer) else {
                    // 只保留可能构成半个 boundary 的尾部
                    trimPreamble(keeping: boundaryLine.count - 1)
                    return
                }
                let after = r.upperBound
                if buffer.count < after + 2 {
                    if r.lowerBound > 0 { buffer.removeSubrange(0..<r.lowerBound) }
                    return
                }
                let b0 = buffer[after]
                let b1 = buffer[after + 1]
                if b0 == 0x2D && b1 == 0x2D {         // "--" → 没有任何 part
                    buffer.removeSubrange(0..<after + 2)
                    complete()
                    return
                }
                if b0 == 0x0D && b1 == 0x0A {          // "\r\n" → 进入 part headers
                    buffer.removeSubrange(0..<after + 2)
                    state = .headers
                    continue
                }
                buffer.removeSubrange(0..<after)        // 畸形，跳过该处继续找
                continue

            case .headers:
                guard let r = dataRange(of: crlfCRLF, in: buffer) else { return }
                let raw = Data(buffer[0..<r.lowerBound])
                buffer.removeSubrange(0..<r.upperBound)
                parseHeaders(raw)
                openCurrent()
                state = .body
                continue

            case .body:
                guard let r = dataRange(of: delimiter, in: buffer) else {
                    // 尾部保留 delimiter.count-1 字节，防止 boundary 被拆在两个 chunk 里
                    let keep = delimiter.count - 1
                    if buffer.count > keep {
                        let n = buffer.count - keep
                        writeCurrent(Data(buffer[0..<n]))
                        buffer.removeSubrange(0..<n)
                    }
                    return
                }
                writeCurrent(Data(buffer[0..<r.lowerBound]))
                buffer.removeSubrange(0..<r.upperBound)  // 吃掉 \r\n--boundary（CRLF 不属于文件内容）
                closeCurrent()
                state = .suffix
                continue

            case .suffix:
                if buffer.count < 2 { return }
                let b0 = buffer[0]
                let b1 = buffer[1]
                buffer.removeSubrange(0..<2)
                if b0 == 0x2D && b1 == 0x2D {          // 结束
                    complete()
                    return
                }
                if b0 == 0x0D && b1 == 0x0A {          // 下一个 part
                    state = .headers
                    continue
                }
                complete()                              // 异常，按结束处理
                return

            case .done:
                return
            }
        }
    }

    private func trimPreamble(keeping: Int) {
        guard keeping > 0 else { buffer.removeAll(); return }
        if buffer.count > keeping {
            buffer.removeSubrange(0..<(buffer.count - keeping))
        }
    }

    // MARK: - part 解析

    private func parseHeaders(_ raw: Data) {
        current = Part()
        let text = String(data: raw, encoding: .utf8) ?? ""
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            current.headers[key] = value
        }
        if let cd = current.headers["content-disposition"] {
            current.name = headerParam(cd, key: "name")
            var fn = headerParam(cd, key: "filename")
            if fn == nil { fn = encodedHeaderParam(cd, key: "filename") }
            current.fileName = fn
        }
        current.contentType = current.headers["content-type"]
    }

    private func openCurrent() {
        currentText = Data()
        let isFile = (current.fileName?.isEmpty == false)
        if isFile {
            let u = tempDir.appendingPathComponent("up_" + UUID().uuidString + ".part")
            FileManager.default.createFile(atPath: u.path, contents: nil)
            currentHandle = try? FileHandle(forWritingTo: u)
            current.tempURL = u
        } else {
            currentHandle = nil
            current.tempURL = nil
        }
        partOpen = true
    }

    private func writeCurrent(_ data: Data) {
        guard !data.isEmpty else { return }
        if let h = currentHandle {
            try? h.write(contentsOf: data)
        } else if currentText.count < textLimit {
            currentText.append(data)
        }
    }

    private func closeCurrent() {
        guard partOpen else { return }
        partOpen = false
        if let h = currentHandle {
            try? h.close()
            currentHandle = nil
            parts.append(current)
        } else {
            current.textValue = String(data: currentText, encoding: .utf8)
            parts.append(current)
        }
        current = Part()
        currentText = Data()
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        if state != .done { closeCurrent() }
        state = .done
        buffer.removeAll()
        onFinish?(parts)
    }
}
