package com.tina4.pascal;

import android.content.Context;
import android.graphics.Canvas;
import android.media.MediaPlayer;
import android.net.Uri;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import android.widget.FrameLayout;
import android.widget.MediaController;
import android.widget.VideoView;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Map;

/**
 * The whole UI: a single custom View whose every pixel is drawn by the native
 * Tina4 renderer (libtina4.so). onDraw hands the native side an android Canvas;
 * the Pascal core lays out the HTML and paints straight onto it. Touches drive
 * scrolling / onclick natively; typed characters are forwarded to nativeKey.
 */
public class Tina4View extends View implements Runnable {

    static { System.loadLibrary("tina4"); }

    private native void nativeSetHtml(String html);
    private native void nativePaint(Canvas canvas, int w, int h, float density);
    private native int  nativeTouch(int action, float x, float y);
    private native int  nativeTick();
    private native int  nativeWantsKeyboard();
    private native void nativeBlur();
    private native int  nativeBlinkCaret();
    native void nativeKey(int codepoint);        // package-visible for KeyInput
    native int  nativeFocusKind();               // 0 none, 1 text, 2 textarea
    private native int nativeFocusNext();        // move to next field; new kind (0=none)
    private native void nativeSetFile(String name);   // picked filename → the <input type=file>
    private native void nativeSetPhoto(String path);  // captured image path → <img id="shot">
    private native int    nativeEmbedCount();          // laid-out <video> boxes
    private native float[] nativeEmbedRect(int index); // [x,y,w,h] in CSS px (scroll applied)
    private native String  nativeEmbedSrc(int index);  // the video source URL
    private native int     nativeEmbedFlags(int index);// 1 controls·2 autoplay·4 loop·8 muted

    /** Called by MainActivity once the system file picker returns a name. */
    void onFilePicked(String name) { nativeSetFile(name); invalidate(); }

    /** Called by MainActivity once a photo has been captured and saved to path. */
    void onPhotoCaptured(String path) { nativeSetPhoto(path); invalidate(); }

    // IME "Done": drop focus + hide the keyboard
    void imeDone() { nativeBlur(); hideKeyboard(); stopCaret(); invalidate(); }

    // IME "Next" / Tab: jump to the next input, or finish if there is none
    void imeNext() {
        if (nativeFocusNext() == 0) imeDone();
        else { restartIme(); startCaret(); invalidate(); }  // keyboard stays for the new field
    }

    // Enter pressed: newline inside a textarea, otherwise advance to the next field
    void imeEnter() {
        if (nativeFocusKind() == 2) { nativeKey(10); invalidate(); }
        else imeNext();
    }

    private void restartIme() {
        InputMethodManager imm =
            (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) imm.restartInput(this);   // re-read inputType for the new field
    }

    // blinking text caret while an input is focused. Static nested class (with
    // an explicit view ref) — d8 8.2.2 chokes on JDK-25 non-static/anon classes.
    private final Blinker blinker = new Blinker(this);
    private static final class Blinker implements Runnable {
        private final Tina4View v;
        Blinker(Tina4View v) { this.v = v; }
        public void run() {
            if (v.nativeBlinkCaret() != 0) { v.invalidate(); v.postDelayed(this, 500); }
            else v.invalidate();
        }
    }
    private void startCaret() { removeCallbacks(blinker); postDelayed(blinker, 500); }
    private void stopCaret()  { removeCallbacks(blinker); }

    private final float density;

    public Tina4View(Context context) {
        super(context);
        density = getResources().getDisplayMetrics().density;
        setFocusable(true);
        setFocusableInTouchMode(true);
    }

    public void setHtml(String html) {
        nativeSetHtml(html);
        invalidate();
    }


    // fling: the native side decays the velocity; we re-post each frame
    @Override
    public void run() {
        if (nativeTick() != 0) { invalidate(); postOnAnimation(this); }
    }
    private void startFling() { removeCallbacks(this); postOnAnimation(this); }
    private void stopFling()  { removeCallbacks(this); }

    @Override
    protected void onDraw(Canvas canvas) {
        nativePaint(canvas, getWidth(), getHeight(), density);
        // autofocus: the engine parses on the first frame, so poll here (it
        // returns 1 exactly once, after an input[autofocus] has been focused)
        if (nativeWantsKeyboard() != 0) showKeyboard();
        // overlay/position native <video> players — off the draw pass (mutating
        // the view hierarchy during onDraw is unsafe), coalesced to one per frame
        removeCallbacks(videoSync);
        post(videoSync);
    }

