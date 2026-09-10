// C interface to the Tina4 watchOS engine (implemented in Pascal, linked from
// libtina4watch.a — build it with `tools/tina4pascal build watchsim`). These
// mirror the exports in watch/tina4watch.pas.
#ifndef TINA4WATCH_H
#define TINA4WATCH_H

// Runtime init: call ONCE at launch before anything else touches the engine.
// PASCALMAIN runs the FPC runtime + every unit's initialization.
extern void PASCALMAIN(void);

// Create the software raster canvas at w×h pixels and bind the engine to it.
void  tina4watch_init(int w, int h);
// Load a document (UTF-8 HTML).
void  tina4watch_set_html(const char *html);
// Paint a frame; returns a pointer to the w*h*4 pixel buffer. Each pixel is a
// 32-bit word $AARRGGBB (straight alpha), row-major, top-left origin — i.e. on
// little-endian arm64 the bytes in memory are B,G,R,A. The pointer stays valid
// until the next init/render at a different size.
void *tina4watch_render(int w, int h, float density);
// Dispatch a touch (action 0=down 1=up 2=move); non-zero if the frame changed.
int   tina4watch_touch(int action, float x, float y);

#endif
