// C interface to the Tina4 native renderer (implemented in Pascal, linked from
// libtina4ios.a). These mirror the tina4_* exports in ios/tina4ios.pas.
#ifndef TINA4_H
#define TINA4_H

// Runtime init: call ONCE from main() before anything else touches the engine.
extern void PASCALMAIN(void);

// Touch return codes (match TINA_* in Tina4Interact).
enum { TINA_NONE = 0, TINA_SHOW_KBD = 1, TINA_HIDE_KBD = 2, TINA_FLING = 3,
       TINA_PICK_FILE = 4, TINA_CAPTURE = 5 };

void tina4_set_html(const char *html);
void tina4_frame(void *cgcontext, int w, int h, float density);
int  tina4_touch(int action, float x, float y);   // action 0=down 1=up 2=move
int  tina4_tick(void);
int  tina4_http_pending(void);                     // in-flight HTTP requests
int  tina4_ios_images_pending(void);               // in-flight <img> downloads (ImageLoader.m)
int  tina4_wants_keyboard(void);
void tina4_blur(void);
int  tina4_blink_caret(void);
void tina4_key(int codepoint);                     // 8=backspace 10=newline
int  tina4_focus_kind(void);                       // 0 none 1 text 2 textarea
int  tina4_focus_next(void);
void tina4_set_file(const char *name);
void tina4_set_photo(const char *path);

#endif
