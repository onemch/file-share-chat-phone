import Foundation

/// 路由分发：与 `server.py` 的 Flask 路由一一对应。
final class Router {

    unowned let server: FileShareServer

    private var store: FileStore { server.fileStore }
    private var chat: ChatHub { server.chat }
    private var wwwDir: URL { server.wwwDir }

    private let rootAssets: Set<String> = [
        "/manifest.webmanifest", "/sw.js", "/icon-192.png",
        "/icon-512.png", "/apple-touch-icon.png", "/favicon.ico",
    ]

    init(server: FileShareServer) {
        self.server = server
    }

    // MARK: - 请求分发

    func handle(_ req: HTTPRequest, body: Data, connection: HTTPConnection) -> HTTPResponse {
        let path = req.path

        switch req.method {
        case "GET":
            if path == "/" { return serveStatic("index.html") }
            if path.hasPrefix("/static/") { return serveStaticPath(path) }
            if rootAssets.contains(path) { return serveRootAsset(path) }
            if path == "/qr.png" { return .notFound }   // 前端会自动隐藏二维码卡片
            if path == "/health" { return health() }
            if path == "/files" { return .json(store.listItems()) }
            if path == "/download-selected" { return downloadSelected(req) }
            if path == "/download-all" { return downloadAll() }
            if path.hasPrefix("/download/") { return downloadOrPreview(req, attachment: true, prefix: "/download/") }
            if path.hasPrefix("/preview/") { return downloadOrPreview(req, attachment: false, prefix: "/preview/") }
            if path == "/chat" {
                return .json(["success": false, "message": "需要 WebSocket 升级"], status: 400)
            }
            return .notFound

        case "DELETE":
            if path.hasPrefix("/delete/") { return deleteOne(req) }
            return .notFound

        case "POST":
            if path == "/upload" || path == "/upload-folder" {
                // 正常路径走 multipart（见 configureMultipart）；这里处理非 multipart 的兜底
                return .json(["success": false, "message": "需要 multipart/form-data"], status: 400)
            }
            if path == "/delete-selected" { return deleteSelected(req, body: body) }
            if path == "/clear-download" { return clearDownload() }
            return .notFound

        default:
            return .notFound
        }
    }

    // MARK: - multipart 上传

    func configureMultipart(_ parser: MultipartParser, request: HTTPRequest,
                            connection: HTTPConnection) {
        let isFolder = request.path == "/upload-folder"
        parser.onFinish = { [weak self, weak connection] parts in
            guard let self = self else { return }
            let response = isFolder
                ? self.handleFolderUpload(parts: parts)
                : self.handleFileUpload(parts: parts)
            connection?.send(response)
        }
    }

    private func handleFileUpload(parts: [MultipartParser.Part]) -> HTTPResponse {
        let files = parts.filter { p in
            p.tempURL != nil &&
            (p.name == "file" || p.name == "files[]") &&
            (p.fileName?.isEmpty == false)
        }
        guard !files.isEmpty else {
            cleanupTemps(parts)
            return .json(["success": false, "message": "没有选择文件"], status: 400)
        }

        var saved: [String] = []
        var failed: [String] = []
        for p in files {
            guard let raw = p.fileName,
                  let name = store.safeBasename(raw),
                  let temp = p.tempURL else {
                if let raw = p.fileName { failed.append(raw) }
                continue
            }
            let finalName = store.uniqueName(for: name)
            let dest = store.shareDir.appendingPathComponent(finalName)
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
                saved.append(finalName)
            } catch {
                failed.append("\(finalName): \(error.localizedDescription)")
            }
        }
        cleanupTemps(parts)

