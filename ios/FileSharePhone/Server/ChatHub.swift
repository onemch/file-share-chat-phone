import Foundation

/// 群聊中枢：线程安全的客户端集合、聊天历史、广播。
/// 与 Python `server.py` 中 clients / chat_history / broadcast 行为一致。
final class ChatHub {

    private var clients: [String: WebSocketConnection] = [:]
    private var history: [[String: Any]] = []
    private let lock = NSLock()
    private let maxHistory = 100

    var onlineCount: Int {
        lock.lock(); defer { lock.unlock() }
        return clients.count
    }

    func add(_ ws: WebSocketConnection) {
        // 先挂上回调，避免极早断开时漏掉离开广播
        ws.onText = { [weak self] text in
            self?.handleText(text, id: ws.id, nick: ws.nick)
        }
        ws.onClose = { [weak self] id in
            self?.remove(id: id, nick: ws.nick)
        }

        lock.lock()
        clients[ws.id] = ws
        let count = clients.count
        let users = clients.values.map { $0.nick }
        lock.unlock()

        ws.send(jsonString([
            "type": "welcome",
            "user_id": ws.id,
            "nick": ws.nick,
            "online_count": count,
            "users": users,
        ]))

        // 最近 100 条历史回放：只回放 chat / file_shared，不回放 system
        lock.lock()
        let replay = history.filter {
            let t = $0["type"] as? String
            return t == "chat" || t == "file_shared"
        }
        lock.unlock()
        for msg in replay { ws.send(jsonString(msg)) }

        let sys: [String: Any] = [
            "type": "system",
            "message": "\(ws.nick) 加入了共享",
            "timestamp": isoTimestamp(),
            "online_count": count,
            "users": users,
        ]
        pushHistory(sys)
        broadcast(sys, exclude: ws.id)
    }

    private func remove(id: String, nick: String) {
        lock.lock()
        let existed = clients.removeValue(forKey: id) != nil
        let count = clients.count
        let users = clients.values.map { $0.nick }
        lock.unlock()
        guard existed else { return }

        let leave: [String: Any] = [
            "type": "system",
            "message": "\(nick) 离开了共享",
            "timestamp": isoTimestamp(),
            "online_count": count,
            "users": users,
        ]
        pushHistory(leave)
        broadcast(leave, exclude: nil)
    }

    private func handleText(_ text: String, id: String, nick: String) {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = obj["type"] as? String,
              kind == "chat" || kind == "file_shared" else { return }

        var message = ""
        if let s = obj["message"] as? String { message = s }
        else if let n = obj["message"] as? NSNumber { message = n.stringValue }
        message = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !message.isEmpty else { return }

        let msg: [String: Any] = [
            "type": kind,
            "user_id": id,
            "nick": nick,
            "message": message,
            "timestamp": isoTimestamp(),
        ]
        if kind == "chat" { pushHistory(msg) }
        broadcast(msg, exclude: id)   // 不回发发送者
    }

    /// 广播给所有客户端（可排除发送者）。发送失败的客户端由 WebSocketConnection.onClose 移除。
    func broadcast(_ message: [String: Any], exclude senderID: String? = nil) {
        let payload = jsonString(message)
        lock.lock()
        let targets = clients.values.filter { $0.id != senderID }
        lock.unlock()
        for t in targets { t.send(payload) }
    }

    /// 任意上传 / 删除后通知所有客户端刷新文件列表。
    func notifyFilesChanged() {
        broadcast(["type": "files_changed"])
    }

    private func pushHistory(_ message: [String: Any]) {
        lock.lock()
        history.append(message)
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
        lock.unlock()
    }

    static func makeUserID() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "dev-" + String(raw.prefix(12))
    }

    /// 与 Python `clean_nick` 等价：兼容未编码的 UTF-8 昵称、去控制字符、截 20 字。
    static func cleanNick(_ raw: String?) -> String {
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        s = String(s.prefix(20))
        let scalars = Array(s.unicodeScalars)
        if scalars.allSatisfy({ $0.value <= 0xFF }),
           scalars.contains(where: { $0.value >= 0x80 && $0.value <= 0xFF }) {
            let bytes = scalars.map { UInt8($0.value) }
            if let fixed = String(bytes: bytes, encoding: .utf8) { s = fixed }
        }
        s = s.components(separatedBy: .controlCharacters).joined()
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(s.prefix(20))
    }
}
