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
void tina4_set_asset_base(const char *dir);        // base for relative <img src="assets/…">

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

// Native media embeds (<video>): after a frame, ask the engine which <video>
// boxes are laid out and where (screen points, scroll applied), to overlay a
// native AVPlayer over each. Call tina4_embed_count() first (it snapshots the
// current layout), then read each embed's rect + source URL.
int  tina4_embed_count(void);
void tina4_embed_rect(int index, float *x, float *y, float *w, float *h);
int  tina4_embed_src(int index, char *buf, int cap);   // fills buf, returns length
int  tina4_embed_flags(int index);                     // 1 controls·2 autoplay·4 loop·8 muted
int  tina4_embed_poster(int index, char *buf, int cap);// poster URL ('' if none)
int  tina4_embed_kind(int index);                      // 0 = video · 1 = audio

#endif
