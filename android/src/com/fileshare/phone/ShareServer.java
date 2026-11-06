package com.fileshare.phone;

import android.content.Context;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.Charset;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Date;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/** App 内嵌的 HTTP + WebSocket 服务端，与桌面版 server.py 的 API 保持一致。 */
public class ShareServer {
    private final Context ctx;
    private final int port;
    private final File root;
    private final File tempDir;
    private final WsHub hub = new WsHub();
    private ServerSocket listener;
    private ExecutorService pool;
    private volatile boolean running = false;

    public ShareServer(Context ctx, int port, File root, File tempDir) {
        this.ctx = ctx;
        this.port = port;
        this.root = root;
        this.tempDir = tempDir;
        if (!root.exists()) root.mkdirs();
        if (!tempDir.exists()) tempDir.mkdirs();
    }

    public boolean start() {
        try {
            listener = new ServerSocket(port, 64, InetAddress.getByName("0.0.0.0"));
            pool = Executors.newCachedThreadPool();
            running = true;
            Thread t = new Thread(new Runnable() {
                @Override public void run() { acceptLoop(); }
            }, "fileshare-http");
            t.setDaemon(true);
            t.start();
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    public void stop() {
        running = false;
        try { if (listener != null) listener.close(); } catch (Exception ignored) { }
        if (pool != null) pool.shutdownNow();
    }

    private void acceptLoop() {
        while (running) {
            try {
                final Socket s = listener.accept();
                pool.execute(new Runnable() {
                    @Override public void run() { handle(s); }
                });
            } catch (Exception e) {
                if (running) continue;
                break;
            }
        }
    }

    // ---------------------------------------------------------------- 请求分发
    private void handle(Socket socket) {
        try {
            socket.setSoTimeout(0);
            BufferedInputStream in = new BufferedInputStream(socket.getInputStream(), 16384);
            BufferedOutputStream out = new BufferedOutputStream(socket.getOutputStream(), 16384);

            String requestLine = Multipart.readLine(in);
            if (requestLine == null) return;
            String[] sp = requestLine.split(" ");
            if (sp.length < 2) return;
            String method = sp[0].toUpperCase(Locale.US);
            String target = sp[1];
            int q = target.indexOf('?');
            String path = decode(q < 0 ? target : target.substring(0, q));
            String query = q < 0 ? "" : target.substring(q + 1);

            Map<String, String> headers = new HashMap<String, String>();
            String h;
            while ((h = Multipart.readLine(in)) != null && h.length() > 0) {
                int c = h.indexOf(':');
                if (c > 0) headers.put(h.substring(0, c).trim().toLowerCase(Locale.US),
                        h.substring(c + 1).trim());
            }

            if ("OPTIONS".equals(method)) {
                respond(out, 200, "OK", "text/plain", new byte[0], null);
                return;
            }

            if ("websocket".equalsIgnoreCase(headers.get("upgrade"))
                    && "/chat".equals(path)) {
                String id = socket.getInetAddress().getHostAddress() + ":" + socket.getPort();
                String nick = queryParam(query, "nick");
                if (nick == null || nick.length() == 0) nick = id;
                if (nick.length() > 20) nick = nick.substring(0, 20);
                if (hub.handshake(out, headers)) {
                    hub.serve(socket, in, out, id, nick);
                    return;
                }
            }

            route(method, path, query, headers, in, out);
            out.flush();
        } catch (Exception ignored) {
        } finally {
            try { socket.close(); } catch (Exception ignored) { }
        }
    }

    private void route(String method, String path, String query,
                       Map<String, String> headers, InputStream in, OutputStream out) throws Exception {
        // 静态资源
        String asset = assetName(path);
        if (asset != null && "GET".equals(method)) {
            sendAsset(out, asset);
            return;
        }

        if ("/health".equals(path)) {
            int count = root.list() == null ? 0 : root.list().length;
            String json = "{\"ok\":true,\"app\":\"文件共享中心 · 手机版\",\"version\":\"1.0\","
                    + "\"time\":" + WsHub.q(now()) + ",\"lan_ip\":" + WsHub.q(lanIp())
                    + ",\"port\":" + port + ",\"online\":" + hub.online()
                    + ",\"items\":" + count + "}";
            respond(out, 200, "OK", "application/json; charset=utf-8", json.getBytes("UTF-8"), null);
            return;
        }

        if ("/files".equals(path)) {
            respond(out, 200, "OK", "application/json; charset=utf-8", listJson().getBytes("UTF-8"), null);
            return;
        }

        if ("/upload".equals(path) && "POST".equals(method)) {
            doUpload(in, headers, out, false);
            return;
        }
        if ("/upload-folder".equals(path) && "POST".equals(method)) {
            doUpload(in, headers, out, true);
            return;
        }

        if ("/download-selected".equals(path)) {
            List<String> names = queryParams(query, "name");
            sendZip(out, names, "selected");
            return;
        }
        if ("/download-all".equals(path)) {
            List<String> names = new ArrayList<String>();
            File[] fs = root.listFiles();
            if (fs != null) for (File f : fs) names.add(f.getName());
            sendZip(out, names, "files");
            return;
        }

        if (path.startsWith("/download/") || path.startsWith("/preview/")) {
            boolean preview = path.startsWith("/preview/");
            String name = path.substring((preview ? "/preview/" : "/download/").length());
            File f = resolve(name);
            if (f == null || !f.exists()) { notFound(out); return; }
            if (f.isDirectory()) {
                List<String> one = new ArrayList<String>();
                one.add(name);
                sendZip(out, one, "folder");
            } else {
                sendFile(out, f, !preview, f.getName());
            }
            return;
        }

        if ("/delete-selected".equals(path) && "POST".equals(method)) {
            String body = readBody(in, headers);
            doDelete(out, stringArray(body, "names"));
            return;
        }
        if (path.startsWith("/delete/") && "DELETE".equals(method)) {
            List<String> one = new ArrayList<String>();
            one.add(path.substring("/delete/".length()));
            doDelete(out, one);
            return;
        }
        if ("/clear-download".equals(path) && "POST".equals(method)) {
            readBody(in, headers);
            List<String> all = new ArrayList<String>();
            File[] fs = root.listFiles();
            if (fs != null) for (File f : fs) all.add(f.getName());
            doDelete(out, all);
            return;
        }
        notFound(out);
    }

    // ---------------------------------------------------------------- 静态
    private String assetName(String path) {
        if ("/".equals(path) || "/index.html".equals(path)) return "www/index.html";
        if (path.startsWith("/static/")) return "www/" + path.substring("/static/".length());
        if ("/manifest.webmanifest".equals(path)) return "www/manifest.webmanifest";
        if ("/sw.js".equals(path)) return "www/sw.js";
        if ("/icon-192.png".equals(path) || "/icon-512.png".equals(path)
                || "/apple-touch-icon.png".equals(path)) return "www" + path;
        if ("/favicon.ico".equals(path)) return "www/icon-192.png";
        return null;
    }

    private void sendAsset(OutputStream out, String asset) throws IOException {
        try {
            InputStream is = ctx.getAssets().open(asset);
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = is.read(buf)) > 0) b.write(buf, 0, n);
            is.close();
            respond(out, 200, "OK", mime(asset), b.toByteArray(), "Cache-Control: no-cache");
        } catch (IOException e) {
            notFound(out);
        }
    }

