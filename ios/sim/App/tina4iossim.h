// C interface to the Tina4 iOS-Simulator engine (implemented in Pascal, linked
// from libtina4iossim.a — build it with ios/build-sim.sh). By default this is
// the NATIVE Core Graphics / Core Text canvas (device-identical); the symbols
// mirror the exports in ios/sim/native/tina4iossimnative.pas.
//
// (The --raster build exports tina4sim_set_html / tina4sim_render / tina4sim_touch
// instead — a returned RGBA buffer rather than drawing into a CGContext.)
#ifndef TINA4IOSSIM_H
#define TINA4IOSSIM_H

#include <CoreGraphics/CoreGraphics.h>

// Runtime init: call ONCE at launch before anything else touches the engine.
// PASCALMAIN runs the FPC runtime + every unit's initialization.
extern void PASCALMAIN(void);

// Load a document (UTF-8 HTML).
void tina4sim_native_set_html(const char *html);
// Paint the current document into a CGContext (a UIView drawRect context: points,
// top-left origin, density 1). w×h are the view's point size.
void tina4sim_native_frame(CGContextRef ctx, int w, int h, float density);
// Dispatch a touch (action 0=down 1=up 2=move); non-zero if the frame changed.
int  tina4sim_native_touch(int action, float x, float y);

#endif
