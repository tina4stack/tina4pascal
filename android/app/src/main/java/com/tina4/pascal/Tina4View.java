package com.tina4.pascal;

import android.content.Context;
import android.graphics.Canvas;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;

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
    native void nativeKey(int codepoint);   // package-visible for KeyInput

    // IME "Done": drop focus + hide the keyboard
    void imeDone() { nativeBlur(); hideKeyboard(); stopCaret(); invalidate(); }

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

    private boolean pendingKeyboard;

    public void setHtml(String html) {
        nativeSetHtml(html);
        pendingKeyboard = nativeWantsKeyboard() != 0;   // autofocus
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
        // autofocus: first real frame is the reliable moment to raise the kbd
        if (pendingKeyboard) { pendingKeyboard = false; showKeyboard(); }
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        int action;
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: action = 0; requestFocus(); stopFling(); break;
            case MotionEvent.ACTION_UP:   action = 1; break;
            case MotionEvent.ACTION_MOVE: action = 2; break;
            default: return true;
        }
        int r = nativeTouch(action, e.getX(), e.getY());
        if (r == 1) showKeyboard();
        else if (r == 2) hideKeyboard();
        else if (r == 3) startFling();
        invalidate();
        return true;
    }

    private void showKeyboard() {
        requestFocus();
        InputMethodManager imm =
            (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) imm.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT);
        startCaret();   // begin blinking the input caret
    }

    private void hideKeyboard() {
        InputMethodManager imm =
            (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) imm.hideSoftInputFromWindow(getWindowToken(), 0);
    }

    // --- soft-keyboard input: feed characters + backspace to the native side ---

    @Override
    public boolean onCheckIsTextEditor() { return true; }

    // hardware keys and injected key events (e.g. `adb shell input text`)
    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_DEL) { nativeKey(8); invalidate(); return true; }
        int u = event.getUnicodeChar();
        if (u != 0) { nativeKey(u); invalidate(); return true; }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        // NO_SUGGESTIONS stops predictive keyboards from using composing text
        // (which we don't track) — they commitText each character instead.
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT
            | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
        outAttrs.imeOptions = EditorInfo.IME_ACTION_DONE
            | EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN;
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
        public boolean performEditorAction(int actionCode) { view.imeDone(); return true; }
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
                if (code == KeyEvent.KEYCODE_ENTER) { view.imeDone(); return true; }
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
