package com.tina4.pascal;

import android.app.Activity;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Bundle;
import android.provider.MediaStore;
import android.provider.OpenableColumns;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;

/** Loads assets/controls.html and hands it to the native renderer. */
public class MainActivity extends Activity {

    private static final int REQ_PICK_FILE = 42;
    private static final int REQ_CAPTURE   = 43;
    private Tina4View view;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        view = new Tina4View(this);
        setContentView(view);
        // "@demo" = built-in interactive demo; an asset name renders that page.
        view.setHtml(loadAsset("controls.html"));
    }

    /** Called from the view when an <input type=file> is tapped. */
    void pickFile(Tina4View from) {
        this.view = from;
        Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        try {
            startActivityForResult(Intent.createChooser(intent, "Select a file"), REQ_PICK_FILE);
        } catch (Exception e) { /* no picker available */ }
    }

    /** Called from the view when a <camera> tag is tapped. */
    void captureCamera(Tina4View from) {
        this.view = from;
        Intent intent = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
        try {
            startActivityForResult(intent, REQ_CAPTURE);   // thumbnail returns in the result
        } catch (Exception e) { /* no camera app */ }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (view == null || resultCode != RESULT_OK) return;
        if (requestCode == REQ_PICK_FILE && data != null && data.getData() != null) {
            view.onFilePicked(displayName(data.getData()));
        } else if (requestCode == REQ_CAPTURE && data != null) {
            // ACTION_IMAGE_CAPTURE without EXTRA_OUTPUT returns a thumbnail
            // Bitmap; save it to a file the native image loader can decode.
            Object thumb = data.getExtras() != null ? data.getExtras().get("data") : null;
            if (thumb instanceof Bitmap) {
                String path = saveBitmap((Bitmap) thumb);
                if (path != null) view.onPhotoCaptured(path);
            }
        }
    }

    /** Persist a captured bitmap to the app's files dir; return its path. */
    private String saveBitmap(Bitmap bmp) {
        String stamp = new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(new Date());
        File out = new File(getFilesDir(), "IMG_" + stamp + ".jpg");
        try (FileOutputStream fos = new FileOutputStream(out)) {
            bmp.compress(Bitmap.CompressFormat.JPEG, 90, fos);
            return out.getAbsolutePath();
        } catch (Exception e) { return null; }
    }

    /** Resolve a content: Uri to its human-readable filename. */
    private String displayName(Uri uri) {
        String name = uri.getLastPathSegment();
        try (Cursor c = getContentResolver().query(uri, null, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (i >= 0) name = c.getString(i);
            }
        } catch (Exception ignored) { }
        return name != null ? name : "file";
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
            return "<body><h1>Could not load controls.html</h1></body>";
        }
    }
}
