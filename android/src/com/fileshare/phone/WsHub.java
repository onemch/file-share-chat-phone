package com.fileshare.phone;

import android.util.Base64;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.security.MessageDigest;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;

/** 极简 WebSocket 服务端：握手、帧编解码、群聊广播、历史回放、文件变更通知。 */
public class WsHub {
    private static final String GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    private static final int MAX_FRAME = 2 * 1024 * 1024;

    static class Client {
        Socket socket;
        OutputStream out;
        String id;
        String nick;
    }

    private final List<Client> clients = new CopyOnWriteArrayList<Client>();
    private final Deque<String> history = new ArrayDeque<String>();

    /** JSON 字符串转义（整个工程共用，避免引入第三方 JSON 库）。 */
    public static String q(String s) {
        if (s == null) return "\"\"";
        StringBuilder b = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20) b.append(String.format(Locale.US, "\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        return b.append('"').toString();
    }

    public boolean handshake(OutputStream out, Map<String, String> headers) throws Exception {
        String key = headers.get("sec-websocket-key");
        if (key == null) return false;
        MessageDigest md = MessageDigest.getInstance("SHA-1");
        byte[] hash = md.digest((key + GUID).getBytes("UTF-8"));
        String accept = Base64.encodeToString(hash, Base64.NO_WRAP);
        String resp = "HTTP/1.1 101 Switching Protocols\r\n"
                + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: " + accept + "\r\n\r\n";
        out.write(resp.getBytes("UTF-8"));
        out.flush();
        return true;
    }

    public void serve(Socket socket, InputStream in, OutputStream out, String id, String nick) throws Exception {
        final Client c = new Client();
        c.socket = socket;
        c.out = out;
        c.id = id;
        c.nick = nick;

        synchronized (clients) { clients.add(c); }
        send(c, "{\"type\":\"welcome\",\"user_id\":" + q(id) + ",\"nick\":" + q(nick)
                + ",\"online_count\":" + clients.size() + ",\"users\":" + userList() + "}");
        synchronized (history) {
            for (String h : history) send(c, h);
        }
        String joined = system(nick + " 加入了共享");
        synchronized (history) {
            history.addLast(joined);
            trimHistory();
        }
        broadcast(joined, c);

        try {
            while (true) {
                Frame f = readFrame(in);
                if (f == null) break;
                if (f.opcode == 0x8) break;              // close
                if (f.opcode == 0x9) {                  // ping -> pong
                    sendRaw(c, 0x0A, f.payload);
                    continue;
                }
                if (f.opcode != 0x1) continue;
                String text = new String(f.payload, "UTF-8");
                String type = jsonString(text, "type");
                if (!"chat".equals(type) && !"file_shared".equals(type)) continue;
                String message = jsonString(text, "message");
                if (message == null || message.length() == 0) continue;
                if (message.length() > 2000) message = message.substring(0, 2000);
                String msg = "{\"type\":" + q(type) + ",\"user_id\":" + q(id)
                        + ",\"nick\":" + q(nick) + ",\"message\":" + q(message)
                        + ",\"timestamp\":" + q(ShareServer.now()) + "}";
                if ("chat".equals(type)) {
                    synchronized (history) {
                        history.addLast(msg);
                        trimHistory();
                    }
                }
                broadcast(msg, c);
            }
        } finally {
            synchronized (clients) { clients.remove(c); }
            String left = system(nick + " 离开了共享");
            synchronized (history) {
                history.addLast(left);
                trimHistory();
            }
            broadcast(left, null);
            try { socket.close(); } catch (Exception ignored) { }
        }
    }

    public int online() {
        return clients.size();
    }

    /** 任意设备改动共享目录后，通知所有客户端刷新列表。 */
    public void filesChanged() {
        broadcast("{\"type\":\"files_changed\"}", null);
    }

    private String system(String text) {
        return "{\"type\":\"system\",\"message\":" + q(text)
                + ",\"timestamp\":" + q(ShareServer.now())
                + ",\"online_count\":" + clients.size() + ",\"users\":" + userList() + "}";
    }

    private String userList() {
        StringBuilder b = new StringBuilder("[");
        boolean first = true;
        for (Client x : clients) {
            if (!first) b.append(',');
            first = false;
            b.append(q(x.nick));
        }
        return b.append(']').toString();
    }

    private void trimHistory() {
        while (history.size() > 100) history.removeFirst();
    }

    private void broadcast(String json, Client exclude) {
        List<Client> dead = new ArrayList<Client>();
        for (Client x : clients) {
            if (x == exclude) continue;
            try { send(x, json); } catch (Exception e) { dead.add(x); }
        }
        if (!dead.isEmpty()) synchronized (clients) { clients.removeAll(dead); }
    }

    private void send(Client c, String text) throws IOException {
        sendRaw(c, 0x1, text.getBytes("UTF-8"));
    }

    private void sendRaw(Client c, int opcode, byte[] data) throws IOException {
        synchronized (c.out) {
            c.out.write(0x80 | opcode);
            int n = data.length;
            if (n < 126) {
                c.out.write(n);
            } else if (n < 65536) {
                c.out.write(126);
                c.out.write((n >> 8) & 0xFF);
                c.out.write(n & 0xFF);
            } else {
                c.out.write(127);
                for (int i = 7; i >= 0; i--) c.out.write((int) (((long) n >>> (8 * i)) & 0xFF));
            }
            c.out.write(data);
            c.out.flush();
        }
    }

    static class Frame {
        int opcode;
        byte[] payload;
        Frame(int opcode, byte[] payload) { this.opcode = opcode; this.payload = payload; }
    }

    private static Frame readFrame(InputStream in) throws IOException {
        int b1 = in.read();
        if (b1 < 0) return null;
        int b2 = in.read();
        if (b2 < 0) return null;
        int opcode = b1 & 0x0F;
        long length = b2 & 0x7F;
        if (length == 126) {
            int h = in.read(), l = in.read();
            if (h < 0 || l < 0) return null;
            length = ((h & 0xFF) << 8) | (l & 0xFF);
        } else if (length == 127) {
            long v = 0;
            for (int i = 0; i < 8; i++) {
                int c = in.read();
                if (c < 0) return null;
                v = (v << 8) | (c & 0xFF);
            }
            length = v;
        }
        if (length < 0 || length > MAX_FRAME) throw new IOException("frame too large");
        boolean masked = (b2 & 0x80) != 0;
        byte[] mask = new byte[4];
        if (masked) readFully(in, mask);
        byte[] data = new byte[(int) length];
        readFully(in, data);
        if (masked) for (int i = 0; i < data.length; i++) data[i] ^= mask[i % 4];
        return new Frame(opcode, data);
    }

    private static void readFully(InputStream in, byte[] b) throws IOException {
        int off = 0;
        while (off < b.length) {
            int n = in.read(b, off, b.length - off);
            if (n < 0) throw new IOException("连接中断");
            off += n;
        }
    }

    /** 从客户端 JSON 里取一个字符串字段（只用于解析我们自己的消息格式）。 */
    private static String jsonString(String json, String key) {
        String needle = "\"" + key + "\"";
        int i = json.indexOf(needle);
        if (i < 0) return null;
        int colon = json.indexOf(':', i + needle.length());
        if (colon < 0) return null;
        int start = colon + 1;
        while (start < json.length() && Character.isWhitespace(json.charAt(start))) start++;
        if (start >= json.length() || json.charAt(start) != '"') return null;
        StringBuilder b = new StringBuilder();
        for (int p = start + 1; p < json.length(); p++) {
            char c = json.charAt(p);
            if (c == '"') return b.toString();
            if (c == '\\' && p + 1 < json.length()) {
                char n = json.charAt(++p);
                switch (n) {
                    case 'n': b.append('\n'); break;
                    case 'r': b.append('\r'); break;
                    case 't': b.append('\t'); break;
                    case 'u':
                        if (p + 4 < json.length()) {
                            try {
                                b.append((char) Integer.parseInt(json.substring(p + 1, p + 5), 16));
                                p += 4;
                            } catch (Exception ignored) { }
                        }
                        break;
                    default: b.append(n);
                }
            } else b.append(c);
        }
        return b.toString();
    }
}
