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
public class Tina4View extends View {

    static { System.loadLibrary("tina4"); }

    private native void nativeSetHtml(String html);
    private native void nativePaint(Canvas canvas, int w, int h);
    private native int  nativeTouch(int action, float x, float y);
    native void nativeKey(int codepoint);   // package-visible for KeyInput

    public Tina4View(Context context) {
        super(context);
        setFocusable(true);
        setFocusableInTouchMode(true);
    }

    public void setHtml(String html) {
        nativeSetHtml(html);
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        nativePaint(canvas, getWidth(), getHeight());
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
        int action;
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: action = 0; requestFocus(); break;
            case MotionEvent.ACTION_UP:   action = 1; break;
            case MotionEvent.ACTION_MOVE: action = 2; break;
            default: return true;
        }
        int r = nativeTouch(action, e.getX(), e.getY());
        if (r == 1) showKeyboard();
        else if (r == 2) hideKeyboard();
        invalidate();
        return true;
    }

    private void showKeyboard() {
        requestFocus();
        InputMethodManager imm =
            (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) imm.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT);
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
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT;
        outAttrs.imeOptions = EditorInfo.IME_ACTION_DONE | EditorInfo.IME_FLAG_NO_EXTRACT_UI;
        return new KeyInput(this);
    }

    /** Named (not anonymous) so d8 stays happy; forwards IME text to nativeKey. */
    private static final class KeyInput extends BaseInputConnection {
        private final Tina4View view;
        KeyInput(Tina4View v) { super(v, false); this.view = v; }

        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            for (int i = 0; i < text.length(); i++) view.nativeKey(text.charAt(i));
            view.invalidate();
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
                if (event.getKeyCode() == KeyEvent.KEYCODE_DEL) {
                    view.nativeKey(8); view.invalidate(); return true;
                }
                int u = event.getUnicodeChar();
                if (u != 0) { view.nativeKey(u); view.invalidate(); return true; }
            }
            return super.sendKeyEvent(event);
        }
    }
}