    // ---------------------------------------------------------------- 文件列表
    private String listJson() {
        File[] fs = root.listFiles();
        List<File> files = new ArrayList<File>();
        if (fs != null) for (File f : fs) files.add(f);
        Collections.sort(files, new Comparator<File>() {
            @Override public int compare(File a, File b) {
                if (a.isDirectory() != b.isDirectory()) return a.isDirectory() ? -1 : 1;
                return Long.valueOf(b.lastModified()).compareTo(a.lastModified());
            }
        });
        StringBuilder s = new StringBuilder("[");
        for (int i = 0; i < files.size(); i++) {
            if (i > 0) s.append(',');
            File f = files.get(i);
            long size = f.isDirectory() ? dirSize(f) : f.length();
            s.append("{\"name\":").append(WsHub.q(f.getName()))
                    .append(",\"size\":").append(WsHub.q(humanSize(size)))
                    .append(",\"bytes\":").append(size)
                    .append(",\"modified\":").append(f.lastModified() / 1000.0)
                    .append(",\"modified_str\":").append(WsHub.q(modified(f)))
                    .append(",\"type\":").append(WsHub.q(f.isDirectory() ? "folder" : "file"));
            if (f.isDirectory()) s.append(",\"file_count\":").append(countFiles(f));
            s.append('}');
        }
        return s.append(']').toString();
    }

