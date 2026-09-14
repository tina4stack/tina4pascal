package com.tina4.pascal;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import org.json.JSONObject;

/**
 * Self-hosted push - a foreground service holding a long-poll to the Tina4
 * backend. No Google, no library: pure Java over the platform's own
 * HttpURLConnection, a few kilobytes, and the engine's libtina4.so is untouched.
 * Each message the server returns becomes an OS notification through Tina4Notify.
 * This is the lean default; FCM is the opt-in alternative for apps that want it.
 */
public class Tina4PushService extends Service {
    static final String CH = "tina4.push";
    private volatile boolean running = false;
    private String url, device;

    @Override public int onStartCommand(Intent i, int flags, int startId) {
        if (i != null) { url = i.getStringExtra("url"); device = i.getStringExtra("device"); }
        startForeground(1001, ongoing());
        if (!running && url != null) { running = true; new Thread(this::loop).start(); }
        return START_STICKY;
    }

    private Notification ongoing() {
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            nm.createNotificationChannel(new NotificationChannel(
                CH, "Tina4 connection", NotificationManager.IMPORTANCE_MIN));
        }
        Notification.Builder b = (Build.VERSION.SDK_INT >= 26)
            ? new Notification.Builder(this, CH) : new Notification.Builder(this);
        return b.setContentTitle("Tina4")
                .setContentText("Connected")
                .setSmallIcon(getApplicationInfo().icon)
                .build();
    }

    // Long-poll: the server holds each request open until it has a message (or a
    // timeout), we deliver it, and reconnect. A single held connection, not polling.
    private void loop() {
        while (running) {
            try {
                HttpURLConnection c = (HttpURLConnection)
                    new URL(url + (url.contains("?") ? "&" : "?") + "device=" + device).openConnection();
                c.setReadTimeout(75000);
                if (c.getResponseCode() == 200) {
                    BufferedReader r = new BufferedReader(new InputStreamReader(c.getInputStream()));
                    StringBuilder sb = new StringBuilder(); String line;
                    while ((line = r.readLine()) != null) sb.append(line);
                    r.close();
                    if (sb.length() > 0) {
                        JSONObject m = new JSONObject(sb.toString());
                        Tina4Notify.show(m.optString("title"), m.optString("body"), m.optString("tag"));
                    }
                }
                c.disconnect();
            } catch (Exception e) {
                try { Thread.sleep(5000); } catch (InterruptedException ignored) { return; }
            }
        }
    }

    @Override public void onDestroy() { running = false; }
    @Override public IBinder onBind(Intent i) { return null; }
}
