package com.tina4.pascal;

import android.content.Context;
import android.graphics.Canvas;
import android.view.MotionEvent;
import android.view.View;

/**
 * The whole UI: a single custom View whose every pixel is drawn by the native
 * Tina4 renderer (libtina4.so). onDraw hands the native side an android Canvas;
 * the Pascal core lays out the HTML and paints straight onto it.
 */
public class Tina4View extends View {

    static { System.loadLibrary("tina4"); }

    private native void nativeSetHtml(String html);
    private native void nativePaint(Canvas canvas, int w, int h);
    private native void nativeTouch(int action, float x, float y);

    public Tina4View(Context context) {
        super(context);
        setFocusable(true);
    }

    /** Set the document to render (HTML string). */
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
        int action = -1;
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN: action = 0; break;
            case MotionEvent.ACTION_UP:   action = 1; break;
            case MotionEvent.ACTION_MOVE: action = 2; break;
        }
        if (action >= 0) {
            nativeTouch(action, e.getX(), e.getY());
            invalidate();
        }
        return true;
    }
}