    // ---------------------------------------------------------------- 上传
    private void doUpload(InputStream in, Map<String, String> headers,
                          OutputStream out, boolean folderMode) {
        List<Multipart.Part> parts = null;
        try {
            String boundary = boundaryOf(headers.get("content-type"));
            parts = Multipart.parse(in, boundary, tempDir);
            int saved = 0;
            String folderName = null;

            if (folderMode) {
                for (Multipart.Part p : parts) {
                    if (p.filename == null && "folder_name".equals(p.name)) {
                        folderName = new String(readAll(p.file), "UTF-8").trim();
                    }
                }
                String safe = safeName(folderName == null || folderName.length() == 0
                        ? "上传文件夹" : folderName);
                if (safe == null) safe = "上传文件夹";
                File dir = unique(new File(root, safe), true);
                dir.mkdirs();
                for (Multipart.Part p : parts) {
                    if (p.filename == null) continue;
                    File dest = resolveIn(dir, p.filename);
                    if (dest == null) continue;
                    dest.getParentFile().mkdirs();
                    copy(p.file, dest);
                    saved++;
                }
                folderName = dir.getName();
            } else {
                for (Multipart.Part p : parts) {
                    if (p.filename == null) continue;
                    String name = safeName(p.filename);
                    if (name == null) continue;
                    File dest = unique(new File(root, name), false);
                    copy(p.file, dest);
                    saved++;
                }
            }
            hub.filesChanged();
            String extra = folderMode ? ",\"folder_name\":" + WsHub.q(folderName) : "";
            String json = "{\"success\":true,\"message\":" + WsHub.q("上传成功 " + saved + " 个文件")
                    + ",\"filenames\":[],\"failed\":[]" + extra + "}";
            respond(out, 200, "OK", "application/json; charset=utf-8", json.getBytes("UTF-8"), null);
        } catch (Exception e) {
            try {
                respond(out, 500, "Error", "application/json; charset=utf-8",
                        ("{\"success\":false,\"message\":" + WsHub.q(String.valueOf(e.getMessage())) + "}")
                                .getBytes("UTF-8"), null);
            } catch (Exception ignored) { }
        } finally {
            if (parts != null) for (Multipart.Part p : parts) p.file.delete();
        }
    }

    // ---------------------------------------------------------------- 下载 / ZIP
    private void sendZip(OutputStream out, List<String> names, String prefix) throws Exception {
        List<File> items = new ArrayList<File>();
        for (String n : names) {
            File f = resolve(n);
            if (f != null && f.exists()) items.add(f);
        }
        if (items.isEmpty()) { notFound(out); return; }
        File zip = new File(tempDir, prefix + "_" + System.currentTimeMillis() + ".zip");
        ZipOutputStream zos = new ZipOutputStream(new FileOutputStream(zip),
                Charset.forName("UTF-8"));
        try {
            for (File f : items) addToZip(zos, f, f.getName());
        } finally {
            zos.close();
        }
        sendFile(out, zip, true, zip.getName());
        cleanupLater(zip);
    }

