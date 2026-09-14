package com.tina4.pascal;

import android.content.Context;
import android.content.Intent;
import android.os.Build;

/**
 * Android push provider switch. Two providers feed the same OS notification
 * (Tina4Notify), and an app enables whichever it wants:
 *
 *   - Self-hosted (Tina4PushService) - lean default, no Google, ~kilobytes.
 *     startSelfHosted(ctx, "https://your-backend/push/poll", deviceId).
 *
 *   - Firebase Cloud Messaging (FCM) - opt-in. Drop in firebase-messaging (bundled
 *     as an .aar so the manual aapt2/d8 build swallows it) plus google-services.json;
 *     a FirebaseMessagingService calls Tina4Notify.show and hands its token to
 *     native tina4_push_token. Only apps that enable it pay the several-megabyte
 *     Firebase/Play-Services cost - the baseline engine stays tiny.
 */
public class Tina4Push {
    public static void startSelfHosted(Context ctx, String url, String device) {
        Intent i = new Intent(ctx, Tina4PushService.class);
        i.putExtra("url", url);
        i.putExtra("device", device);
        if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i);
        else ctx.startService(i);
    }

    public static void stop(Context ctx) {
        ctx.stopService(new Intent(ctx, Tina4PushService.class));
    }
}
