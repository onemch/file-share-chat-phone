package com.fileshare.phone;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;

import java.io.File;

/** 前台服务：让内嵌的 HTTP + WebSocket 服务在 App 退到后台后继续运行。 */
public class ShareService extends Service {
    public static final int PORT = 5000;
    private static final String CHANNEL = "fileshare_server";
    private static final int NOTIFICATION_ID = 1;

    static volatile ShareServer server;
    static volatile String lanIp = "127.0.0.1";
    static volatile boolean running = false;

    @Override
    public void onCreate() {
        super.onCreate();
        File shared = new File(getExternalFilesDir(null), "shared");
        if (!shared.exists()) shared.mkdirs();
        File temp = new File(getCacheDir(), "temp");
        if (!temp.exists()) temp.mkdirs();

        lanIp = ShareServer.lanIp();
        if (server == null) {
            server = new ShareServer(getApplicationContext(), PORT, shared, temp);
            // start() 内部同步完成端口绑定，避免 WebView 加载时还没监听
            if (server.start()) running = true;
            else lanIp = "127.0.0.1";
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(NOTIFICATION_ID, buildNotification());
        return START_STICKY;
    }

    private Notification buildNotification() {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null && nm.getNotificationChannel(CHANNEL) == null) {
                NotificationChannel ch = new NotificationChannel(
                        CHANNEL, "文件共享服务", NotificationManager.IMPORTANCE_LOW);
                ch.setDescription("局域网文件共享与群聊服务");
                nm.createNotificationChannel(ch);
            }
        }
        Intent open = new Intent(this, MainActivity.class);
        int flag = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) flag |= PendingIntent.FLAG_IMMUTABLE;
        PendingIntent pi = PendingIntent.getActivity(this, 0, open, flag);

        Notification.Builder b = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL)
                : new Notification.Builder(this);
        String addr = "http://" + lanIp + ":" + PORT;
        return b.setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(running ? "共享服务运行中" : "共享服务启动失败")
                .setContentText(running ? addr + " · 其他设备可加入" : "端口可能被占用，请重启 App")
                .setContentIntent(pi)
                .setOngoing(true)
                .build();
    }

    @Override
    public void onDestroy() {
        if (server != null) {
            server.stop();
            server = null;
        }
        running = false;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