    private void addToZip(ZipOutputStream zos, File f, String entry) throws IOException {
        if (f.isDirectory()) {
            File[] children = f.listFiles();
            if (children != null) for (File c : children) addToZip(zos, c, entry + "/" + c.getName());
        } else {
            zos.putNextEntry(new ZipEntry(entry));
            FileInputStream is = new FileInputStream(f);
            byte[] buf = new byte[8192];
            int n;
            while ((n = is.read(buf)) > 0) zos.write(buf, 0, n);
            is.close();
            zos.closeEntry();
        }
    }

    private void sendFile(OutputStream out, File f, boolean attachment, String name) throws IOException {
        String extra = null;
        if (attachment) {
            String ascii = name.replaceAll("[^\\x20-\\x7E]", "_");
            extra = "Content-Disposition: attachment; filename=\"" + ascii
                    + "\"; filename*=UTF-8''" + URLEncoder.encode(name, "UTF-8").replace("+", "%20");
        }
        FileInputStream is = new FileInputStream(f);
        try {
            writeHeaders(out, 200, "OK", mime(name), f.length(), extra);
            byte[] buf = new byte[16384];
            int n;
            while ((n = is.read(buf)) > 0) out.write(buf, 0, n);
            out.flush();
        } finally {
            is.close();
        }
    }

    // ---------------------------------------------------------------- 删除
    private void doDelete(OutputStream out, List<String> names) throws IOException {
        int deleted = 0;
        for (String n : names) {
            File f = resolve(n);
            if (f == null || !f.exists()) continue;
            if (deleteRecursive(f)) deleted++;
        }
        hub.filesChanged();
        String json = "{\"success\":true,\"deleted\":" + deleted
                + ",\"failed\":[],\"message\":" + WsHub.q("成功删除 " + deleted + " 个项目") + "}";
        respond(out, 200, "OK", "application/json; charset=utf-8", json.getBytes("UTF-8"), null);
    }

    // ---------------------------------------------------------------- HTTP 输出
    private void respond(OutputStream out, int code, String reason, String type,
                         byte[] body, String extra) throws IOException {
        writeHeaders(out, code, reason, type, body.length, extra);
        out.write(body);
        out.flush();
    }

    private void writeHeaders(OutputStream out, int code, String reason, String type,
                              long length, String extra) throws IOException {
        StringBuilder h = new StringBuilder();
        h.append("HTTP/1.1 ").append(code).append(' ').append(reason).append("\r\n")
                .append("Content-Type: ").append(type).append("\r\n")
                .append("Content-Length: ").append(length).append("\r\n")
                .append("Access-Control-Allow-Origin: *\r\n")
                .append("Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n")
                .append("Access-Control-Allow-Headers: Content-Type\r\n")
                .append("Connection: close\r\n");
        if (extra != null) h.append(extra).append("\r\n");
        h.append("\r\n");
        out.write(h.toString().getBytes("UTF-8"));
    }

    private void notFound(OutputStream out) throws IOException {
        respond(out, 404, "Not Found", "application/json; charset=utf-8",
                "{\"success\":false,\"message\":\"资源不存在\"}".getBytes("UTF-8"), null);
    }

    // ---------------------------------------------------------------- 工具
    private String boundaryOf(String contentType) {
        if (contentType == null) return null;
        int i = contentType.toLowerCase(Locale.US).indexOf("boundary=");
        if (i < 0) return null;
        String b = contentType.substring(i + 9).trim();
        if (b.length() > 1 && b.charAt(0) == '"') {
            int end = b.indexOf('"', 1);
            if (end > 0) b = b.substring(1, end);
        }
        int semi = b.indexOf(';');
        return semi > 0 ? b.substring(0, semi).trim() : b;
    }

    private String readBody(InputStream in, Map<String, String> headers) throws IOException {
        int len = 0;
        try { len = Integer.parseInt(headers.get("content-length")); } catch (Exception ignored) { }
        if (len <= 0 || len > 4 * 1024 * 1024) return "";
        byte[] b = new byte[len];
        int off = 0;
        while (off < len) {
            int n = in.read(b, off, len - off);
            if (n < 0) break;
            off += n;
        }
        return new String(b, 0, off, "UTF-8");
    }

