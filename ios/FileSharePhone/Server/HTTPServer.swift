import Foundation
import Network

extension Notification.Name {
    static let fileShareServerStatus = Notification.Name("FileShareServerStatusDidChange")
}

// MARK: - 服务主体

/// 内嵌 HTTP + WebSocket 服务端。仅用系统框架 Network.framework。
final class FileShareServer {

    let port: UInt16 = 5000
    let fileStore = FileStore()
    let chat = ChatHub()
    let wwwDir: URL

    private(set) var lanIP: String = "127.0.0.1"
    private(set) var isRunning: Bool = false
    private(set) var statusNote: String = ""

    private let queue = DispatchQueue(label: "com.fileshare.phone.server", qos: .userInitiated)
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    lazy var router: Router = Router(server: self)

    init() {
        wwwDir = FileShareServer.resolveWWWDir()
        lanIP = localLANIPv4()
    }

    var displayAddress: String { "http://\(lanIP):\(port)" }
    var loopbackAddress: String { "http://127.0.0.1:\(port)/" }

    /// 定位 bundle 中的 www 目录（pbxproj 中作为 folder reference 复制到 bundle 根）。
    private static func resolveWWWDir() -> URL {
        let candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("www", isDirectory: true),
            (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("www", isDirectory: true),
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c.appendingPathComponent("index.html").path) {
                return c
            }
        }
        if let u = Bundle.main.url(forResource: "index", withExtension: "html") {
            return u.deletingLastPathComponent()
        }
        return Bundle.main.bundleURL
    }

    // MARK: - 生命周期

    func start() {
        stateLock.lock()
        let already = (listener != nil || isRunning)
        stateLock.unlock()
        if already {
            postStatus()
            return
        }

        lanIP = localLANIPv4()
        do {
            let parameters = NWParameters.tcp
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw NSError(domain: "FileShareServer", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "无效端口"])
            }
            let l = try NWListener(using: parameters, on: nwPort)
            stateLock.lock()
            listener = l
            stateLock.unlock()

            l.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                self.accept(connection)
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                self.listenerDidChange(state)
            }
            l.start(queue: queue)
        } catch {
            statusNote = "启动失败：\(error.localizedDescription)"
            postStatus(running: false)
        }
    }

    func stop() {
        stateLock.lock()
        let l = listener
        listener = nil
        stateLock.unlock()
        l?.cancel()
        isRunning = false
        postStatus(running: false)
    }

    private func listenerDidChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            lanIP = localLANIPv4()
            isRunning = true
            statusNote = ""
            postStatus(running: true)
        case .failed(let error):
            isRunning = false
            statusNote = "监听失败：\(error.localizedDescription)"
            stateLock.lock(); listener = nil; stateLock.unlock()
            postStatus(running: false)
        case .waiting(let error):
            isRunning = false
            statusNote = "等待网络：\(error.localizedDescription)"
            postStatus(running: false)
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func postStatus(running: Bool? = nil) {
        let r = running ?? isRunning
        let addr = displayAddress
        let ip = lanIP
        let p = Int(port)
        let note = statusNote
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .fileShareServerStatus, object: self,
                userInfo: ["running": r, "address": addr, "lanIP": ip,
                           "port": p, "note": note])
        }
    }

    // MARK: - 连接管理

    private func accept(_ nw: NWConnection) {
        let conn = HTTPConnection(server: self, connection: nw, queue: queue)
        stateLock.lock()
        connections[ObjectIdentifier(conn)] = conn
        stateLock.unlock()
        conn.start()
    }

    func connectionDidClose(_ conn: HTTPConnection) {
        stateLock.lock()
        connections.removeValue(forKey: ObjectIdentifier(conn))
        stateLock.unlock()
    }

    /// 任一上传 / 删除成功后调用：通知所有在线客户端刷新列表。
    func notifyFilesChanged() {
        chat.notifyFilesChanged()
    }
}

// MARK: - 单条 TCP 连接

final class HTTPConnection {

    private enum Mode {
        case headers
        case fixedBody
        case multipart
        case websocket
        case closed
    }

    private let server: FileShareServer
    private let nw: NWConnection
    private let queue: DispatchQueue
    private let crlfCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private var buffer = Data()
    private var mode: Mode = .headers
    private var request: HTTPRequest?
    private var contentLength = 0
    private var bodyReceived = 0
    private var multipart: MultipartParser?
    private var webSocket: WebSocketConnection?
    private var responded = false
    private var terminated = false

