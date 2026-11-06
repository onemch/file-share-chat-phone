package com.fileshare.phone;

import android.Manifest;
import android.app.Activity;
import android.app.DownloadManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.ViewGroup;
import android.webkit.DownloadListener;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.net.URLDecoder;

/** WebView 壳：加载内嵌服务端提供的移动端页面，同时具备「连别人主机」的能力。 */
public class MainActivity extends Activity {
    private static final int REQ_FILE = 1001;
    private static final int REQ_NOTIFICATION = 1002;
    private static final String HOME = "http://127.0.0.1:5000/";

    private WebView web;
    private ValueCallback<Uri[]> filePathCallback;
    private int retryCount = 0;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTIFICATION);
        }
        startShareService();
        buildUi();
        // 服务绑定端口在主线程稍后执行，延迟加载并在失败时重试
        web.postDelayed(new Runnable() {
            @Override public void run() { web.loadUrl(HOME); }
        }, 700);
    }

    private void startShareService() {
        try {
            Intent i = new Intent(this, ShareService.class);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i);
            else startService(i);
        } catch (Exception e) {
            Toast.makeText(this, "服务启动失败：" + e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.parseColor("#F5F6FA"));

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setBackgroundColor(Color.parseColor("#6C5CE7"));
        bar.setGravity(Gravity.CENTER_VERTICAL);
        int pad = dp(12);
        bar.setPadding(pad, pad + dp(6), pad, pad);

        final TextView addr = new TextView(this);
        addr.setTextColor(Color.WHITE);
        addr.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        addr.setText("本机服务  http://" + ShareService.lanIp + ":" + ShareService.PORT);
        addr.setSingleLine(true);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        bar.addView(addr, lp);

        Button copy = new Button(this);
        copy.setText("复制地址");
        copy.setTextColor(Color.parseColor("#6C5CE7"));
        copy.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        copy.setAllCaps(false);
        copy.setBackgroundColor(Color.WHITE);
        copy.setOnClickListener(new android.view.View.OnClickListener() {
            @Override public void onClick(android.view.View v) {
                String url = "http://" + ShareService.lanIp + ":" + ShareService.PORT
                        + "/?host=http%3A%2F%2F" + ShareService.lanIp + "%3A" + ShareService.PORT;
                ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("share", url));
                Toast.makeText(MainActivity.this, "访问链接已复制，发给朋友即可加入", Toast.LENGTH_SHORT).show();
            }
        });
        bar.addView(copy);
        root.addView(bar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(true);
        s.setLoadWithOverviewMode(false);
        s.setUseWideViewPort(true);
        s.setSupportZoom(false);
        s.setMediaPlaybackRequiresUserGesture(false);
        if (Build.VERSION.SDK_INT >= 21) s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        web.setBackgroundColor(Color.parseColor("#F5F6FA"));

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return false;
            }
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, String url) {
                return false;   // API 23 兼容
            }
            @Override
            public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) {
                if (HOME.equals(failingUrl) && retryCount < 4) {
                    retryCount++;
                    view.postDelayed(new Runnable() {
                        @Override public void run() { web.loadUrl(HOME); }
                    }, 800L * retryCount);
                }
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback,
                                             FileChooserParams params) {
                if (filePathCallback != null) filePathCallback.onReceiveValue(null);
                filePathCallback = callback;
                Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
                intent.addCategory(Intent.CATEGORY_OPENABLE);
                intent.setType("*/*");
                intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
                try {
                    startActivityForResult(Intent.createChooser(intent, "选择要上传的文件"), REQ_FILE);
                    return true;
                } catch (Exception e) {
                    filePathCallback = null;
                    Toast.makeText(MainActivity.this, "无法打开文件选择器", Toast.LENGTH_SHORT).show();
                    return false;
                }
            }
        });

        web.setDownloadListener(new DownloadListener() {
            @Override
            public void onDownloadStart(String url, String userAgent, String contentDisposition,
                                        String mimeType, long contentLength) {
                startDownload(url, contentDisposition, mimeType);
            }
        });

        root.addView(web, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(root);
    }

    /** DownloadManager 跑在系统进程，127.0.0.1 指不到 App 内嵌服务，改用本机局域网 IP。 */
    private void startDownload(String url, String cd, String mime) {
        try {
            String real = url.replace("127.0.0.1", ShareService.lanIp);
            DownloadManager.Request req = new DownloadManager.Request(Uri.parse(real));
            req.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
            req.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, fileNameFrom(cd, url));
            if (mime != null && mime.length() > 0) req.setMimeType(mime);
            DownloadManager dm = (DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE);
            if (dm != null) {
                dm.enqueue(req);
                Toast.makeText(this, "开始下载，详见通知栏", Toast.LENGTH_SHORT).show();
            }
        } catch (Exception e) {
            Toast.makeText(this, "下载失败：" + e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private String fileNameFrom(String cd, String url) {
        try {
            if (cd != null) {
                int i = cd.indexOf("filename*=UTF-8''");
                if (i >= 0) {
                    String v = cd.substring(i + 17).replaceAll("[\"; ]", "");
                    return URLDecoder.decode(v, "UTF-8");
                }
                i = cd.indexOf("filename=\"");
                if (i >= 0) {
                    String v = cd.substring(i + 10, cd.indexOf('"', i + 10));
                    return new String(v.getBytes("ISO-8859-1"), "UTF-8");
                }
            }
            String path = Uri.parse(url).getLastPathSegment();
            return URLDecoder.decode(path == null ? "download" : path, "UTF-8");
        } catch (Exception e) {
            return "download_" + System.currentTimeMillis();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQ_FILE || filePathCallback == null) return;
        Uri[] results = null;
        if (resultCode == RESULT_OK && data != null) {
            if (data.getClipData() != null) {
                int n = data.getClipData().getItemCount();
                results = new Uri[n];
                for (int i = 0; i < n; i++) results[i] = data.getClipData().getItemAt(i).getUri();
            } else if (data.getData() != null) {
                results = new Uri[]{data.getData()};
            }
        }
        filePathCallback.onReceiveValue(results);
        filePathCallback = null;
    }

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) web.goBack();
        else super.onBackPressed();
    }

    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                getResources().getDisplayMetrics());
    }
}