    private static List<String> stringArray(String body, String key) {
        List<String> r = new ArrayList<String>();
        int i = body.indexOf("\"" + key + "\"");
        if (i < 0) return r;
        int open = body.indexOf('[', i);
        if (open < 0) return r;
        int p = open + 1;
        while (p < body.length()) {
            int start = body.indexOf('"', p);
            if (start < 0) break;
            StringBuilder s = new StringBuilder();
            int j = start + 1;
            while (j < body.length()) {
                char c = body.charAt(j);
                if (c == '"') break;
                if (c == '\\' && j + 1 < body.length()) {
                    char n = body.charAt(++j);
                    if (n == 'u' && j + 4 < body.length()) {
                        try {
                            s.append((char) Integer.parseInt(body.substring(j + 1, j + 5), 16));
                            j += 4;
                        } catch (Exception ignored) { }
                    } else if (n == 'n') s.append('\n');
                    else if (n == 'r') s.append('\r');
                    else if (n == 't') s.append('\t');
                    else s.append(n);
                } else s.append(c);
                j++;
            }
            r.add(s.toString());
            p = j + 1;
            int comma = body.indexOf(',', p);
            int close = body.indexOf(']', p);
            if (close >= 0 && (comma < 0 || close < comma)) break;
            if (comma < 0) break;
            p = comma + 1;
        }
        return r;
    }

    private static String queryParam(String query, String key) {
        for (String pair : query.split("&")) {
            int e = pair.indexOf('=');
            if (e > 0 && decode(pair.substring(0, e)).equals(key)) return decode(pair.substring(e + 1));
        }
        return null;
    }

    private static List<String> queryParams(String query, String key) {
        List<String> r = new ArrayList<String>();
        for (String pair : query.split("&")) {
            int e = pair.indexOf('=');
            if (e > 0 && decode(pair.substring(0, e)).equals(key)) r.add(decode(pair.substring(e + 1)));
        }
        return r;
    }

    private static String decode(String s) {
        try { return URLDecoder.decode(s.replace("+", "%2B"), "UTF-8"); }
        catch (Exception e) { return s; }
    }

    public static String safeName(String raw) {
        if (raw == null) return null;
        String n = raw.replace('\\', '/');
        n = n.substring(n.lastIndexOf('/') + 1);
        n = n.replaceAll("[<>:\"|?*\\x00-\\x1F]", "_").trim();
        while (n.endsWith(".")) n = n.substring(0, n.length() - 1);
        if (n.length() == 0 || ".".equals(n) || "..".equals(n)) return null;
        return n.length() > 200 ? n.substring(0, 200) : n;
    }

    private File resolve(String raw) {
        if (raw == null) return null;
        String p = raw.replace('\\', '/').trim();
        if (p.startsWith("/") || p.contains(":") || p.length() == 0) return null;
        for (String seg : p.split("/")) if ("..".equals(seg)) return null;
        try {
            File f = new File(root, p).getCanonicalFile();
            String base = root.getCanonicalPath();
            if (f.getPath().equals(base) || !f.getPath().startsWith(base + File.separator)) return null;
            return f;
        } catch (Exception e) { return null; }
    }

    private File resolveIn(File dir, String rel) {
        if (rel == null) return null;
        String p = rel.replace('\\', '/');
        if (p.startsWith("/") || p.contains(":")) return null;
        for (String seg : p.split("/")) if ("..".equals(seg) || seg.length() == 0) continue;
        if (p.contains("..")) return null;
        try {
            File f = new File(dir, p).getCanonicalFile();
            if (!f.getPath().startsWith(dir.getCanonicalPath() + File.separator)) return null;
            return f;
        } catch (Exception e) { return null; }
    }

    private static File unique(File base, boolean dir) {
        if (!base.exists()) return base;
        String n = base.getName();
        int dot = n.lastIndexOf('.');
        String stem = (dir || dot < 0) ? n : n.substring(0, dot);
        String ext = (dir || dot < 0) ? "" : n.substring(dot);
        int i = 1;
        File f;
        do {
            f = new File(base.getParentFile(), stem + "(" + (i++) + ")" + ext);
        } while (f.exists());
        return f;
    }

