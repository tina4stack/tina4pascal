package com.tina4.pascal;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.ImageFormat;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.media.Image;
import android.media.ImageReader;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;
import android.view.Surface;
import android.view.TextureView;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.MultiFormatReader;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;

/** Live camera barcode/QR scanner for &lt;barcode-scanner&gt;: a Camera2 preview
 *  in a TextureView plus ZXing decode of the YUV frames. Pure platform + ZXing —
 *  no Gradle, no Play Services. The view is positioned by Tina4View over the
 *  engine's scanner box; a decode calls back to nativeScanResult. */
public class Tina4Scanner implements TextureView.SurfaceTextureListener {
    public interface Callback { void onScan(String value, String format); }

    private final Context ctx;
    private final Callback cb;
    public final TextureView view;

    private CameraDevice camera;
    private CameraCaptureSession session;
    private ImageReader reader;
    private CaptureRequest.Builder req;
    private HandlerThread bg;
    private Handler bgHandler;
    private final MultiFormatReader zxing = new MultiFormatReader();
    private volatile boolean torch = false;
    private volatile boolean opening = false;
    private long lastAt = 0;

    private static final int PREV_W = 1280, PREV_H = 720;

    Tina4Scanner(Context ctx, String formats, Callback cb) {
        this.ctx = ctx; this.cb = cb;
        this.view = new TextureView(ctx);
        this.view.setSurfaceTextureListener(this);
        Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
        hints.put(DecodeHintType.POSSIBLE_FORMATS, formatsToZxing(formats == null ? "" : formats));
        hints.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);   // scan more rows/angles
        zxing.setHints(hints);
    }

    private static List<BarcodeFormat> formatsToZxing(String f) {
        f = f.toLowerCase();
        List<BarcodeFormat> out = new ArrayList<>();
        if (f.isEmpty()) {
            out.add(BarcodeFormat.QR_CODE); out.add(BarcodeFormat.EAN_13);
            out.add(BarcodeFormat.EAN_8); out.add(BarcodeFormat.CODE_128);
            out.add(BarcodeFormat.CODE_39); out.add(BarcodeFormat.UPC_A);
            return out;
        }
        if (f.contains("qr")) out.add(BarcodeFormat.QR_CODE);
        if (f.contains("ean13")) {
            out.add(BarcodeFormat.EAN_13);
            // UPC-A/UPC-E are the same 1D family printed on retail goods; a page
            // that asks for ean13 means "retail codes", so accept them too.
            out.add(BarcodeFormat.UPC_A); out.add(BarcodeFormat.UPC_E);
        }
        if (f.contains("ean8")) out.add(BarcodeFormat.EAN_8);
        if (f.contains("code128")) out.add(BarcodeFormat.CODE_128);
        if (f.contains("code39")) out.add(BarcodeFormat.CODE_39);
        if (f.contains("code93")) out.add(BarcodeFormat.CODE_93);
        if (f.contains("upce")) out.add(BarcodeFormat.UPC_E);
        if (f.contains("upca")) out.add(BarcodeFormat.UPC_A);
        if (f.contains("pdf417")) out.add(BarcodeFormat.PDF_417);
        if (f.contains("aztec")) out.add(BarcodeFormat.AZTEC);
        if (f.contains("datamatrix")) out.add(BarcodeFormat.DATA_MATRIX);
        if (out.isEmpty()) out.add(BarcodeFormat.QR_CODE);
        return out;
    }

    /** Camera permission — granted, or ask the host Activity once (returns false). */
    static boolean ensurePermission(Context ctx) {
        if (Build.VERSION.SDK_INT < 23) return true;
        if (ctx.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
            return true;
        if (ctx instanceof Activity)
            ((Activity) ctx).requestPermissions(new String[]{ Manifest.permission.CAMERA }, 4711);
        return false;
    }

    /** Re-attempt opening the camera (e.g. after the user grants permission). */
    void retryOpen() { open(); }

    void setTorch(boolean on) {
        if (torch == on) return;
        torch = on;
        try {
            if (session != null && req != null) {
                req.set(CaptureRequest.FLASH_MODE,
                        torch ? CaptureRequest.FLASH_MODE_TORCH : CaptureRequest.FLASH_MODE_OFF);
                session.setRepeatingRequest(req.build(), null, bgHandler);
            }
        } catch (Exception e) { /* torch not available */ }
    }

    @Override public void onSurfaceTextureAvailable(SurfaceTexture st, int w, int h) { open(); }
    @Override public void onSurfaceTextureSizeChanged(SurfaceTexture st, int w, int h) {}
    @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture st) { close(); return true; }
    @Override public void onSurfaceTextureUpdated(SurfaceTexture st) {}

    private void open() {
        if (opening || camera != null) return;
        if (!ensurePermission(ctx)) return;   // retries when the view re-lays out after grant
        if (view.getSurfaceTexture() == null) return;
        opening = true;
        bg = new HandlerThread("tina4-cam"); bg.start(); bgHandler = new Handler(bg.getLooper());
        CameraManager cm = (CameraManager) ctx.getSystemService(Context.CAMERA_SERVICE);
        try {
            String id = backCamera(cm);
            if (id == null) { opening = false; return; }
            reader = ImageReader.newInstance(PREV_W, PREV_H, ImageFormat.YUV_420_888, 2);
            reader.setOnImageAvailableListener(onFrame, bgHandler);
            cm.openCamera(id, stateCb, bgHandler);
        } catch (Exception e) { opening = false; }
    }

    private String backCamera(CameraManager cm) throws CameraAccessException {
        String[] ids = cm.getCameraIdList();
        for (String id : ids) {
            Integer f = cm.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING);
            if (f != null && f == CameraCharacteristics.LENS_FACING_BACK) return id;
        }
        return ids.length > 0 ? ids[0] : null;
    }

    private final CameraDevice.StateCallback stateCb = new CameraDevice.StateCallback() {
        @Override public void onOpened(CameraDevice cam) {
            camera = cam; opening = false;
            try {
                SurfaceTexture st = view.getSurfaceTexture();
                if (st == null) return;
                st.setDefaultBufferSize(PREV_W, PREV_H);
                Surface preview = new Surface(st);
                req = cam.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
                req.addTarget(preview);
                req.addTarget(reader.getSurface());
                List<Surface> outs = new ArrayList<>();
                outs.add(preview); outs.add(reader.getSurface());
                cam.createCaptureSession(outs, sessionCb, bgHandler);
            } catch (Exception e) { /* ignore */ }
        }
        @Override public void onDisconnected(CameraDevice cam) { cam.close(); camera = null; opening = false; }
        @Override public void onError(CameraDevice cam, int err) { cam.close(); camera = null; opening = false; }
    };

    private final CameraCaptureSession.StateCallback sessionCb = new CameraCaptureSession.StateCallback() {
        @Override public void onConfigured(CameraCaptureSession s) {
            session = s;
            try {
                req.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE);
                s.setRepeatingRequest(req.build(), null, bgHandler);
            } catch (Exception e) { /* ignore */ }
        }
        @Override public void onConfigureFailed(CameraCaptureSession s) {}
    };

    private final ImageReader.OnImageAvailableListener onFrame = new ImageReader.OnImageAvailableListener() {
        @Override public void onImageAvailable(ImageReader r) {
            Image img = null;
            try {
                img = r.acquireLatestImage();
                if (img == null) return;
                int w = img.getWidth(), h = img.getHeight();
                Image.Plane yp = img.getPlanes()[0];
                int rowStride = yp.getRowStride();
                ByteBuffer yb = yp.getBuffer();
                byte[] data = new byte[yb.remaining()];
                yb.get(data);

                // The camera sensor delivers landscape frames; a phone held in
                // portrait sees 1D barcodes with their bars running VERTICALLY in
                // this buffer, which ZXing's row-scanning 1D readers can't read.
                // Decode the frame as-is (catches sensor-aligned codes, all QR),
                // then a transposed copy (turns vertical bars horizontal).
                Result res = decode(data, rowStride, w, h);
                if (res == null) {
                    byte[] t = transpose(data, rowStride, w, h);
                    res = decode(t, h, h, w);   // transposed: rowStride = new width = h
                }
                long now = SystemClock.uptimeMillis();
                if (res != null && res.getText() != null && now - lastAt > 1500) {
                    lastAt = now;
                    // Hop to the UI thread. A NAMED Runnable, not an anonymous one
                    // nested inside this anonymous listener — d8 8.2.2 NPEs when
                    // dexing a doubly-nested anonymous class.
                    view.post(new Deliver(cb, res.getText(), res.getBarcodeFormat().toString()));
                }
            } catch (Exception e) {
                /* ignore a bad frame */
            } finally {
                if (img != null) img.close();
            }
        }
    };

    /** One decode attempt over a grayscale buffer; null if no code is found. */
    private Result decode(byte[] gray, int rowStride, int w, int h) {
        try {
            PlanarYUVLuminanceSource src = new PlanarYUVLuminanceSource(
                    gray, rowStride, h, 0, 0, Math.min(w, rowStride), h, false);
            return zxing.decodeWithState(new BinaryBitmap(new HybridBinarizer(src)));
        } catch (Exception notFound) {
            return null;                       // NotFoundException etc.
        } finally {
            zxing.reset();
        }
    }

    /** Transpose the w×h luminance image (swap x/y). Vertical bars become
     *  horizontal so the 1D readers can scan them; output is h wide, w tall. */
    private static byte[] transpose(byte[] src, int rowStride, int w, int h) {
        byte[] out = new byte[w * h];
        for (int y = 0; y < h; y++) {
            int row = y * rowStride;
            for (int x = 0; x < w; x++)
                out[x * h + y] = src[row + x];
        }
        return out;
    }

    /** Delivers a decode to the Callback on the UI thread (posted from the frame
     *  thread). A top-level named class so d8 doesn't choke on nested anonymers. */
    private static final class Deliver implements Runnable {
        private final Callback cb; private final String value, format;
        Deliver(Callback cb, String value, String format) {
            this.cb = cb; this.value = value; this.format = format;
        }
        public void run() { cb.onScan(value, format); }
    }

    void close() {
        try { if (session != null) session.close(); } catch (Exception e) {}
        try { if (camera != null) camera.close(); } catch (Exception e) {}
        try { if (reader != null) reader.close(); } catch (Exception e) {}
        if (bg != null) { bg.quitSafely(); bg = null; }
        session = null; camera = null; reader = null; req = null; opening = false;
    }
}
