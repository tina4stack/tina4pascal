package com.tina4.pascal;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

/**
 * Local notifications for the Tina4 engine. Native (Tina4NotifyAndroid.pas) calls
 * show(); an HTML notify.show('Title','Body') — or an SSE/WebSocket handler
 * calling Tina4Notify — lands here. init() is called from MainActivity.onCreate
 * to hold the app context and create the channel. Local only; remote (FCM) is
 * Phase 2, and it posts through this same path.
 */
public class Tina4Notify {
    private static Context APP;
    private static final String CH = "tina4.default";
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static int seq = 1;

    public static void init(Context ctx) {
        APP = ctx.getApplicationContext();
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm =
                (NotificationManager) APP.getSystemService(Context.NOTIFICATION_SERVICE);
            NotificationChannel ch = new NotificationChannel(
                CH, "Tina4", NotificationManager.IMPORTANCE_DEFAULT);
            nm.createNotificationChannel(ch);
        }
        // POST_NOTIFICATIONS runtime permission (API 33+) is requested by MainActivity.
    }

    // called from native via JNI — deliver on the main thread
    public static void show(final String title, final String body, final String tag) {
        if (APP == null) return;
        MAIN.post(new Runnable() {
            public void run() {
                NotificationManager nm =
                    (NotificationManager) APP.getSystemService(Context.NOTIFICATION_SERVICE);
                Notification.Builder b = (Build.VERSION.SDK_INT >= 26)
                    ? new Notification.Builder(APP, CH)
                    : new Notification.Builder(APP);
                b.setContentTitle(title)
                 .setContentText(body)
                 .setSmallIcon(APP.getApplicationInfo().icon)
                 .setAutoCancel(true);
                int id = (tag != null && tag.length() > 0) ? tag.hashCode() : seq++;
                nm.notify(id, b.build());
            }
        });
    }
}