    private static boolean deleteRecursive(File f) {
        if (f.isDirectory()) {
            File[] children = f.listFiles();
            if (children != null) for (File c : children) deleteRecursive(c);
        }
        return f.delete();
    }

    private static void copy(File src, File dest) throws IOException {
        FileInputStream is = new FileInputStream(src);
        FileOutputStream os = new FileOutputStream(dest);
        try {
            byte[] buf = new byte[16384];
            int n;
            while ((n = is.read(buf)) > 0) os.write(buf, 0, n);
        } finally {
            is.close();
            os.close();
        }
    }

    private static byte[] readAll(File f) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        FileInputStream is = new FileInputStream(f);
        try {
            byte[] buf = new byte[4096];
            int n;
            while ((n = is.read(buf)) > 0) b.write(buf, 0, n);
        } finally { is.close(); }
        return b.toByteArray();
    }

    private static void cleanupLater(final File f) {
        Thread t = new Thread(new Runnable() {
            @Override public void run() {
                try { Thread.sleep(300000); } catch (Exception ignored) { }
                f.delete();
            }
        });
        t.setDaemon(true);
        t.start();
    }

    private static long dirSize(File dir) {
        long total = 0;
        File[] fs = dir.listFiles();
        if (fs != null) for (File f : fs) total += f.isDirectory() ? dirSize(f) : f.length();
        return total;
    }

    private static int countFiles(File dir) {
        int n = 0;
        File[] fs = dir.listFiles();
        if (fs != null) for (File f : fs) n += f.isDirectory() ? countFiles(f) : 1;
        return n;
    }

    private static String humanSize(long n) {
        if (n < 1024) return n + " B";
        if (n < 1048576) return String.format(Locale.US, "%.2f KB", n / 1024.0);
        if (n < 1073741824L) return String.format(Locale.US, "%.2f MB", n / 1048576.0);
        return String.format(Locale.US, "%.2f GB", n / 1073741824.0);
    }

    private static String modified(File f) {
        return new SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(new Date(f.lastModified()));
    }

    public static String now() {
        return new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).format(new Date());
    }

    public static String lanIp() {
        try {
            Enumeration<NetworkInterface> en = NetworkInterface.getNetworkInterfaces();
            while (en != null && en.hasMoreElements()) {
                NetworkInterface ni = en.nextElement();
                Enumeration<InetAddress> as = ni.getInetAddresses();
                while (as.hasMoreElements()) {
                    InetAddress a = as.nextElement();
                    if (!a.isLoopbackAddress() && (a instanceof Inet4Address) && a.isSiteLocalAddress())
                        return a.getHostAddress();
                }
            }
        } catch (Exception ignored) { }
        return "127.0.0.1";
    }

    private static String mime(String name) {
        String n = name.toLowerCase(Locale.US);
        if (n.endsWith(".html") || n.endsWith(".htm")) return "text/html; charset=utf-8";
        if (n.endsWith(".js")) return "application/javascript; charset=utf-8";
        if (n.endsWith(".css")) return "text/css; charset=utf-8";
        if (n.endsWith(".json") || n.endsWith(".webmanifest")) return "application/manifest+json; charset=utf-8";
        if (n.endsWith(".png")) return "image/png";
        if (n.endsWith(".jpg") || n.endsWith(".jpeg")) return "image/jpeg";
        if (n.endsWith(".gif")) return "image/gif";
        if (n.endsWith(".svg")) return "image/svg+xml";
        if (n.endsWith(".pdf")) return "application/pdf";
        if (n.endsWith(".txt") || n.endsWith(".md")) return "text/plain; charset=utf-8";
        if (n.endsWith(".mp4")) return "video/mp4";
        if (n.endsWith(".mp3")) return "audio/mpeg";
        if (n.endsWith(".zip")) return "application/zip";
        return "application/octet-stream";
    }
}
