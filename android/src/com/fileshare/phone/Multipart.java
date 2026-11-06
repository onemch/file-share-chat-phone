package com.fileshare.phone;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** 流式 multipart/form-data 解析：每个 part 直接落临时文件，避免大文件占满内存。 */
public class Multipart {
    public static class Part {
        public String name;
        public String filename;
        public File file;
    }

    public static List<Part> parse(InputStream raw, String boundary, File tempDir) throws IOException {
        if (boundary == null || boundary.length() == 0) throw new IOException("缺少 boundary");
        BufferedInputStream in = new BufferedInputStream(raw, 16384);
        String marker = "--" + boundary;
        String line;
        do {
            line = readLine(in);
        } while (line != null && !line.startsWith(marker));
        if (line == null) throw new IOException("multipart 格式错误");

        List<Part> parts = new ArrayList<Part>();
        int index = 0;
        while (true) {
            if (line.startsWith(marker + "--")) break;

            String disposition = null;
            while ((line = readLine(in)) != null && line.length() > 0) {
                if (line.toLowerCase(Locale.US).startsWith("content-disposition:")) disposition = line;
            }
            if (disposition == null) throw new IOException("part 缺少 Content-Disposition");

            Part p = new Part();
            p.name = attribute(disposition, "name");
            p.filename = attribute(disposition, "filename");
            p.file = new File(tempDir, "up_" + System.nanoTime() + "_" + (index++) + ".part");

            DelimitedInputStream body = new DelimitedInputStream(in,
                    ("\r\n" + marker).getBytes("ISO-8859-1"));
            OutputStream out = new FileOutputStream(p.file);
            try {
                byte[] buf = new byte[8192];
                int n;
                while ((n = body.read(buf)) > 0) out.write(buf, 0, n);
            } finally {
                out.close();
            }
            parts.add(p);

            String tail = readLine(in);   // 消耗 boundary 后的 \r\n 或结束标记 --
            if (tail == null || tail.startsWith("--")) break;
            line = marker;               // 下一个 part 的 headers 紧随其后
        }
        return parts;
    }

    private static String attribute(String header, String key) {
        int i = header.toLowerCase(Locale.US).indexOf(key + "=");
        if (i < 0) return null;
        i = header.indexOf('=', i) + 1;
        if (i >= header.length()) return null;
        String value;
        if (header.charAt(i) == '"') {
            int end = header.indexOf('"', i + 1);
            if (end < 0) return null;
            value = header.substring(i + 1, end);
        } else {
            int end = header.indexOf(';', i);
            value = end < 0 ? header.substring(i) : header.substring(i, end);
        }
        try {
            return new String(value.getBytes("ISO-8859-1"), "UTF-8");
        } catch (Exception e) {
            return value;
        }
    }

    static String readLine(InputStream in) throws IOException {
        StringBuilder b = new StringBuilder();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') return b.toString();
            if (c != '\r') b.append((char) (c & 0xFF));
        }
        return b.length() == 0 ? null : b.toString();
    }

    /** 读到 \r\n--boundary 为止，delimiter 会被消耗掉但不写入输出。 */
    private static class DelimitedInputStream extends InputStream {
        private final InputStream in;
        private final byte[] delim;
        private final byte[] buf;
        private int len = 0;
        private boolean done = false;

        DelimitedInputStream(InputStream in, byte[] delim) {
            this.in = in;
            this.delim = delim;
            this.buf = new byte[delim.length];
        }

        private boolean matches() {
            for (int i = 0; i < delim.length; i++) if (buf[i] != delim[i]) return false;
            return true;
        }

        @Override
        public int read() throws IOException {
            if (done) return -1;
            while (true) {
                int c = in.read();
                if (c == -1) { done = true; return -1; }
                if (len < buf.length) {
                    buf[len++] = (byte) c;
                    if (len == buf.length && matches()) { done = true; return -1; }
                    // 缓冲未满，继续累积，暂不输出
                    continue;
                }
                int out = buf[0] & 0xFF;
                System.arraycopy(buf, 1, buf, 0, buf.length - 1);
                buf[buf.length - 1] = (byte) c;
                if (matches()) done = true;
                return out;
            }
        }
    }
}
