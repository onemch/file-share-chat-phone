import Foundation
import Network
import CryptoKit

// MARK: - 帧编解码

enum WebSocketFrame {

    /// Sec-WebSocket-Key + GUID → SHA1 → Base64（RFC 6455）。
    static func acceptKey(for key: String) -> String {
        let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    /// 服务端发帧：FIN=1，不 mask（RFC 6455 规定服务端不得 mask）。
    static func serverFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F))
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((n >> 8) & 0xFF))
            frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(127)
            let v = UInt64(n)
            for i in (0..<8).reversed() {
                frame.append(UInt8((v >> UInt64(i * 8)) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }
}

// MARK: - 单个 WebSocket 连接

final class WebSocketConnection {

    let id: String
    let nick: String
    private let nw: NWConnection
    private let queue: DispatchQueue

    /// 收到完整文本消息时回调（由 ChatHub 设置）。
    var onText: ((String) -> Void)?
    /// 连接关闭时回调一次（由 ChatHub 设置），传回 id。
    var onClose: ((String) -> Void)?

    private var closed = false
    private var fragment = Data()
    private var fragmentOpcode: UInt8 = 0

    var isClosed: Bool { closed }

    init(id: String, nick: String, connection: NWConnection, queue: DispatchQueue) {
        self.id = id
        self.nick = nick
        self.nw = connection
        self.queue = queue
    }

    /// 从 buffer 中解析尽可能多的完整帧，返回已消费的字节数。
    /// 客户端帧必须带 mask；支持 7/16/64 位长度、分片、ping/pong/close。
    func consume(_ buffer: Data) -> Int {
        var index = 0
        while !closed {
            let remaining = buffer.count - index
            if remaining < 2 { break }

            let b0 = buffer[index]
            let b1 = buffer[index + 1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var length = Int(b1 & 0x7F)
            var headerLength = 2

            if length == 126 {
                if remaining < 4 { break }
                length = (Int(buffer[index + 2]) << 8) | Int(buffer[index + 3])
                headerLength = 4
            } else if length == 127 {
                if remaining < 10 { break }
                var v: UInt64 = 0
                for i in 0..<8 { v = (v << 8) | UInt64(buffer[index + 2 + i]) }
                guard v <= UInt64(Int.max) else { break }
                length = Int(v)
                headerLength = 10
            }

            let maskLength = masked ? 4 : 0
            let total = headerLength + maskLength + length
            if remaining < total { break }
            // 单帧长度保护：聊天消息上限 2KB，限制到 8MB 防异常帧
            if length > 8 * 1024 * 1024 { break }

            var payload = Data(buffer[(index + headerLength + maskLength)..<(index + total)])
            if masked {
                let masks: [UInt8] = [
                    buffer[index + headerLength],
                    buffer[index + headerLength + 1],
                    buffer[index + headerLength + 2],
                    buffer[index + headerLength + 3],
                ]
                var unmasked = Data()
                unmasked.reserveCapacity(payload.count)
                for (i, byte) in payload.enumerated() {
                    unmasked.append(byte ^ masks[i % 4])
                }
                payload = unmasked
            }
            index += total
            handleFrame(fin: fin, opcode: opcode, payload: payload)
        }
        return index
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x0:                       // continuation
            fragment.append(payload)
            if fin { deliverFragment() }
        case 0x1, 0x2:                 // text / binary
            if fin {
                if opcode == 0x1 { onText?(String(data: payload, encoding: .utf8) ?? "") }
            } else {
                fragmentOpcode = opcode
                fragment = payload
            }
        case 0x8:                       // close
            sendControl(opcode: 0x8, payload: Data())
            close(sendCloseFrame: false)
        case 0x9:                       // ping → pong（相同 payload）
            sendControl(opcode: 0xA, payload: payload)
        case 0xA:                       // pong
            break
        default:
            break
        }
    }

    private func deliverFragment() {
        if fragmentOpcode == 0x1 {
            onText?(String(data: fragment, encoding: .utf8) ?? "")
        }
        fragment.removeAll()
        fragmentOpcode = 0
    }

    /// 发送文本消息（UTF-8）。
    func send(_ text: String) {
        queue.async { [weak self] in
            guard let self = self, !self.closed else { return }
            let frame = WebSocketFrame.serverFrame(opcode: 0x1, payload: Data(text.utf8))
            self.nw.send(content: frame, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close(sendCloseFrame: false) }
            })
        }
    }

    private func sendControl(opcode: UInt8, payload: Data) {
        guard !closed else { return }
        let frame = WebSocketFrame.serverFrame(opcode: opcode, payload: payload)
        nw.send(content: frame, completion: .idempotent)
    }

    /// 关闭连接。`sendCloseFrame=true` 时先回一个 close 帧。
    func close(sendCloseFrame: Bool = true) {
        guard !closed else { return }
        closed = true
        if sendCloseFrame {
            let frame = WebSocketFrame.serverFrame(opcode: 0x8, payload: Data())
            nw.send(content: frame, completion: .contentProcessed { [weak self] _ in
                self?.nw.cancel()
            })
        } else {
            nw.cancel()
        }
        onClose?(id)
    }
}