        guard !saved.isEmpty else {
            return .json(["success": false, "message": "上传失败", "failed": failed], status: 500)
        }
        server.notifyFilesChanged()
        return .json([
            "success": true,
            "message": "上传成功 \(saved.count) 个文件",
            "filenames": saved,
            "failed": failed,
        ])
    }

    private func handleFolderUpload(parts: [MultipartParser.Part]) -> HTTPResponse {
        let fileParts = parts.filter { p in
            p.tempURL != nil &&
            (p.name == "files[]" || p.name == "folder[]") &&
            (p.fileName?.isEmpty == false)
        }
        guard !fileParts.isEmpty else {
            cleanupTemps(parts)
            return .json(["success": false, "message": "文件夹为空"], status: 400)
        }

        let folderField = parts.first { $0.name == "folder_name" && $0.tempURL == nil }?.textValue
        let folderName = store.safeBasename(folderField ?? "") ?? "上传文件夹"
        let finalFolder = store.uniqueFolderName(for: folderName)
        let folderPath = store.shareDir.appendingPathComponent(finalFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderPath, withIntermediateDirectories: true)
        } catch {
            cleanupTemps(parts)
            return .json(["success": false, "message": error.localizedDescription], status: 500)
        }

        var count = 0
        let basePath = folderPath.standardizedFileURL.path
        for p in fileParts {
            guard let raw = p.fileName,
                  let relParts = store.safeRelativeParts(raw),
                  let temp = p.tempURL else { continue }
            var dest = folderPath
            for seg in relParts { dest.appendPathComponent(seg) }
            let standardized = dest.standardizedFileURL
            guard standardized.path.hasPrefix(basePath + "/") else { continue } // 防路径穿越
            do {
                try FileManager.default.createDirectory(at: standardized.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: standardized)
                try FileManager.default.moveItem(at: temp, to: standardized)
                count += 1
            } catch {
                // 单个文件失败不影响其余
            }
        }
        cleanupTemps(parts)
        server.notifyFilesChanged()
        return .json([
            "success": true,
            "message": "文件夹上传成功，共 \(count) 个文件",
            "folder_name": finalFolder,
        ])
    }

    private func cleanupTemps(_ parts: [MultipartParser.Part]) {
        for p in parts {
            if let u = p.tempURL { try? FileManager.default.removeItem(at: u) }
        }
    }

    // MARK: - 静态资源

    private func serveStatic(_ name: String) -> HTTPResponse {
        let url = wwwDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return .notFound }
        return .data(data, mime: mimeType(for: name))
    }

    private func serveStaticPath(_ path: String) -> HTTPResponse {
        let name = String(path.dropFirst("/static/".count))
        guard !name.isEmpty, !name.hasPrefix("."), isValidStaticName(name) else { return .notFound }
        return serveStatic(name)
    }

    private func serveRootAsset(_ path: String) -> HTTPResponse {
        var name = String(path.dropFirst())
        if name == "favicon.ico" { name = "icon-192.png" }
        var extra: [String: String] = [:]
        if name == "sw.js" { extra["Service-Worker-Allowed"] = "/" }
        let url = wwwDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return .notFound }
        return .data(data, mime: mimeType(for: name), extra: extra)
    }

    private func isValidStaticName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - 状态 / 列表

    private func health() -> HTTPResponse {
        let count = (try? FileManager.default.contentsOfDirectory(atPath: store.shareDir.path))?.count ?? 0
        return .json([
            "ok": true,
            "app": "文件共享中心 · 手机版",
            "version": "1.0",
            "time": isoTimestamp(),
            "lan_ip": server.lanIP,
            "port": Int(server.port),
            "online": chat.onlineCount,
            "items": count,
        ])
    }

    // MARK: - 下载 / 预览

    private func downloadOrPreview(_ req: HTTPRequest, attachment: Bool,
                                   prefix: String) -> HTTPResponse {
        let name = String(req.path.dropFirst(prefix.count))
        guard let path = store.resolveWithin(name) else {
            return .json(["success": false, "message": "文件不存在"], status: 404)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) else {
            return .json(["success": false, "message": "文件不存在"], status: 404)
        }
        if isDir.boolValue {
            guard attachment else {
                return .json(["success": false, "message": "文件不存在"], status: 404)
            }
            guard let zip = store.makeZip(names: [name], prefix: "folder") else { return .serverError }
            let downloadName = path.lastPathComponent + ".zip"
            return .file(zip, mime: "application/zip",
                         disposition: contentDisposition(attachment: true, filename: downloadName),
                         cleanup: zip)
        }
        var extra: [String: String] = [:]
        if !attachment { extra["Cache-Control"] = "no-store" }
        return .file(path, mime: mimeType(for: path.lastPathComponent),
                     disposition: contentDisposition(attachment: attachment,
                                                    filename: path.lastPathComponent),
                     extra: extra)
    }

    private func downloadSelected(_ req: HTTPRequest) -> HTTPResponse {
        let names = parseNames(req, body: Data())
        guard !names.isEmpty else {
            return .json(["success": false, "message": "未选择任何项目"], status: 400)
        }
        let existing = names.filter { n in
            guard let u = store.resolveWithin(n) else { return false }
            return FileManager.default.fileExists(atPath: u.path)
        }
        guard !existing.isEmpty else {
            return .json(["success": false, "message": "选中的项目不存在"], status: 404)
        }
        guard let zip = store.makeZip(names: existing, prefix: "selected") else { return .serverError }
        return .file(zip, mime: "application/zip",
                     disposition: contentDisposition(attachment: true, filename: zip.lastPathComponent),
                     cleanup: zip)
    }

    private func downloadAll() -> HTTPResponse {
        let names = store.topLevelNames()
        guard !names.isEmpty else {
            return .json(["success": false, "message": "暂无可下载的文件"], status: 404)
        }
        guard let zip = store.makeZip(names: names, prefix: "files") else { return .serverError }
        return .file(zip, mime: "application/zip",
                     disposition: contentDisposition(attachment: true, filename: zip.lastPathComponent),
                     cleanup: zip)
    }

    // MARK: - 删除

    private func deleteSelected(_ req: HTTPRequest, body: Data) -> HTTPResponse {
        let names = parseNames(req, body: body)
        guard !names.isEmpty else {
            return .json(["success": false, "message": "未选择任何项目"], status: 400)
        }
        var deleted = 0
        var failed: [String] = []
        for n in names {
            if store.removeItem(named: n) { deleted += 1 } else { failed.append(n) }
        }
        if deleted > 0 { server.notifyFilesChanged() }
        let ok = deleted > 0
        return .json([
            "success": ok,
            "deleted": deleted,
            "failed": failed,
            "message": ok ? "成功删除 \(deleted) 个项目" : "删除失败",
        ])
    }

    private func deleteOne(_ req: HTTPRequest) -> HTTPResponse {
        let name = String(req.path.dropFirst("/delete/".count))
        guard let path = store.resolveWithin(name),
              FileManager.default.fileExists(atPath: path.path) else {
            return .json(["success": false, "message": "文件不存在"], status: 404)
        }
        do {
            try FileManager.default.removeItem(at: path)
            server.notifyFilesChanged()
            return .json(["success": true, "message": "删除成功"])
        } catch {
            return .json(["success": false, "message": error.localizedDescription], status: 500)
        }
    }

    private func clearDownload() -> HTTPResponse {
        let n = store.clearAll()
        server.notifyFilesChanged()
        return .json(["success": true, "message": "已清空 \(n) 个项目"])
    }

    // MARK: - 名称解析

    private func parseNames(_ req: HTTPRequest, body: Data) -> [String] {
        var raws: [String] = []
        if req.method == "POST" {
            if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                if let arr = obj["names"] as? [Any] {
                    raws = arr.compactMap { $0 as? String }
                } else if let s = obj["names"] as? String {
                    raws = [s]
                }
            }
        } else {
            let q = req.queryValues("name")
            if !q.isEmpty {
                raws = q
            } else {
                let joined = req.queryValues("names").first ?? ""
                raws = joined.components(separatedBy: .newlines).filter { !$0.isEmpty }
            }
        }

        var result: [String] = []
        var seen = Set<String>()
        for r in raws {
            guard let name = store.safeBasename(r),
                  !seen.contains(name),
                  store.resolveWithin(name) != nil else { continue }
            seen.insert(name)
            result.append(name)
        }
        return result
    }
}
