package com.tina4.pascal;

import android.os.Handler;
import android.os.Looper;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/**
 * Async remote-image loader for the Tina4 Android canvas. Downloads an <img src>
 * over HttpURLConnection (the platform's native TLS — no OpenSSL) to a disk cache,
 * then calls nativeImageReady so the engine relayouts and TAndroidCanvas.LoadImage
 * decodes the now-present file with BitmapFactory. Idempotent per URL; the decoded
 * Bitmap is then held in the canvas's in-memory cache for instant re-renders.
 */
public class ImageLoader {

    // implemented in libtina4.so (Java_com_tina4_pascal_ImageLoader_nativeImageReady)
    static native void nativeImageReady();

    private static File cacheDir;
    private static Tina4View view;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final Set<String> inflight = Collections.synchronizedSet(new HashSet<String>());

    // A single shared main-thread callback (no per-URL capture) — relayout +
    // repaint once an image lands. Kept as a field so D8 doesn't have to dex a
    // doubly-nested anonymous class.
    private static final Runnable READY = new Runnable() {
        public void run() {
            nativeImageReady();
            if (view != null) view.invalidate();
        }
    };

    /** Called once from MainActivity: where to cache, and who to repaint. */
    static void init(File appCacheDir, Tina4View v) {
        cacheDir = new File(appCacheDir, "tina4render");
        cacheDir.mkdirs();
        view = v;
    }

    private static File fileFor(String url) { return new File(cacheDir, md5(url) + ".img"); }

    /** Local path if the image is cached; otherwise "" and an async download starts. */
    public static String cached(String url) {
        if (cacheDir == null || url == null || url.isEmpty()) return "";
        File f = fileFor(url);
        if (f.exists()) return f.getAbsolutePath();
        request(url, f);
        return "";
    }

    private static void request(final String url, final File f) {
        if (!inflight.add(url)) return;                 // already downloading
        new Thread(new Runnable() {
            public void run() {
                HttpURLConnection c = null;
                try {
                    c = (HttpURLConnection) new URL(url).openConnection();
                    c.setConnectTimeout(15000);
                    c.setReadTimeout(20000);
                    c.setInstanceFollowRedirects(true);
                    c.setRequestProperty("User-Agent", "Tina4Pascal");
                    InputStream is = c.getInputStream();
                    File tmp = new File(f.getAbsolutePath() + ".tmp");
                    OutputStream os = new FileOutputStream(tmp);
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = is.read(buf)) > 0) os.write(buf, 0, n);
                    os.close();
                    is.close();
                    tmp.renameTo(f);                    // atomic — no half-written file decoded
                } catch (Exception e) {
                    /* leave uncached; a later relayout retries */
                } finally {
                    if (c != null) c.disconnect();
                    inflight.remove(url);
                    MAIN.post(READY);                   // relayout + repaint on main thread
                }
            }
        }).start();
    }

    private static String md5(String s) {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            byte[] d = md.digest(s.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(s.hashCode());
        }
    }
}