    // --- native <video> overlays --------------------------------------------
    // Each <video> the engine lays out gets a sibling VideoView (with a
    // MediaController for play/pause/scrub), positioned over the poster box in
    // the parent FrameLayout and reused across frames; removed when the box goes.
    private final Map<String, VideoView> videoViews = new HashMap<>();
    private final Runnable videoSync = new VideoSync(this);

    private static final class VideoSync implements Runnable {
        private final Tina4View v;
        VideoSync(Tina4View v) { this.v = v; }
        public void run() { v.syncVideos(); }
    }

    // apply the <video> attributes once the media is prepared
    private static final class PreparedApply implements MediaPlayer.OnPreparedListener {
        private final VideoView v;
        private final boolean autoplay, loop, muted;
        PreparedApply(VideoView v, boolean autoplay, boolean loop, boolean muted) {
            this.v = v; this.autoplay = autoplay; this.loop = loop; this.muted = muted;
        }
        public void onPrepared(MediaPlayer mp) {
            mp.setLooping(loop);                                 // `loop`
            mp.setVolume(muted ? 0f : 1f, muted ? 0f : 1f);      // `muted`
            if (autoplay) v.start();                             // `autoplay`
            else v.seekTo(1);                                    // show first frame, paused
        }
    }

    private void syncVideos() {
        if (!(getParent() instanceof ViewGroup)) return;
        ViewGroup parent = (ViewGroup) getParent();
        int n = nativeEmbedCount();
        HashSet<String> live = new HashSet<>();
        for (int i = 0; i < n; i++) {
            String src = nativeEmbedSrc(i);
            float[] r = nativeEmbedRect(i);
            if (src == null || src.isEmpty() || r == null || r.length < 4
                || r[2] <= 0 || r[3] <= 0) continue;
            live.add(src);
            int x = Math.round(r[0] * density), y = Math.round(r[1] * density);
            int w = Math.round(r[2] * density), h = Math.round(r[3] * density);
            VideoView vv = videoViews.get(src);
            if (vv == null) {
                int flags = nativeEmbedFlags(i);   // 1 controls·2 autoplay·4 loop·8 muted
                boolean controls = (flags & 1) != 0, autoplay = (flags & 2) != 0,
                        loop = (flags & 4) != 0, muted = (flags & 8) != 0;
                vv = new VideoView(getContext());
                vv.setVideoURI(Uri.parse(src));
                if (controls) {                                  // `controls`
                    MediaController mc = new MediaController(getContext());
                    mc.setAnchorView(vv);
                    vv.setMediaController(mc);
                }
                vv.setOnPreparedListener(new PreparedApply(vv, autoplay, loop, muted));
                FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(w, h);
                lp.leftMargin = x; lp.topMargin = y;
                parent.addView(vv, lp);
                videoViews.put(src, vv);
            } else {
                FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) vv.getLayoutParams();
                lp.width = w; lp.height = h; lp.leftMargin = x; lp.topMargin = y;
                vv.setLayoutParams(lp);
            }
        }
        // tear down players whose <video> is no longer laid out
        Iterator<Map.Entry<String, VideoView>> it = videoViews.entrySet().iterator();
        while (it.hasNext()) {
            Map.Entry<String, VideoView> e = it.next();
            if (!live.contains(e.getKey())) {
                VideoView vv = e.getValue();
                vv.stopPlayback();
                parent.removeView(vv);
                it.remove();
            }
        }
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        int action;
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: action = 0; stopFling(); break;
            case MotionEvent.ACTION_UP:   action = 1; break;
            case MotionEvent.ACTION_MOVE: action = 2; break;
            default: return true;
        }
        int r = nativeTouch(action, e.getX(), e.getY());
        if (r == 1) showKeyboard();
        else if (r == 3) startFling();
        else if (r == 4) pickFile();
        else if (r == 5) captureCamera();
        // Deterministic keyboard rule: it is up only while a text field is
        // focused. Any touch that leaves nothing focused (checkbox, radio,
        // select, button, empty space) dismisses it — no stray pop-ups.
        if (r != 1 && nativeFocusKind() == 0) hideKeyboard();
        invalidate();
        return true;
    }

    private void showKeyboard() {
        requestFocus();
        InputMethodManager imm =
            (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) {
            imm.restartInput(this);   // configure the IME for the field just focused
            imm.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT);
        }
        startCaret();   // begin blinking the input caret
    }

    private void hideKeyboard() {
        InputMethodManager imm =
            (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) imm.hideSoftInputFromWindow(getWindowToken(), 0);
    }

    // launch the system document picker via the hosting Activity
    private void pickFile() {
        Context c = getContext();
        if (c instanceof MainActivity) ((MainActivity) c).pickFile(this);
    }

    // launch the camera capture intent via the hosting Activity
    private void captureCamera() {
        Context c = getContext();
        if (c instanceof MainActivity) ((MainActivity) c).captureCamera(this);
    }

    // --- soft-keyboard input: feed characters + backspace to the native side ---

    // Only claim to be a text editor while a text field is actually focused —
    // otherwise a tap on a checkbox/radio/button would raise the soft keyboard.
    @Override
    public boolean onCheckIsTextEditor() { return nativeFocusKind() != 0; }

    // hardware keys and injected key events (e.g. `adb shell input text`)
    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_DEL)   { nativeKey(8); invalidate(); return true; }
        if (keyCode == KeyEvent.KEYCODE_TAB)   { imeNext();  return true; }
        if (keyCode == KeyEvent.KEYCODE_ENTER) { imeEnter(); return true; }
        int u = event.getUnicodeChar();
        if (u != 0) { nativeKey(u); invalidate(); return true; }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        // NO_SUGGESTIONS stops predictive keyboards from using composing text
        // (which we don't track) — they commitText each character instead.
        int type = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
        if (nativeFocusKind() == 2) {
            // textarea: multi-line, Enter inserts a newline (no action button)
            type |= InputType.TYPE_TEXT_FLAG_MULTI_LINE;
            outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI
                | EditorInfo.IME_FLAG_NO_FULLSCREEN;
        } else {
            // single-line: the action button advances to the next field
            outAttrs.imeOptions = EditorInfo.IME_ACTION_NEXT
                | EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN;
        }
        outAttrs.inputType = type;
        return new KeyInput(this);
    }

    /** Named (not anonymous) so d8 stays happy; forwards IME text to nativeKey. */
    private static final class KeyInput extends BaseInputConnection {
        private final Tina4View view;
        KeyInput(Tina4View v) { super(v, false); this.view = v; }

        private int composing = 0;
        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            for (int i = 0; i < composing; i++) view.nativeKey(8);      // erase composing run
            composing = 0;
            for (int i = 0; i < text.length(); i++) view.nativeKey(text.charAt(i));
            view.invalidate();
            return true;
        }
        // fallback for keyboards that still compose: replace the previous
        // composing run, then re-emit the new text so each char lands
        @Override
        public boolean setComposingText(CharSequence text, int newCursorPosition) {
            for (int i = 0; i < composing; i++) view.nativeKey(8);      // erase old
            for (int i = 0; i < text.length(); i++) view.nativeKey(text.charAt(i));
            composing = text.length();
            view.invalidate();
            return true;
        }
        @Override
        public boolean finishComposingText() { composing = 0; return true; }
        @Override
        public boolean performEditorAction(int actionCode) {
            // A textarea always keeps Enter as a newline, even if the IME still
            // advertises a NEXT action from a stale input config.
            if (view.nativeFocusKind() == 2) { view.nativeKey(10); view.invalidate(); }
            else if (actionCode == EditorInfo.IME_ACTION_NEXT) view.imeNext();
            else view.imeDone();
            return true;
        }
        @Override
        public boolean deleteSurroundingText(int before, int after) {
            for (int i = 0; i < before; i++) view.nativeKey(8); // backspace
            view.invalidate();
            return true;
        }
        @Override
        public boolean sendKeyEvent(KeyEvent event) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                int code = event.getKeyCode();
                if (code == KeyEvent.KEYCODE_ENTER) { view.imeEnter(); return true; }
                if (code == KeyEvent.KEYCODE_TAB)   { view.imeNext();  return true; }
                if (code == KeyEvent.KEYCODE_DEL) {
                    view.nativeKey(8); view.invalidate(); return true;
                }
                int u = event.getUnicodeChar();
                if (u != 0) { view.nativeKey(u); view.invalidate(); return true; }
            }
            return super.sendKeyEvent(event);
        }
    }
}
