// draw.h — emit the wasmcraft "web" draw protocol on stdout.
//
// A frame is a sequence of line-based commands the Lua host (dist/browser.lua)
// parses and paints onto a CC:Tweaked monitor (or an ASCII terminal):
//
//   SIZE cols rows           the logical character grid the page laid out into
//   CLEAR bg                 fill the whole frame with palette colour bg (0..15)
//   RECT x y w h bg          a filled rectangle (backgrounds, borders, swatches)
//   T x y fg bg <text...>    a styled text run starting at cell (x,y)
//   FRAME END                commit — the host flushes this frame to the monitor
//
// Colours are blit-style palette indices 0..15 (0 = white ... 15 = black), so a
// row maps directly onto CC's mon.blit(text, fgHex, bgHex); the host turns an
// index n into the CC colour value 2^n when it needs one.
//
// Every later stage (HTML/CSS layout, then JS/React) emits THIS protocol, so the
// renderer in browser.lua never has to change.
#ifndef WEB_DRAW_H
#define WEB_DRAW_H
#include <stdio.h>

enum {
  COL_WHITE = 0, COL_ORANGE = 1, COL_MAGENTA = 2, COL_LIGHTBLUE = 3,
  COL_YELLOW = 4, COL_LIME = 5, COL_PINK = 6, COL_GRAY = 7,
  COL_LIGHTGRAY = 8, COL_CYAN = 9, COL_PURPLE = 10, COL_BLUE = 11,
  COL_BROWN = 12, COL_GREEN = 13, COL_RED = 14, COL_BLACK = 15
};

// When set, the emitters produce no output. Layout makes a "dry" pass with this
// on to measure page height before emitting the real frame (so SIZE can carry
// the true height). Per translation unit; left 0 for callers that don't measure.
static int draw_suppress = 0;

static inline void draw_size(int cols, int rows) { if (!draw_suppress) printf("SIZE %d %d\n", cols, rows); }
static inline void draw_clear(int bg) { if (!draw_suppress) printf("CLEAR %d\n", bg); }
static inline void draw_rect(int x, int y, int w, int h, int bg) {
  if (!draw_suppress) printf("RECT %d %d %d %d %d\n", x, y, w, h, bg);
}
static inline void draw_text(int x, int y, int fg, int bg, const char *s) {
  if (!draw_suppress) printf("T %d %d %d %d %s\n", x, y, fg, bg, s);
}
static inline void draw_frame_end(void) { if (!draw_suppress) printf("FRAME END\n"); }

#endif