    init(server: FileShareServer, connection: NWConnection, queue: DispatchQueue) {
        self.server = server
        self.nw = connection
        self.queue = queue
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveLoop()
            case .failed(_), .cancelled:
                self?.terminate()
            default:
                break
            }
        }
        nw.start(queue: queue)
    }

    private func receiveLoop() {
        guard !terminated else { return }
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { self.terminate(); return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.process()
            }
            if isComplete { self.terminate(); return }
            guard !self.terminated else { return }
            self.receiveLoop()
        }
    }

    // MARK: - 解析主循环

    private func process() {
        while true {
            switch mode {
            case .headers:
                guard let range = dataRange(of: crlfCRLF, in: buffer) else { return }
                let raw = Data(buffer[0..<range.lowerBound])
                buffer.removeSubrange(0..<range.upperBound)
                guard let req = HTTPRequest.parse(raw) else {
                    send(.badRequest)
                    return
                }
                request = req
                contentLength = req.contentLength
                bodyReceived = 0
                responded = false

                if req.isWebSocketUpgrade && req.path == "/chat" {
                    upgradeWebSocket(req)
                    continue
                }
                if req.method == "OPTIONS" {
                    send(optionsResponse(for: req))
                    return
                }
                if contentLength > 0, let boundary = req.boundary,
                   req.path == "/upload" || req.path == "/upload-folder" {
                    guard let parser = MultipartParser(boundary: boundary,
                                                       tempDir: server.fileStore.tempDir) else {
                        send(.badRequest)
                        return
                    }
                    multipart = parser
                    server.router.configureMultipart(parser, request: req, connection: self)
                    if req.expectContinue { send100Continue() }
                    mode = .multipart
                    continue
                }
                if req.expectContinue { send100Continue() }
                mode = .fixedBody
                continue

            case .fixedBody:
                let need = contentLength - bodyReceived
                if buffer.count >= need {
                    let body = need > 0 ? Data(buffer[0..<need]) : Data()
                    if need > 0 { buffer.removeSubrange(0..<need) }
                    bodyReceived += need
                    guard let req = request else { send(.serverError); return }
                    send(server.router.handle(req, body: body, connection: self))
                    return
                }
                return

            case .multipart:
                let need = contentLength - bodyReceived
                let take = min(need, buffer.count)
                if take > 0 {
                    let chunk = Data(buffer[0..<take])
                    buffer.removeSubrange(0..<take)
                    bodyReceived += take
                    multipart?.feed(chunk)
                }
                if bodyReceived >= contentLength {
                    multipart?.finish()   // 触发 onFinish → 发送响应
                    return
                }
                return

            case .websocket:
                guard let ws = webSocket else { return }
                let consumed = ws.consume(buffer)
                if consumed > 0 { buffer.removeSubrange(0..<consumed) }
                if consumed == 0 || ws.isClosed { return }
                continue

            case .closed:
                return
            }
        }
    }

    // MARK: - WebSocket 升级

    private func upgradeWebSocket(_ req: HTTPRequest) {
        guard let key = req.webSocketKey, !key.isEmpty else {
            send(.badRequest)
            return
        }
        var resp = HTTPResponse(status: 101)
        resp.isWebSocketHandshake = true
        resp.set("Upgrade", "websocket")
        resp.set("Connection", "Upgrade")
        resp.set("Sec-WebSocket-Accept", WebSocketFrame.acceptKey(for: key))
        resp.set("Access-Control-Allow-Origin", "*")
        // 101 响应无 body、无 Content-Length，且必须保持连接
        nw.send(content: resp.headerData(), completion: .idempotent)

        let nickRaw = req.queryValues("nick").first
        var nick = ChatHub.cleanNick(nickRaw)
        if nick.isEmpty { nick = "设备" }
        let ws = WebSocketConnection(id: ChatHub.makeUserID(), nick: nick,
                                     connection: nw, queue: queue)
        webSocket = ws
        mode = .websocket
        server.chat.add(ws)
    }

    // MARK: - 发送

    func send(_ response: HTTPResponse) {
        guard !responded, !terminated else { return }
        responded = true
        var resp = response
        resp.set("Access-Control-Allow-Origin", "*")
        resp.set("Connection", "close")

        if let fileURL = resp.fileURL {
            sendFile(fileURL, response: resp)
            return
        }
        resp.set("Content-Length", "\(resp.body.count)")
        let payload = resp.headerData() + resp.body
        nw.send(content: payload, completion: .contentProcessed { [weak self] _ in
            if let cleanup = resp.cleanupURL {
                try? FileManager.default.removeItem(at: cleanup)
            }
            self?.terminate()
        })
    }

    /// 文件直出：头部 + 64KB 分块流式发送，避免把大文件整块读进内存。
    private func sendFile(_ url: URL, response: HTTPResponse) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber else {
            var err = HTTPResponse.serverError
            err.set("Access-Control-Allow-Origin", "*")
            err.set("Connection", "close")
            err.set("Content-Length", "\(err.body.count)")
            nw.send(content: err.headerData() + err.body,
                    completion: .contentProcessed { [weak self] _ in self?.terminate() })
            return
        }

        var resp = response
        resp.set("Content-Length", "\(number.uint64Value)")
        // 每个 chunk 作为一条完整消息发出；TCP 是字节流，客户端只会看到连续的
        // header + 数据，不会看到消息边界，因此既能流式发送也不会整块占用内存。
        nw.send(content: resp.headerData(), completion: .idempotent)

        do {
            let handle = try FileHandle(forReadingFrom: url)
            while true {
                let chunk = handle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                nw.send(content: chunk, completion: .idempotent)
            }
            try? handle.close()
        } catch {
            // 读取失败时仍发送收尾消息，保证连接被正确关闭
        }

        // 最后一条空消息用 contentProcessed 等待前面所有 send 处理完毕，再关闭连接
        nw.send(content: Data(), completion: .contentProcessed { [weak self] _ in
            if let cleanup = resp.cleanupURL {
                try? FileManager.default.removeItem(at: cleanup)
            }
            self?.terminate()
        })
    }

    private func optionsResponse(for req: HTTPRequest) -> HTTPResponse {
        var r = HTTPResponse(status: 200)
        r.set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        r.set("Access-Control-Allow-Headers", req.requestedHeaders)
        r.set("Content-Type", "text/plain; charset=utf-8")
        r.set("Content-Length", "0")
        return r
    }

    private func send100Continue() {
        let data = Data("HTTP/1.1 100 Continue\r\nAccess-Control-Allow-Origin: *\r\n\r\n".utf8)
        nw.send(content: data, completion: .idempotent)
    }

    private func terminate() {
        guard !terminated else { return }
        terminated = true
        mode = .closed
        webSocket?.close(sendCloseFrame: false)
        nw.cancel()
        server.connectionDidClose(self)
    }
}
