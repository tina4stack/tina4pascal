package com.tina4.pascal;

import android.app.Activity;
import android.os.Bundle;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;

/** Loads assets/index.html and hands it to the native renderer. */
public class MainActivity extends Activity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Tina4View view = new Tina4View(this);
        setContentView(view);
        // "@demo" triggers the built-in interactive demo (scroll + buttons +
        // input). Swap for loadAsset("index.html") to render a static page.
        view.setHtml("@demo");
    }

    private String loadAsset(String name) {
        try {
            InputStream is = getAssets().open(name);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = is.read(buf)) > 0) out.write(buf, 0, n);
            is.close();
            return out.toString("UTF-8");
        } catch (Exception e) {
            return "<body><h1>Could not load index.html</h1></body>";
        }
    }
}
