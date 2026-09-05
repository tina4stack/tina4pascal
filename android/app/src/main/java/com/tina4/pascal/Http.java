package com.tina4.pascal;

import android.os.Handler;
import android.os.Looper;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * Android HTTP worker for the Tina4 native HTTP backend. Runs each request on
 * its own thread with java.net.HttpURLConnection — so HTTPS uses the platform's
 * native TLS (system trust store, OS updates), with no OpenSSL shipped. The
 * result is handed back to native via nativeHttpResult, which queues it for the
 * engine's HttpPump on the UI thread.
 */
public class Http {

    // implemented in libtina4.so (Java_com_tina4_pascal_Http_nativeHttpResult)
    static native void nativeHttpResult(int id, int status, String body, String error);

    // The Pascal engine is single-threaded; deliver results on the main thread.
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static void deliver(final int id, final int status,
                                final String body, final String error) {
        MAIN.post(new Runnable() {
            public void run() { nativeHttpResult(id, status, body, error); }
        });
    }

    /** Called from native Tina4HttpAndroid.Send. */
    public static void send(final int id, final String method, final String url,
                            final String body, final String ctype, final String headers) {
        new Thread(new Runnable() {
            public void run() {
                int status = 0;
                String resp = "", err = "";
                HttpURLConnection c = null;
                try {
                    c = (HttpURLConnection) new URL(url).openConnection();
                    c.setRequestMethod(method == null || method.isEmpty() ? "GET" : method);
                    c.setConnectTimeout(15000);
                    c.setReadTimeout(20000);
                    c.setInstanceFollowRedirects(true);
                    c.setRequestProperty("User-Agent", "Tina4Pascal");
                    // extra headers: one "Name: Value" per line (auth etc.)
                    if (headers != null && !headers.isEmpty()) {
                        for (String line : headers.split("\n")) {
                            int colon = line.indexOf(':');
                            if (colon < 0) continue;
                            String name = line.substring(0, colon).trim();
                            String val  = line.substring(colon + 1).trim();
                            if (!name.isEmpty()) c.setRequestProperty(name, val);
                        }
                    }
                    if (body != null && !body.isEmpty()) {
                        c.setDoOutput(true);
                        if (ctype != null && !ctype.isEmpty())
                            c.setRequestProperty("Content-Type", ctype);
                        OutputStream os = c.getOutputStream();
                        os.write(body.getBytes("UTF-8"));
                        os.close();
                    }
                    status = c.getResponseCode();
                    InputStream is = (status >= 200 && status < 400)
                        ? c.getInputStream() : c.getErrorStream();
                    resp = readAll(is);
                } catch (Exception e) {
                    err = e.toString();
                } finally {
                    if (c != null) c.disconnect();
                }
                deliver(id, status, resp, err);   // hop to the main thread
            }
        }).start();
    }

    private static String readAll(InputStream is) throws Exception {
        if (is == null) return "";
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = is.read(buf)) > 0) out.write(buf, 0, n);
        is.close();
        return out.toString("UTF-8");
    }
}
